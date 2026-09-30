import Foundation

actor ApprovalMailbox {
    private var values: [CodexTransportApproval] = []
    private var waiter: CheckedContinuation<CodexTransportApproval, Never>?

    func append(_ value: CodexTransportApproval) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            values.append(value)
        }
    }

    func next() async -> CodexTransportApproval {
        if !values.isEmpty { return values.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@main
struct CodexTransportHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("fixture path required") }
        let transport = CodexTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]), requestTimeout: .seconds(3))
        let mailbox = ApprovalMailbox()
        let eventTask = Task {
            for await event in transport.transportEvents() {
                if case .approval(let approval) = event {
                    await mailbox.append(approval)
                }
            }
        }
        let thread = try await transport.start(projectPath: "/tmp/Attending Fixture")
        assert(thread.id == "owned-thread")
        let turn = try await transport.startTurn(in: thread, prompt: "fixture only")
        assert(turn.id == "turn-1")
        let approval = await mailbox.next()
        assert(approval.kind == .fileChange)
        assert(approval.grantRoot == "/outside-project")
        assert(approval.contextJSON.contains("grantRoot"))
        assert(!approval.canAllow)
        assert(approval.availableDecisions == [.deny, .cancel])
        do {
            try await transport.respond(to: approval, decision: .allowOnce)
            fatalError("unsafe approval unexpectedly accepted")
        } catch CodexTransportError.protocolViolation { }
        try await transport.respond(to: approval, decision: .deny)
        let steered = try await transport.steer(in: thread, turn: turn, prompt: "fixture steer")
        assert(steered.id == turn.id)
        let networkApproval = await mailbox.next()
        assert(networkApproval.kind == .command)
        assert(networkApproval.command == "curl https://example.com")
        assert(networkApproval.contextJSON.contains("networkApprovalContext"))
        assert(!networkApproval.canAllow)
        assert(networkApproval.availableDecisions == [.deny, .cancel])
        try await transport.respond(to: networkApproval, decision: .deny)
        let restricted = await mailbox.next()
        assert(restricted.command == "printf fixture")
        assert(!restricted.canAllow)
        assert(restricted.availableDecisions == [.deny])
        try await transport.respond(to: restricted, decision: .deny)
        let started = ContinuousClock.now
        do {
            try await transport.interrupt(in: thread, turn: steered)
            fatalError("crashed fixture unexpectedly replied")
        } catch CodexTransportError.processExited {
            assert(ContinuousClock.now - started < .seconds(2))
        }
        eventTask.cancel()
        print("PASS: fake app-server handshake, split JSONL, correlation, fail-closed approval, crash rejection")
    }
}
