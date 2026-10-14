import AppKit
import CoreServices
import AttendingCore

/// Follows Codex's rollout files so sessions from the ChatGPT and Codex apps, the IDE
/// extension and the CLI show in the notch, not only the ones Attending starts.
///
/// File-system events drive it, so it does nothing while Codex is idle. Each file is read
/// once from where it was last read, and only turn boundaries are decoded.
final class CodexSessionWatcher: @unchecked Sendable {
    /// $CODEX_HOME, or ~/.codex.
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], custom.hasPrefix("/") { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static var available: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path) }

    /// Brings the Codex or ChatGPT app forward, whichever is running (or installed).
    @MainActor static func openApp() {
        let ids = ["com.openai.codex", "com.openai.chat"]
        if let running = NSWorkspace.shared.runningApplications.first(where: { ids.contains($0.bundleIdentifier ?? "") }) { running.activate(); return }
        if let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private struct Tracked { var reader = CodexRolloutReader(); var offset: UInt64 = 0; var lastWrite = Date() }

    private let root = CodexSessionWatcher.home.appendingPathComponent("sessions", isDirectory: true)
    private let index = CodexSessionWatcher.home.appendingPathComponent("session_index.jsonl")
    private let queue = DispatchQueue(label: "attending.codex-sessions", qos: .utility)
    private let onEvents: @Sendable ([AgentEvent]) -> Void
    private let onTitle: @Sendable (_ sessionID: String, _ title: String) -> Void
    private var stream: FSEventStreamRef?
    private var files: [String: Tracked] = [:]
    private var names: [String: String] = [:]
    private var staleCheck: DispatchSourceTimer?
    private var poll: DispatchSourceTimer?
    /// App launch: catch-up events are dated no earlier, so they count as live.
    private let since: Date

    /// A turn with no writes for this long is treated as stopped (Codex quit mid-turn).
    private static let silenceLimit: TimeInterval = 20 * 60

    init(since: Date, onEvents: @escaping @Sendable ([AgentEvent]) -> Void, onTitle: @escaping @Sendable (String, String) -> Void) {
        self.since = since; self.onEvents = onEvents; self.onTitle = onTitle
    }

    func start() {
        queue.async { [self] in
            guard stream == nil, FileManager.default.fileExists(atPath: root.path) else { return }
            names = loadNames()
            catchUp()
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<CodexSessionWatcher>.fromOpaque(info).takeUnretainedValue()
                let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
                watcher.changed(Array(changed))
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }
    }

    func stop() {
        queue.sync {
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil
            staleCheck?.cancel(); staleCheck = nil
            poll?.cancel(); poll = nil
        }
    }

    // MARK: Reading

    /// On launch, picks up sessions touched in the last few hours, so a turn that's already
    /// running shows as working and recent ones show under Recent.
    private func catchUp() {
        let recent = Date().addingTimeInterval(-6 * 3600)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        var events: [AgentEvent] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified > recent else { continue }
            let size = UInt64(values.fileSize ?? 0)
            var tracked = Tracked(offset: size, lastWrite: modified)
            // The header is the first line; the newest turn boundary is near the end.
            _ = tracked.reader.consume(lines(read(url, from: 0, count: 512 * 1024), dropFirstPartial: false))
            if size > 512 * 1024 { _ = tracked.reader.consume(lines(read(url, from: size - min(size - 512 * 1024, 2 * 1024 * 1024), count: 2 * 1024 * 1024), dropFirstPartial: true)) }
            files[url.path] = tracked
            guard let id = tracked.reader.threadID, let path = tracked.reader.projectPath, !tracked.reader.isSubagent, let last = tracked.reader.lastTurnEvent else { continue }
            if tracked.reader.turnOpen && Date().timeIntervalSince(modified) < Self.silenceLimit {
                // Dated from the turn's start (or launch, if earlier), so the turn's own later events always apply.
                events.append(AgentEvent(provider: .codex, sessionID: id, projectPath: path, kind: tracked.reader.openQuestions.isEmpty ? .working : .attention, timestamp: max(last, since), title: names[id]))
            } else if !tracked.reader.turnOpen {
                events.append(AgentEvent(provider: .codex, sessionID: id, projectPath: path, kind: .completed, timestamp: last, title: names[id]))
            }
        }
        if !events.isEmpty { onEvents(events) }
        scheduleStaleCheck()
        schedulePoll()
    }

    private func changed(_ reported: [String]) {
        // Under heavy writing macOS can drop file-level events and report only a folder;
        // then every session file being followed is re-checked.
        let paths = reported.contains { !$0.hasSuffix(".jsonl") } ? reported + watched : reported
        var events: [AgentEvent] = []
        for path in Set(paths) where path.hasSuffix(".jsonl") && path.hasPrefix(root.path + "/") {
            let url = URL(fileURLWithPath: path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) else { files[path] = nil; continue }
            var tracked = files[path] ?? Tracked()
            if size < tracked.offset { tracked = Tracked() }   // Rewritten from scratch.
            guard size > tracked.offset else { continue }
            let data = read(url, from: tracked.offset, count: Int(size - tracked.offset))
            // Keep a partly written last line for next time.
            guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = data[data.startIndex...end]
            tracked.offset += UInt64(complete.count)
            tracked.lastWrite = Date()
            events += tracked.reader.consume(lines(Data(complete), dropFirstPartial: false))
            files[path] = tracked
        }
        guard !events.isEmpty else { return }
        if events.contains(where: { names[$0.sessionID] == nil }) { names = loadNames() }
        onEvents(events.map { var event = $0; event.title = names[event.sessionID]; return event })
        // Codex names a thread a few seconds after its first turn starts.
        for event in events where event.kind == .working && names[event.sessionID] == nil {
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.lookUpName(event.sessionID) }
        }
        scheduleStaleCheck()
        schedulePoll()
    }

    /// Codex keeps a session's file open while it appends, and macOS doesn't always report
    /// those writes. So while a turn runs (and briefly after any write), the open files are
    /// checked every few seconds: one size check each, nothing while Codex is idle.
    private var watched: [String] {
        files.filter { !$0.value.reader.isSubagent && ($0.value.reader.turnOpen || Date().timeIntervalSince($0.value.lastWrite) < 120) }.map(\.key)
    }
    private func schedulePoll() {
        if watched.isEmpty { poll?.cancel(); poll = nil; return }
        guard poll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let grown = watched.filter { path in
                let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) ?? 0
                return size != files[path]?.offset
            }
            if grown.isEmpty { schedulePoll() } else { changed(grown) }
        }
        timer.resume()
        poll = timer
    }

    private func lookUpName(_ id: String) {
        names = loadNames()
        if let name = names[id] { onTitle(id, name) }
    }

    /// While a turn is open, checks every few minutes that its file is still being written.
    private func scheduleStaleCheck() {
        let open = files.values.contains { $0.reader.turnOpen && !$0.reader.isSubagent }
        if !open { staleCheck?.cancel(); staleCheck = nil; return }
        guard staleCheck == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 120, repeating: 120, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.expireSilentTurns() }
        timer.resume()
        staleCheck = timer
    }

    private func expireSilentTurns() {
        var events: [AgentEvent] = []
        for (path, tracked) in files where tracked.reader.turnOpen && tracked.reader.openQuestions.isEmpty && Date().timeIntervalSince(tracked.lastWrite) > Self.silenceLimit {
            files[path]?.reader.closeTurn()
            if let id = tracked.reader.threadID, let project = tracked.reader.projectPath, !tracked.reader.isSubagent {
                events.append(AgentEvent(provider: .codex, sessionID: id, projectPath: project, kind: .stopped))
            }
        }
        if !events.isEmpty { onEvents(events) }
        scheduleStaleCheck()
    }

    // MARK: Files

    private func loadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: index), data.count < 8 * 1024 * 1024 else { return names }
        return CodexThreadNames.parse(String(decoding: data, as: UTF8.self))
    }

    private func read(_ url: URL, from offset: UInt64, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset); return try handle.read(upToCount: count) ?? Data() } catch { return Data() }
    }

    private func lines(_ data: Data, dropFirstPartial: Bool) -> [Substring] {
        let all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return dropFirstPartial ? Array(all.dropFirst()) : all
    }
}
