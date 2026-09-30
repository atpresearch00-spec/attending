import Foundation
import Darwin

public enum ApprovalDecision: String, Codable, Sendable {
    case allowOnce
    case deny
}

public struct ApprovalRequest: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let provider: ProviderID
    public let sessionID: String
    public let projectPath: String
    public let toolName: String
    /// The complete canonical JSON object supplied by the provider. It is transported in memory only.
    public let toolInputJSON: String
    /// The exact command string when the tool input contains one. This is never shortened.
    public let command: String?
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        sessionID: String,
        projectPath: String,
        toolName: String,
        toolInputJSON: String,
        command: String?,
        requestedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.command = command
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }

    public var displayText: String { command ?? toolInputJSON }

    public func validate(now: Date = Date()) -> Bool {
        guard provider == .claudeCode,
              !sessionID.isEmpty, sessionID.utf8.count <= 256,
              !sessionID.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              projectPath.hasPrefix("/"), projectPath.utf8.count < 4_096,
              !projectPath.contains("\0"),
              !toolName.isEmpty, toolName.utf8.count <= 256,
              toolInputJSON.utf8.count <= ApprovalWire.maximumToolInputBytes,
              requestedAt <= now.addingTimeInterval(5),
              requestedAt >= now.addingTimeInterval(-10),
              expiresAt > now,
              expiresAt <= requestedAt.addingTimeInterval(ApprovalWire.maximumLifetime + 1),
              let data = toolInputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let input = object as? [String: Any]
        else { return false }

        if let command {
            guard command.utf8.count <= ApprovalWire.maximumToolInputBytes,
                  input["command"] as? String == command
            else { return false }
        } else if toolName == "Bash" {
            // Never offer an approval card for a shell action whose full command cannot be shown.
            return false
        }
        return true
    }
}

/// The authenticated correlation envelope used by `attending-bridge` and `ApprovalBroker`.
/// UI code should consume `ApprovalBroker.snapshots` rather than retain this value.
public struct ApprovalEnvelope: Codable, Sendable {
    public let request: ApprovalRequest
    public let token: String

    public init(request: ApprovalRequest, token: String) {
        self.request = request
        self.token = token
    }
}

public struct ApprovalResponseEnvelope: Codable, Sendable {
    public let requestID: UUID
    public let token: String
    public let decision: ApprovalDecision

    public init(requestID: UUID, token: String, decision: ApprovalDecision) {
        self.requestID = requestID
        self.token = token
        self.decision = decision
    }
}

public enum ApprovalTransportError: Error, Equatable {
    case alreadyRunning
    case invalidDirectory
    case invalidMessage
    case messageTooLarge
    case socketPathTooLong
    case systemCall(String, Int32)
}

public extension AppPaths {
    static var approvalSocket: URL {
        directory.appendingPathComponent("run", isDirectory: true).appendingPathComponent("approval.sock")
    }
}

/// Length-prefixed local wire format. The maximums keep a malformed peer from retaining memory or a socket.
public enum ApprovalWire {
    public static let maximumMessageBytes = 131_072
    public static let maximumToolInputBytes = 65_536
    public static let maximumLifetime: TimeInterval = 60

    public static func configure(_ descriptor: Int32, timeout: TimeInterval) throws {
        var noPipe: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe))) == 0 else {
            throw ApprovalTransportError.systemCall("setsockopt(SO_NOSIGPIPE)", errno)
        }
        let bounded = max(0.1, min(timeout, maximumLifetime + 1))
        var value = timeval(tv_sec: Int(bounded), tv_usec: Int32((bounded - floor(bounded)) * 1_000_000))
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0
        else { throw ApprovalTransportError.systemCall("setsockopt(timeout)", errno) }
    }

    public static func send<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumMessageBytes else { throw ApprovalTransportError.messageTooLarge }
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        try writeAll(header, to: descriptor)
        try writeAll(payload, to: descriptor)
    }

    public static func receive<T: Decodable>(_ type: T.Type, from descriptor: Int32) throws -> T {
        let header = try readExactly(MemoryLayout<UInt32>.size, from: descriptor)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= maximumMessageBytes else { throw ApprovalTransportError.messageTooLarge }
        let payload = try readExactly(Int(length), from: descriptor)
        do { return try JSONDecoder().decode(type, from: payload) }
        catch { throw ApprovalTransportError.invalidMessage }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        let received = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { throw ApprovalTransportError.invalidMessage }
            var offset = 0
            while offset < count {
                let amount = Darwin.recv(descriptor, base.advanced(by: offset), count - offset, 0)
                if amount > 0 { offset += amount; continue }
                if amount < 0 && errno == EINTR { continue }
                throw ApprovalTransportError.systemCall("recv", amount == 0 ? ECONNRESET : errno)
            }
            return offset
        }
        guard received == count else { throw ApprovalTransportError.invalidMessage }
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw ApprovalTransportError.invalidMessage }
            var offset = 0
            while offset < data.count {
                let amount = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                if amount > 0 { offset += amount; continue }
                if amount < 0 && errno == EINTR { continue }
                throw ApprovalTransportError.systemCall("send", amount == 0 ? EPIPE : errno)
            }
        }
    }
}

/// In-memory approval broker for the Attending UI. It never writes provider tool input to disk.
public actor ApprovalBroker {
    public nonisolated let snapshots: AsyncStream<[ApprovalRequest]>

    private struct Pending {
        let envelope: ApprovalEnvelope
        let descriptor: Int32
        let disconnectSource: DispatchSourceRead
        let expiryTask: Task<Void, Never>
    }

    private let socketURL: URL
    private let continuation: AsyncStream<[ApprovalRequest]>.Continuation
    private var listener: DispatchSourceRead?
    private var pending: [UUID: Pending] = [:]
    private var inflightConnections: Set<Int32> = []
    private var seen: [UUID: Date] = [:]
    private let maximumPending = 64
    private var stopped = false
    private var ownsSocket = false

    public init(socketURL: URL = AppPaths.approvalSocket) {
        self.socketURL = socketURL
        let pair = AsyncStream.makeStream(of: [ApprovalRequest].self, bufferingPolicy: .bufferingNewest(8))
        snapshots = pair.stream
        continuation = pair.continuation
    }

    deinit {
        listener?.cancel()
        for item in pending.values {
            item.expiryTask.cancel()
            item.disconnectSource.cancel()
        }
        for descriptor in inflightConnections { Darwin.close(descriptor) }
        continuation.finish()
    }

    public func start() throws {
        guard !stopped else { throw ApprovalTransportError.invalidMessage }
        guard listener == nil else { return }
        try preparePrivateDirectory(socketURL.deletingLastPathComponent())
        try removeStaleSocketIfSafe()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ApprovalTransportError.systemCall("socket", errno) }
        do {
            try ApprovalWire.configure(descriptor, timeout: 2)
            try bindSocket(descriptor, to: socketURL.path)
            ownsSocket = true
            guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ApprovalTransportError.systemCall("chmod", errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ApprovalTransportError.systemCall("listen", errno)
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ApprovalTransportError.systemCall("fcntl", errno)
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { await self?.acceptAvailable(on: descriptor) }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            listener = source
            source.resume()
            publishSnapshot()
        } catch {
            Darwin.close(descriptor)
            if ownsSocket { try? FileManager.default.removeItem(at: socketURL); ownsSocket = false }
            throw error
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        listener = nil
        if ownsSocket { try? FileManager.default.removeItem(at: socketURL); ownsSocket = false }
        for id in Array(pending.keys) { removePending(id) }
        // Wake pending readers; the reader owns the final close, preventing fd reuse races.
        for descriptor in inflightConnections { Darwin.shutdown(descriptor, SHUT_RDWR) }
        publishSnapshot()
        continuation.finish()
    }

    public func pendingRequests() -> [ApprovalRequest] { currentSnapshot() }

    @discardableResult
    public func respond(to id: UUID, decision: ApprovalDecision) -> Bool {
        guard let item = pending[id], item.envelope.request.expiresAt > Date() else {
            removePending(id)
            publishSnapshot()
            return false
        }
        let response = ApprovalResponseEnvelope(requestID: id, token: item.envelope.token, decision: decision)
        do {
            try ApprovalWire.send(response, to: item.descriptor)
            removePending(id)
            publishSnapshot()
            return true
        } catch {
            removePending(id)
            publishSnapshot()
            return false
        }
    }

    private func acceptAvailable(on listenerDescriptor: Int32) {
        guard listener != nil, !stopped else { return }
        while true {
            let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                return
            }
            // Darwin accept inherits O_NONBLOCK from the listener. Frame parsing
            // runs on a utility task with socket deadlines, so accepted peers must
            // block for partial frames instead of failing early with EAGAIN.
            let acceptedFlags = fcntl(descriptor, F_GETFL)
            guard acceptedFlags >= 0, fcntl(descriptor, F_SETFL, acceptedFlags & ~O_NONBLOCK) == 0 else { Darwin.close(descriptor); continue }
            guard peerIsCurrentUser(descriptor) else { Darwin.close(descriptor); continue }
            guard pending.count + inflightConnections.count < maximumPending else {
                Darwin.close(descriptor)
                continue
            }
            do { try ApprovalWire.configure(descriptor, timeout: 2) }
            catch { Darwin.close(descriptor); continue }
            inflightConnections.insert(descriptor)
            Task.detached(priority: .utility) { [weak self] in
                do {
                    let envelope = try ApprovalWire.receive(ApprovalEnvelope.self, from: descriptor)
                    guard let self else { Darwin.close(descriptor); return }
                    await self.register(envelope, descriptor: descriptor)
                } catch {
                    guard let self else { Darwin.close(descriptor); return }
                    await self.rejectInflight(descriptor)
                }
            }
        }
    }

    private func register(_ envelope: ApprovalEnvelope, descriptor: Int32) {
        guard inflightConnections.remove(descriptor) != nil else { return }
        guard !stopped else { Darwin.close(descriptor); return }
        let now = Date()
        seen = seen.filter { $0.value > now.addingTimeInterval(-120) }
        guard pending.count < maximumPending,
              seen[envelope.request.id] == nil,
              envelope.token.utf8.count >= 64,
              envelope.token.utf8.count <= 128,
              envelope.request.validate(now: now)
        else { Darwin.close(descriptor); return }

        let id = envelope.request.id
        seen[id] = now
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.removeIfDisconnected(id: id, descriptor: descriptor) }
        }
        // Closing from the cancellation handler prevents a queued event from observing a reused fd.
        source.setCancelHandler { Darwin.close(descriptor) }
        let delay = max(0, envelope.request.expiresAt.timeIntervalSince(now))
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.expire(id)
        }
        pending[id] = Pending(envelope: envelope, descriptor: descriptor, disconnectSource: source, expiryTask: expiry)
        source.resume()
        publishSnapshot()
    }

    private func expire(_ id: UUID) {
        guard pending[id] != nil else { return }
        removePending(id)
        publishSnapshot()
    }

    private func removeIfDisconnected(id: UUID, descriptor: Int32) {
        guard pending[id]?.descriptor == descriptor else { return }
        var byte: UInt8 = 0
        let result = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        // The bridge sends exactly one request before waiting. EOF, errors, or any later byte
        // are disconnect/protocol violations; consuming neither avoids a permanently-ready source.
        if result >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            removePending(id)
            publishSnapshot()
        }
    }

    private func removePending(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.expiryTask.cancel()
        item.disconnectSource.cancel()
    }

    private func rejectInflight(_ descriptor: Int32) {
        guard inflightConnections.remove(descriptor) != nil else { return }
        Darwin.close(descriptor)
    }

    private func currentSnapshot() -> [ApprovalRequest] {
        pending.values.map(\.envelope.request).sorted { $0.requestedAt < $1.requestedAt }
    }

    private func publishSnapshot() { continuation.yield(currentSnapshot()) }

    private func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        return getpeereid(descriptor, &effectiveUID, &effectiveGID) == 0 && effectiveUID == geteuid()
    }

    private func preparePrivateDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == geteuid()
        else { throw ApprovalTransportError.invalidDirectory }

        if mkdir(directory.path, S_IRWXU) != 0 && errno != EEXIST {
            throw ApprovalTransportError.systemCall("mkdir", errno)
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw ApprovalTransportError.invalidDirectory }
    }

    private func removeStaleSocketIfSafe() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ApprovalTransportError.systemCall("lstat", errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else {
            throw ApprovalTransportError.invalidDirectory
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ApprovalTransportError.systemCall("socket", errno) }
        defer { Darwin.close(probe) }
        do {
            try connectSocket(probe, to: socketURL.path)
            throw ApprovalTransportError.alreadyRunning
        } catch ApprovalTransportError.systemCall("connect", let code) where code == ECONNREFUSED || code == ENOENT {
            // Only a definitively stale local socket may be removed.
        } catch {
            throw error
        }
        guard unlink(socketURL.path) == 0 else { throw ApprovalTransportError.systemCall("unlink", errno) }
    }

    private func bindSocket(_ descriptor: Int32, to path: String) throws {
        var address = try unixAddress(path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard result == 0 else { throw ApprovalTransportError.systemCall("bind", errno) }
    }

    private func connectSocket(_ descriptor: Int32, to path: String) throws {
        var address = try unixAddress(path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
        }
        guard result == 0 else { throw ApprovalTransportError.systemCall("connect", errno) }
    }

    private func unixAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw ApprovalTransportError.socketPathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                bytes.withUnsafeBytes { source in
                    if let base = source.baseAddress { memcpy(destination, base, bytes.count) }
                }
            }
        }
        return address
    }
}
