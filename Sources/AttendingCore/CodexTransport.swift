import Foundation

private enum CodexJSONValue: Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func parse(_ value: Any) throws -> CodexJSONValue {
        switch value {
        case let value as [String: Any]: return .object(try value.mapValues(parse))
        case let value as [Any]: return .array(try value.map(parse))
        case let value as String: return .string(value)
        case let value as NSNumber:
            // NSNumber bridges booleans too, so test its Core Foundation type first.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        case is NSNull: return .null
        default: throw CodexTransportError.protocolViolation("Codex app-server returned an unsupported JSON value.")
        }
    }

    var object: [String: CodexJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}

/// Pipe readability handlers run outside the transport actor. Sequence their bytes
/// before hopping into the actor: independent `Task` hops are not FIFO.
private final class CodexPipeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        value = 0
    }
}

/// An Attending-created Codex thread.  The public initializer exists only so Attending can
/// restore IDs it previously persisted; callers must never use it for discovered
/// desktop or CLI threads.
public struct CodexOwnedThread: Sendable, Hashable {
    public let id: String
    public let projectPath: String

    public init(id: String, projectPath: String) {
        self.id = id
        self.projectPath = projectPath
    }
}

public struct CodexTurn: Sendable, Hashable {
    public let id: String
    public let threadID: String

    public init(id: String, threadID: String) {
        self.id = id
        self.threadID = threadID
    }
}

/// A one-shot approval request. Its text is held only in memory by this adapter.
public struct CodexTransportApproval: Sendable, Hashable {
    public enum Kind: String, Sendable { case command, fileChange }

    public let id: String
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let kind: Kind
    public let command: String?
    public let cwd: String?
    public let reason: String?
    public let diff: String?
    public let grantRoot: String?
    /// Bounded JSON of every server-supplied approval parameter, retained only in memory.
    public let contextJSON: String
    /// `false` means Attending has no exact request content to show, so it will deny
    /// any attempted allow-once response.
    public let canAllow: Bool
    public let unavailableReason: String?
    public let availableDecisions: Set<CodexApprovalDecision>
    public let startedAtMs: Int64

    public init(id: String, threadID: String, turnID: String, itemID: String, kind: Kind, command: String?, cwd: String?, reason: String?, diff: String?, grantRoot: String? = nil, contextJSON: String = "", canAllow: Bool, unavailableReason: String?, availableDecisions: Set<CodexApprovalDecision>, startedAtMs: Int64) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.reason = reason
        self.diff = diff
        self.grantRoot = grantRoot
        self.contextJSON = contextJSON
        self.canAllow = canAllow
        self.unavailableReason = unavailableReason
        self.availableDecisions = availableDecisions
        self.startedAtMs = startedAtMs
    }
}

public enum CodexApprovalDecision: Sendable, Equatable, Hashable {
    /// Maps to app-server `accept`; it never creates a persistent grant.
    case allowOnce
    case deny
    case cancel
}

public enum CodexTransportEvent: Sendable {
    case turn(threadID: String, turnID: String, active: Bool)
    case text(threadID: String, turnID: String, delta: String)
    case summary(threadID: String, turnID: String, text: String)
    case approval(CodexTransportApproval)
    case approvalResolved(id: String)
    case diagnostic(String)
}

public enum CodexTransportError: Error, Sendable, LocalizedError {
    case unavailable(String)
    case invalidInput(String)
    case notReady
    case processExited(Int32)
    case protocolViolation(String)
    case timeout(String)
    case unknownThread
    case unknownTurn
    case unknownApproval

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .invalidInput(let detail), .protocolViolation(let detail), .timeout(let detail): detail
        case .notReady: "Codex app-server is not ready."
        case .processExited(let status): "Codex app-server exited (\(status))."
        case .unknownThread: "This is not an Attending-owned Codex thread."
        case .unknownTurn: "This Codex turn is no longer active."
        case .unknownApproval: "This approval request has expired or was already answered."
        }
    }
}

/// A bounded JSONL transport to a child `codex app-server --stdio` process.
///
/// The process is launched only after an explicit `start` or `resume` action.
/// It neither discovers desktop sessions nor connects to the app-server daemon.
public actor CodexTransport: AgentProvider {
    public nonisolated let descriptor = ProviderDescriptor(
        id: .codex,
        capabilities: [.openProject, .sendMessage, .approve, .stop],
        detail: "Starts Attending-owned Codex app-server sessions on demand"
    )

    private static let defaultExecutable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
    private static let maxInputBytes = 32 * 1024
    private static let maxPathBytes = 4 * 1024
    private static let maxJSONLBytes = 1024 * 1024
    private static let maxDiagnosticBytes = 4 * 1024

    public nonisolated let executableURL: URL
    public static let executableCandidates = [
        // ChatGPT.app moved its bundled CLI into codex-cli/bin in September 2026.
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
    ]
    public static func discoverExecutable(candidates: [String] = executableCandidates) -> URL? {
        candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    private let requestTimeout: Duration
    private let approvalTimeout: Duration = .seconds(120)
    private let writer = DispatchQueue(label: "attending.codex.writer")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var processGeneration = 0
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var discardedStderrLines = 0
    private var expectedStdoutSequence = 0
    private var pendingStdoutChunks: [Int: Data] = [:]
    private var requestSequence: Int64 = 0
    private var pendingRequests: [String: CheckedContinuation<[String: CodexJSONValue], Error>] = [:]
    private var ownedThreads: [String: CodexOwnedThread] = [:]
    private var activeTurns: [String: String] = [:]
    private var pendingApprovals: [String: CodexTransportApproval] = [:]
    private var approvalWireIDs: [String: Any] = [:]
    private var latestTurnDiff: [String: String] = [:]
    private var itemDiffs: [String: String] = [:]
    private var isInitialized = false

    private nonisolated let agentEventStream: AsyncStream<AgentEvent>
    private var agentEventContinuation: AsyncStream<AgentEvent>.Continuation
    private nonisolated let transportEventStream: AsyncStream<CodexTransportEvent>
    private var transportEventContinuation: AsyncStream<CodexTransportEvent>.Continuation

    public init(executableURL: URL = CodexTransport.discoverExecutable() ?? URL(fileURLWithPath: CodexTransport.executableCandidates[0]), requestTimeout: Duration = .seconds(15)) {
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout
        let agentPair = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.agentEventStream = agentPair.stream
        self.agentEventContinuation = agentPair.continuation
        let transportPair = AsyncStream<CodexTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.transportEventStream = transportPair.stream
        self.transportEventContinuation = transportPair.continuation
    }

    public nonisolated func events() -> AsyncStream<AgentEvent> { agentEventStream }
    public nonisolated func transportEvents() -> AsyncStream<CodexTransportEvent> { transportEventStream }

    /// Creates a new owned thread with `untrusted` approvals and project-only writes.
    public func start(projectPath: String) async throws -> CodexOwnedThread {
        let projectPath = try validatedProjectPath(projectPath)
        try await ensureReady()
        let result = try await request("thread/start", params: [
            "cwd": projectPath,
            "approvalPolicy": "untrusted",
            "approvalsReviewer": "user",
            "sandbox": "workspace-write",
            "ephemeral": false
        ])
        guard let thread = result["thread"]?.object, let id = thread["id"]?.string, !id.isEmpty else {
            throw CodexTransportError.protocolViolation("thread/start returned no thread ID.")
        }
        let owned = CodexOwnedThread(id: id, projectPath: projectPath)
        ownedThreads[id] = owned
        emitLifecycle(for: owned, kind: .started)
        return owned
    }

    /// Resumes only an ID restored from Attending's own persisted session metadata.
    public func resume(_ thread: CodexOwnedThread) async throws -> CodexOwnedThread {
        let projectPath = try validatedProjectPath(thread.projectPath)
        try validateIdentifier(thread.id, label: "thread")
        try await ensureReady()
        let result = try await request("thread/resume", params: [
            "threadId": thread.id,
            "cwd": projectPath,
            "approvalPolicy": "untrusted",
            "approvalsReviewer": "user",
            "sandbox": "workspace-write",
            "excludeTurns": true
        ])
        guard let returned = result["thread"]?.object, returned["id"]?.string == thread.id else {
            throw CodexTransportError.protocolViolation("thread/resume returned a mismatched thread.")
        }
        let owned = CodexOwnedThread(id: thread.id, projectPath: projectPath)
        ownedThreads[owned.id] = owned
        emitLifecycle(for: owned, kind: .started)
        return owned
    }

    public func startTurn(in thread: CodexOwnedThread, prompt: String) async throws -> CodexTurn {
        let owned = try owned(thread)
        let prompt = try validatedPrompt(prompt)
        try await ensureReady()
        let result = try await request("turn/start", params: turnParams(threadID: owned.id, projectPath: owned.projectPath, prompt: prompt))
        let turn = try decodedStartedTurn(from: result, threadID: owned.id)
        activeTurns[owned.id] = turn.id
        emitLifecycle(for: owned, kind: .working)
        transportEventContinuation.yield(.turn(threadID: owned.id, turnID: turn.id, active: true))
        return turn
    }

    public func steer(in thread: CodexOwnedThread, turn: CodexTurn, prompt: String) async throws -> CodexTurn {
        let owned = try owned(thread)
        try validateTurn(turn, in: owned)
        let prompt = try validatedPrompt(prompt)
        try await ensureReady()
        let result = try await request("turn/steer", params: [
            "threadId": owned.id,
            "expectedTurnId": turn.id,
            "input": [["type": "text", "text": prompt]]
        ])
        guard let turnID = result["turnId"]?.string, !turnID.isEmpty else {
            throw CodexTransportError.protocolViolation("turn/steer returned no turn ID.")
        }
        let returned = CodexTurn(id: turnID, threadID: owned.id)
        activeTurns[owned.id] = returned.id
        transportEventContinuation.yield(.turn(threadID: owned.id, turnID: returned.id, active: true))
        return returned
    }

    public func interrupt(in thread: CodexOwnedThread, turn: CodexTurn) async throws {
        let owned = try owned(thread)
        try validateTurn(turn, in: owned)
        try await ensureReady()
        _ = try await request("turn/interrupt", params: ["threadId": owned.id, "turnId": turn.id])
    }

    /// Answers only a currently pending, correlated request. Persistent grants are never sent.
    public func respond(to approval: CodexTransportApproval, decision: CodexApprovalDecision) throws {
        guard let pending = pendingApprovals.removeValue(forKey: approval.id), pending == approval else {
            throw CodexTransportError.unknownApproval
        }
        guard let wireID = approvalWireIDs.removeValue(forKey: approval.id) else {
            throw CodexTransportError.unknownApproval
        }
        guard decision != .allowOnce || pending.canAllow else {
            pendingApprovals[approval.id] = pending
            approvalWireIDs[approval.id] = wireID
            throw CodexTransportError.protocolViolation(pending.unavailableReason ?? "Codex did not provide exact approval content.")
        }
        guard pending.availableDecisions.contains(decision) else {
            pendingApprovals[approval.id] = pending
            approvalWireIDs[approval.id] = wireID
            throw CodexTransportError.protocolViolation("Codex does not allow that approval decision.")
        }
        let wireDecision: String = switch decision { case .allowOnce: "accept"; case .deny: "decline"; case .cancel: "cancel" }
        try writeJSON(["jsonrpc": "2.0", "id": wireID, "result": ["decision": wireDecision]])
        transportEventContinuation.yield(.approvalResolved(id: approval.id))
    }

    public func shutdown() {
        failTransport(with: CodexTransportError.processExited(0), emitEnded: true)
    }

    private func ensureReady() async throws {
        if isInitialized, let process, process.isRunning { return }
        try launch()
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "attending", "title": "Attending", "version": "0.1"]
            ])
            try writeJSON(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
            isInitialized = true
        } catch {
            failTransport(with: error, emitEnded: false)
            throw error
        }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexTransportError.unavailable("Codex was not found at \(executableURL.path).")
        }
        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["app-server", "--stdio"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = standardError
        processGeneration += 1
        let generation = processGeneration
        let stdoutSequence = CodexPipeSequence()
        expectedStdoutSequence = 0
        pendingStdoutChunks.removeAll(keepingCapacity: false)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            let sequence = stdoutSequence.next()
            Task { await self.receivedStdout(data, generation: generation, sequence: sequence) }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receivedStderr(data, generation: generation) }
        }
        child.terminationHandler = { [weak self] process in
            Task { await self?.processDidExit(process.terminationStatus, generation: generation) }
        }
        do { try child.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw CodexTransportError.unavailable("Could not launch Codex app-server: \(error.localizedDescription)")
        }
        process = child
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = standardError.fileHandleForReading
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: CodexJSONValue] {
        guard let process, process.isRunning else { throw CodexTransportError.notReady }
        requestSequence += 1
        let id = String(requestSequence)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try writeJSON(["jsonrpc": "2.0", "id": requestSequence, "method": method, "params": params])
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            let timeout = requestTimeout
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireRequest(id)
            }
        }
    }

    private func expireRequest(_ id: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CodexTransportError.timeout("Codex app-server request \(id) timed out."))
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let inputHandle, process?.isRunning == true else { throw CodexTransportError.notReady }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard data.count <= Self.maxInputBytes else { throw CodexTransportError.invalidInput("Codex request exceeds \(Self.maxInputBytes) bytes.") }
        var line = data
        line.append(0x0A)
        let framedLine = line
        let generation = processGeneration
        // Keep potentially blocking pipe I/O off the actor so timeouts and the UI
        // can still make progress if the child stops draining stdin.
        writer.async { [weak self, inputHandle] in
            do { try inputHandle.write(contentsOf: framedLine) }
            catch { Task { await self?.writeFailed(generation: generation) } }
        }
    }

    private func writeFailed(generation: Int) {
        guard generation == processGeneration else { return }
        failTransport(with: CodexTransportError.processExited(process?.terminationStatus ?? -1), emitEnded: true)
    }

    private func receivedStdout(_ data: Data, generation: Int, sequence: Int) {
        guard generation == processGeneration else { return }
        pendingStdoutChunks[sequence] = data
        while let next = pendingStdoutChunks.removeValue(forKey: expectedStdoutSequence) {
            expectedStdoutSequence += 1
            consumeStdout(next)
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        if stdoutBuffer.count > Self.maxJSONLBytes {
            failTransport(with: CodexTransportError.protocolViolation("Codex app-server emitted an oversized JSONL record."), emitEnded: true)
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maxJSONLBytes else {
                failTransport(with: CodexTransportError.protocolViolation("Codex app-server emitted an oversized JSONL record."), emitEnded: true)
                return
            }
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexTransportError.protocolViolation("Codex app-server emitted a non-object JSON message.")
                }
                handle(object)
            } catch {
                failTransport(with: error, emitEnded: true)
                return
            }
        }
    }

    private func receivedStderr(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.maxDiagnosticBytes { stderrBuffer = stderrBuffer.suffix(Self.maxDiagnosticBytes) }
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            stderrBuffer.removeSubrange(...newline)
            // Codex emits routine JSON logs and startup warnings on stderr. They
            // may expose implementation details and are not product diagnostics;
            // structured RPC errors and process exit are handled separately.
            discardedStderrLines += 1
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"], object["method"] == nil {
            let key = requestID(id)
            guard let continuation = pendingRequests.removeValue(forKey: key) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: CodexTransportError.protocolViolation(error["message"] as? String ?? "Codex app-server rejected a request."))
            } else if let result = object["result"] as? [String: Any] {
                do {
                    guard let safeResult = try CodexJSONValue.parse(result).object else {
                        throw CodexTransportError.protocolViolation("Codex app-server response result was not an object.")
                    }
                    continuation.resume(returning: safeResult)
                } catch {
                    continuation.resume(throwing: error)
                }
            } else {
                continuation.resume(throwing: CodexTransportError.protocolViolation("Codex app-server response had no result."))
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        if object["id"] != nil {
            handleServerRequest(id: object["id"]!, method: method, params: params)
        } else {
            handleNotification(method, params: params)
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        let requestID = requestID(id)
        switch method {
        case "item/commandExecution/requestApproval":
            guard let approval = approval(id: requestID, kind: .command, params: params) else { replyDecline(id: id); return }
            pendingApprovals[requestID] = approval
            approvalWireIDs[requestID] = id
            transportEventContinuation.yield(.approval(approval))
            scheduleApprovalExpiry(requestID)
        case "item/fileChange/requestApproval":
            guard let approval = approval(id: requestID, kind: .fileChange, params: params) else { replyDecline(id: id); return }
            pendingApprovals[requestID] = approval
            approvalWireIDs[requestID] = id
            transportEventContinuation.yield(.approval(approval))
            scheduleApprovalExpiry(requestID)
        default:
            // Server-originated actions are denied unless Attending explicitly implements them.
            replyError(id: id, code: -32601, message: "Attending does not support \(method).")
        }
    }

    private func handleNotification(_ method: String, params: [String: Any]) {
        guard let threadID = string(params["threadId"]), ownedThreads[threadID] != nil else { return }
        let turnID = string(params["turnId"])
        switch method {
        case "thread/status/changed":
            if let status = params["status"] as? [String: Any], let type = string(status["type"]) {
                let event: AgentEvent.Kind = switch type {
                case "active": .working
                case "systemError": .failed
                case "idle": .completed
                default: .started
                }
                emitLifecycle(for: ownedThreads[threadID]!, kind: event)
            }
        case "turn/started":
            if let turn = params["turn"] as? [String: Any], let id = string(turn["id"]) {
                activeTurns[threadID] = id
                emitLifecycle(for: ownedThreads[threadID]!, kind: .working)
                transportEventContinuation.yield(.turn(threadID: threadID, turnID: id, active: true))
            }
        case "turn/completed":
            let completed = (params["turn"] as? [String: Any])
            let id = completed.flatMap { string($0["id"]) } ?? turnID
            if let id {
                activeTurns.removeValue(forKey: threadID)
                let status = completed.flatMap { string($0["status"]) }
                emitLifecycle(for: ownedThreads[threadID]!, kind: status == "failed" ? .failed : .completed)
                transportEventContinuation.yield(.turn(threadID: threadID, turnID: id, active: false))
            }
        case "item/agentMessage/delta":
            if let turnID, let delta = bounded(params["delta"] as? String) {
                transportEventContinuation.yield(.text(threadID: threadID, turnID: turnID, delta: delta))
            }
        case "item/reasoningSummary/textDelta":
            if let turnID, let delta = bounded(params["delta"] as? String) {
                transportEventContinuation.yield(.summary(threadID: threadID, turnID: turnID, text: delta))
            }
        case "turn/diff/updated":
            if let turnID, let diff = bounded(params["diff"] as? String) {
                latestTurnDiff[turnKey(threadID, turnID)] = diff
            }
        case "item/fileChange/patchUpdated":
            if let turnID, let itemID = string(params["itemId"]), let changes = params["changes"] as? [[String: Any]] {
                let joined = changes.compactMap { bounded($0["diff"] as? String) }.joined(separator: "\n")
                if !joined.isEmpty { itemDiffs[itemKey(threadID, turnID, itemID)] = joined }
            }
        case "item/started":
            if let turnID, let item = params["item"] as? [String: Any], string(item["type"]) == "fileChange",
               let itemID = string(item["id"]), let changes = item["changes"] as? [[String: Any]] {
                let joined = changes.compactMap { bounded($0["diff"] as? String) }.joined(separator: "\n")
                if !joined.isEmpty { itemDiffs[itemKey(threadID, turnID, itemID)] = joined }
            }
        case "serverRequest/resolved":
            let resolvedID = requestID(params["requestId"] as Any)
            if !resolvedID.isEmpty, pendingApprovals.removeValue(forKey: resolvedID) != nil {
                approvalWireIDs.removeValue(forKey: resolvedID)
                transportEventContinuation.yield(.approvalResolved(id: resolvedID))
            }
        case "error":
            let message = bounded(params["message"] as? String) ?? "Codex app-server reported an error."
            transportEventContinuation.yield(.diagnostic(message))
        default:
            break
        }
    }

    private func approval(id: String, kind: CodexTransportApproval.Kind, params: [String: Any]) -> CodexTransportApproval? {
        guard let threadID = string(params["threadId"]), ownedThreads[threadID] != nil,
              let turnID = string(params["turnId"]), let itemID = string(params["itemId"]),
              let started = integer(params["startedAtMs"]) else { return nil }
        let command = bounded(params["command"] as? String)
        // A turn-wide diff can include other items, so it must never authorize a
        // file-change approval. Only the item-specific patch is exact enough.
        let diff = kind == .fileChange ? itemDiffs[itemKey(threadID, turnID, itemID)] : nil
        let contextJSON = boundedApprovalContext(params)
        let grantRoot = bounded(params["grantRoot"] as? String)
        let hasUnsupportedScope = grantRoot != nil || params["networkApprovalContext"] != nil
        let contentIsExact = kind == .command ? command != nil : diff != nil
        let providerDecisions: Set<CodexApprovalDecision>
        if let offered = params["availableDecisions"] as? [Any] {
            providerDecisions = Set(offered.compactMap { value -> CodexApprovalDecision? in
                switch value as? String { case "accept": .allowOnce; case "decline": .deny; case "cancel": .cancel; default: nil }
            })
        } else { providerDecisions = [.allowOnce, .deny, .cancel] }
        let canAllow = contentIsExact && contextJSON != nil && !hasUnsupportedScope && providerDecisions.contains(.allowOnce)
        let unavailableReason: String? = canAllow ? nil : (!providerDecisions.contains(.allowOnce) ? "Codex does not offer Allow Once for this request." : hasUnsupportedScope
            ? "Codex requested a permission scope Attending does not support."
            : contextJSON == nil
                ? "Codex approval context exceeded Attending's in-memory limit."
                : kind == .fileChange
                    ? "Codex did not provide an item-specific file diff."
                    : "Codex did not provide the command to execute.")
        return CodexTransportApproval(id: id, threadID: threadID, turnID: turnID, itemID: itemID, kind: kind,
                                      command: command, cwd: bounded(params["cwd"] as? String),
                                      reason: bounded(params["reason"] as? String), diff: diff, grantRoot: grantRoot,
                                      contextJSON: contextJSON ?? "",
                                      canAllow: canAllow, unavailableReason: unavailableReason,
                                      availableDecisions: canAllow ? providerDecisions : providerDecisions.subtracting([.allowOnce]), startedAtMs: started)
    }

    private func replyDecline(id: Any) { try? writeJSON(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]]) }
    private func replyError(id: Any, code: Int, message: String) { try? writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

    private func scheduleApprovalExpiry(_ id: String) {
        let timeout = approvalTimeout
        let generation = processGeneration
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireApproval(id, generation: generation)
        }
    }

    private func expireApproval(_ id: String, generation: Int) {
        guard generation == processGeneration else { return }
        guard pendingApprovals.removeValue(forKey: id) != nil, let wireID = approvalWireIDs.removeValue(forKey: id) else { return }
        replyDecline(id: wireID)
        transportEventContinuation.yield(.approvalResolved(id: id))
    }

    private func processDidExit(_ status: Int32, generation: Int) {
        guard process != nil, generation == processGeneration else { return }
        let interruptedThreads = Array(ownedThreads.values)
        failTransport(with: CodexTransportError.processExited(status), emitEnded: true)
        if status != 0 {
            for thread in interruptedThreads { emitLifecycle(for: thread, kind: .failed) }
            transportEventContinuation.yield(.diagnostic("The Codex process stopped unexpectedly. Select its session and send an instruction to reconnect."))
        }
    }

    private func failTransport(with error: Error, emitEnded: Bool) {
        let child = process
        process = nil
        inputHandle = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        isInitialized = false
        if child?.isRunning == true { child?.terminate() }
        let requests = pendingRequests
        pendingRequests.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
        let approvals = pendingApprovals.keys
        pendingApprovals.removeAll()
        approvalWireIDs.removeAll()
        for id in approvals { transportEventContinuation.yield(.approvalResolved(id: id)) }
        for (threadID, turnID) in activeTurns {
            transportEventContinuation.yield(.turn(threadID: threadID, turnID: turnID, active: false))
        }
        if emitEnded {
            for owned in ownedThreads.values { emitLifecycle(for: owned, kind: .ended) }
        }
        activeTurns.removeAll()
        latestTurnDiff.removeAll()
        itemDiffs.removeAll()
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        discardedStderrLines = 0
        // A new process must explicitly resume persisted IDs; it never inherits
        // authorization to control sessions from a dead transport.
        ownedThreads.removeAll()
    }

    private func owned(_ thread: CodexOwnedThread) throws -> CodexOwnedThread {
        guard let owned = ownedThreads[thread.id], owned == thread else { throw CodexTransportError.unknownThread }
        return owned
    }

    private func validateTurn(_ turn: CodexTurn, in thread: CodexOwnedThread) throws {
        guard turn.threadID == thread.id, activeTurns[thread.id] == turn.id else { throw CodexTransportError.unknownTurn }
    }

    private func turnParams(threadID: String, projectPath: String, prompt: String) -> [String: Any] {
        [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]],
            "cwd": projectPath,
            "approvalPolicy": "untrusted",
            "approvalsReviewer": "user",
            "sandboxPolicy": ["type": "workspaceWrite", "writableRoots": [projectPath], "networkAccess": false, "excludeSlashTmp": true, "excludeTmpdirEnvVar": true]
        ]
    }

    private func decodedStartedTurn(from result: [String: CodexJSONValue], threadID: String) throws -> CodexTurn {
        guard let turn = result["turn"]?.object, let turnID = turn["id"]?.string, !turnID.isEmpty else {
            throw CodexTransportError.protocolViolation("turn/start returned no turn ID.")
        }
        return CodexTurn(id: turnID, threadID: threadID)
    }

    private func emitLifecycle(for thread: CodexOwnedThread, kind: AgentEvent.Kind) {
        agentEventContinuation.yield(AgentEvent(provider: .codex, sessionID: thread.id, projectPath: thread.projectPath, kind: kind))
    }

    private func validatedProjectPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= Self.maxPathBytes, !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw CodexTransportError.invalidInput("Project path must be a bounded absolute path.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func validatedPrompt(_ prompt: String) throws -> String {
        guard !prompt.isEmpty, prompt.utf8.count <= Self.maxInputBytes, !prompt.contains("\0") else {
            throw CodexTransportError.invalidInput("Prompt must be non-empty and at most \(Self.maxInputBytes) bytes.")
        }
        return prompt
    }

    private func validateIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw CodexTransportError.invalidInput("Invalid \(label) ID.")
        }
    }

    private func bounded(_ text: String?) -> String? {
        guard let text, text.utf8.count <= Self.maxJSONLBytes / 2 else { return nil }
        return text
    }

    private func boundedApprovalContext(_ params: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              data.count <= Self.maxJSONLBytes / 4 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func requestID(_ value: Any) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String ?? ""
    }

    private func integer(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func string(_ value: Any?) -> String? { value as? String }
    private func turnKey(_ threadID: String, _ turnID: String) -> String { "\(threadID)\u{1F}\(turnID)" }
    private func itemKey(_ threadID: String, _ turnID: String, _ itemID: String) -> String { "\(turnKey(threadID, turnID))\u{1F}\(itemID)" }
}
