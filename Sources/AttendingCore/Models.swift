import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable { case claudeCode, codex, chatGPT
    public var title: String { switch self { case .claudeCode: "Claude Code"; case .codex: "Codex"; case .chatGPT: "ChatGPT" } }
}
public enum Capability: String, Codable, Sendable { case observe, openProject, sendMessage, approve, stop }
public struct ProviderDescriptor: Identifiable, Sendable {
    public var id: ProviderID
    public var capabilities: Set<Capability>
    public var detail: String
    public init(id: ProviderID, capabilities: Set<Capability>, detail: String) { self.id = id; self.capabilities = capabilities; self.detail = detail }
}
public protocol AgentProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func events() -> AsyncStream<AgentEvent>
}
public enum SessionStatus: String, Codable, Sendable { case idle, working, attention, completed, failed, stale
    public var title: String { switch self { case .idle: "Ready"; case .working: "Working"; case .attention: "Needs attention"; case .completed: "Completed"; case .failed: "Error"; case .stale: "Disconnected" } }
}
public struct Project: Codable, Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
public struct AgentSession: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var provider: ProviderID
    public var externalID: String
    public var projectPath: String
    public var title: String
    public var status: SessionStatus
    public var startedAt: Date
    public var lastActiveAt: Date
    public var latestActivity: String
}
public struct AgentEvent: Codable, Sendable {
    public var id: UUID
    public var provider: ProviderID
    public var sessionID: String
    public var projectPath: String
    public var kind: Kind
    public var timestamp: Date
    /// The conversation's name, when the provider has one. Sessions keep the last name they were given.
    public var title: String?
    public enum Kind: String, Codable, Sendable { case started, working, attention, completed, failed, ended, stopped }
    public init(id: UUID = UUID(), provider: ProviderID, sessionID: String, projectPath: String, kind: Kind, timestamp: Date = Date(), title: String? = nil) {
        self.id = id; self.provider = provider; self.sessionID = sessionID; self.projectPath = projectPath; self.kind = kind; self.timestamp = timestamp; self.title = title
    }
    public func validate(now: Date = Date()) -> Bool {
        !sessionID.isEmpty && sessionID.utf8.count <= 256 && !sessionID.contains(where: { $0.isNewline || $0.asciiValue == 0 }) && projectPath.hasPrefix("/") && projectPath.utf8.count < 4096 && !projectPath.contains("\0") && timestamp <= now.addingTimeInterval(60)
    }
}
public struct AppState: Codable, Sendable, Equatable {
    public var version = 1
    public var sessions: [AgentSession] = []
    public var managedCodexProjects: [String: String]? = nil
    public init() {}
    public var projects: [Project] { Set(sessions.map(\.projectPath)).sorted().map { Project(path: $0) } }
    public mutating func apply(_ event: AgentEvent, liveEventsSince: Date? = nil) {
        guard event.validate() else { return }
        let id = event.provider.rawValue + ":" + event.sessionID
        let previous = sessions.first(where: { $0.id == id })
        guard previous == nil || event.timestamp >= previous!.lastActiveAt else { return }
        var status: SessionStatus = switch event.kind { case .started, .stopped: .idle; case .working: .working; case .attention: .attention; case .completed: .completed; case .failed: .failed; case .ended: .stale }
        var activity: String = switch event.kind { case .started: "Session started"; case .working: "Agent is working"; case .attention: "Respond in the provider session"; case .completed: "Turn completed"; case .failed: "Provider reported an error"; case .ended: "Session ended"; case .stopped: "Stopped" }
        if let cutoff = liveEventsSince, event.timestamp < cutoff,
           [.working, .attention, .idle].contains(status) {
            status = .stale
            activity = "Waiting for a fresh provider event"
        }
        let started = event.kind == .working && previous?.status != .working && previous?.status != .attention ? event.timestamp : previous?.startedAt ?? event.timestamp
        let session = AgentSession(id: id, provider: event.provider, externalID: event.sessionID, projectPath: event.projectPath, title: event.title ?? previous?.title ?? SessionNaming.folderTitle(event.projectPath), status: status, startedAt: started, lastActiveAt: event.timestamp, latestActivity: activity)
        sessions.removeAll { $0.id == id }; sessions.insert(session, at: 0)
        if sessions.count > 200 { sessions.removeLast(sessions.count - 200) }
    }
    public mutating func markDisconnected() {
        for i in sessions.indices where [.working, .attention, .idle].contains(sessions[i].status) {
            sessions[i].status = .stale; sessions[i].latestActivity = "Waiting for a fresh provider event"
        }
    }
}
/// Readable names for sessions that have no conversation title yet.
public enum SessionNaming {
    /// "Google Drive" rather than "GoogleDrive-name@example.com", "Home" rather than the user name,
    /// and the task name for Codex's dated task folders (~/Documents/Codex/2026-10-01/fix-the-build).
    public static func folderTitle(_ path: String, home: String = NSHomeDirectory()) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        if url.path == URL(fileURLWithPath: home).standardizedFileURL.path { return "Home" }
        if name.hasPrefix("GoogleDrive-") { return "Google Drive" }
        if name.hasPrefix("OneDrive-") { return "OneDrive" }
        if name == "com~apple~CloudDocs" { return "iCloud Drive" }
        if isScratch(path) { return "Temporary folder" }
        let parent = url.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == "Codex", parent.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let words = name.replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        return name
    }
    /// Temporary and build folders: sessions there are tests and scratch work, not projects.
    public static func isScratch(_ path: String) -> Bool {
        path == "/tmp" || path.hasPrefix("/tmp/") || path == "/private/tmp" || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/") || path.contains("/.build/")
    }
}

public enum StorageError: Error { case unsupportedVersion(Int) }
public actor StateStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppState() }
        let state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw StorageError.unsupportedVersion(state.version) }
        return state
    }
    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
public enum AppPaths {
    /// ~/Library/Application Support/Attending. Installs from before the rename keep
    /// using their existing "Astra" folder. ATTENDING_DATA_DIR overrides it (tests).
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ATTENDING_DATA_DIR"], override.hasPrefix("/") { return URL(fileURLWithPath: override, isDirectory: true) }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = support.appendingPathComponent("Attending", isDirectory: true)
        let legacy = support.appendingPathComponent("Astra", isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
    public static var events: URL { directory.appendingPathComponent("events", isDirectory: true) }
}
