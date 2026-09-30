import Foundation
import Darwin

@main struct ApprovalBrokerHarness {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/attending-broker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("run/approval.sock")
        let broker = ApprovalBroker(socketURL: socketURL)
        try await broker.start()
        let duplicate = ApprovalBroker(socketURL: socketURL)
        do { try await duplicate.start(); fatalError("duplicate listener accepted") } catch ApprovalTransportError.alreadyRunning { }
        await duplicate.stop()
        precondition(FileManager.default.fileExists(atPath: socketURL.path), "duplicate stop removed live socket")
        func connectClient(lifetime: Double) throws -> Int32 {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(descriptor >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(socketURL.path.utf8CString)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    bytes.withUnsafeBytes { source in _ = memcpy(dest, source.baseAddress!, bytes.count) }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(result == 0)
            try ApprovalWire.configure(descriptor, timeout: 2)
            let now = Date()
            let request = ApprovalRequest(provider: .claudeCode, sessionID: "broker-test", projectPath: "/tmp/test", toolName: "Bash", toolInputJSON: "{\"command\":\"printf test\"}", command: "printf test", requestedAt: now, expiresAt: now.addingTimeInterval(lifetime))
            try ApprovalWire.send(ApprovalEnvelope(request: request, token: String(repeating: "a", count: 64)), to: descriptor)
            return descriptor
        }
        var iterator = broker.snapshots.makeAsyncIterator()
        _ = await iterator.next()
        let first = try connectClient(lifetime: 0.4)
        guard let pending = await iterator.next(), pending.count == 1 else { fatalError("no pending snapshot") }
        guard let expired = await iterator.next(), expired.isEmpty else { fatalError("expiry did not clear snapshot") }
        let accepted = await broker.respond(to: pending[0].id, decision: .allowOnce)
        precondition(!accepted, "expired request accepted")
        close(first)
        let second = try connectClient(lifetime: 5)
        var connected = false
        while let snapshot = await iterator.next() {
            if !snapshot.isEmpty { connected = true; break }
        }
        precondition(connected)
        close(second)
        guard let removed = await iterator.next(), removed.isEmpty else { fatalError("disconnect did not clear snapshot") }
        await broker.stop()
        precondition(!FileManager.default.fileExists(atPath: socketURL.path))
        print("PASS: broker duplicate launch, expiry, replay rejection, disconnect snapshots, socket cleanup")
    }
}
