import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import AttendingCore

enum Tab: String, CaseIterable { case home, agents, assistant, study, shelf, clipboard, mirror, settings
    var symbol: String {
        switch self { case .home: "square.grid.2x2"; case .agents: "terminal"; case .assistant: "sparkles"; case .study: "graduationcap"; case .shelf: "tray"; case .clipboard: "doc.on.clipboard"; case .mirror: "camera"; case .settings: "gearshape" }
    }
    var title: String {
        switch self { case .home: "Home"; case .agents: "Agents"; case .assistant: "Ask AI"; case .study: "Study"; case .shelf: "Shelf"; case .clipboard: "Clipboard"; case .mirror: "Mirror"; case .settings: "Settings" }
    }
}

/// A short-lived banner the notch drops down for agent, timer and device events.
struct NotchAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String
    var symbol: String
    var color: Color
    var target: Tab = .agents
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var image: NSImage?
    var fileURL: URL?
    static func == (a: NotchAlert, b: NotchAlert) -> Bool { a.id == b.id }
}

@MainActor final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var mode: PanelMode = .idle
    @Published var error: String?
    @Published var selectedTab: Tab = .home
    @Published var alert: NotchAlert?
    @Published var dropTargeted = false
    /// A file drag is hovering the notch: the preview shows drop targets instead.
    @Published var dragActive = false
    /// The pointer is over one of those drop targets.
    var dropZoneTargeted = false
    let airDropSender = AirDropSender()
    @Published var assistantFocus = 0
    @Published var notchHeight: CGFloat = 0
    @Published var notchWidth: CGFloat = 0
    /// Island position inside the panel window (SwiftUI coordinates). Animated by the
    /// window controller so every size change springs instead of jumping.
    @Published var islandFrame: CGRect = .zero
    /// The mode currently drawn; lags `mode` only by the animation transaction.
    @Published var shownMode: PanelMode = .idle
    @Published var hud: HUDState?
    var pointerInside = false
    var pickerOpen = false
    /// Tab icon frames in the panel's SwiftUI coordinates, for hover switching.
    var tabFrames: [Tab: CGRect] = [:]
    /// Set by the development snapshot tool so auto-close doesn't interfere.
    var holdOpen = false
    var lastTypingAt = Date.distantPast
    private var hudTask: Task<Void, Never>?
    private var alertOpenedPanel = false
    private var alertTask: Task<Void, Never>?
    let media = MediaController()
    let volume = SystemVolume()
    let calendar = CalendarService()
    let timer = FocusTimer()
    let shelf = ShelfStore()
    let assistant = AssistantController()
    let battery = BatteryMonitor()
    let usage = UsageMonitor()
    let clipboard = ClipboardHistory()
    let weather = WeatherService()
    let mirror = MirrorController()
    let mediaKeys = MediaKeyTap()
    let anki = AnkiService()
    let exams = ExamStore()
    let sheets = SheetTracker()
    let salah = SalahTracker()
    let updater = Updater()
    let drives = VolumeMonitor()
    let outlook = OutlookService()
    let launcher = LauncherStore()
    let meeting = MeetingMonitor()
    let screenshots = ScreenshotWatcher()
    let activities = ActivityCenter()
    private var sessionTask: Task<Void, Never>?
    private var wasWorking = false
    @Published var awake = true
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var providers: [ProviderDescriptor] = []
    @Published var claudeDetected = false
    @Published var codexDetected = false
    @Published var loginStatus = SMAppService.mainApp.status
    @AppStorage("showPet") var showPet = true
    @AppStorage("completionNotifications") var completionNotifications = true
    @AppStorage("hoverDelay") var hoverDelay = 0.25
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("debugLogging") var debugLogging = false
    @AppStorage("agentAlerts") var agentAlerts = true
    @AppStorage("alertSounds") var alertSounds = true
    @AppStorage("mediaControls") var mediaControls = true
    @AppStorage("calendarEnabled") var calendarEnabled = false
    @AppStorage("weatherEnabled") var weatherEnabled = false
    @AppStorage("clipboardEnabled") var clipboardEnabled = true
    @AppStorage("hudEnabled") var hudEnabled = true
    @AppStorage("autoClose") var autoClose = true
    @AppStorage("showExams") var showExams = false
    @AppStorage("screenshotDrops") var screenshotDrops = true
    @AppStorage("liveActivities") var liveActivities = true
    @AppStorage("previewGlance") var previewGlance = true
    @AppStorage("salahEnabled") var salahEnabled = true
    @AppStorage("salahAlerts") var salahAlerts = true
    /// Height Home's content needs; every tab shares it so switching never resizes.
    @Published var homeHeight: CGFloat = 540
    @AppStorage("focusStartShortcut") var focusStartShortcut = ""
    @AppStorage("focusEndShortcut") var focusEndShortcut = ""
    let store = StateStore(url: AppPaths.directory.appendingPathComponent("state.json"))
    private var watcher: EventWatcher?
    private var saveTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var storageHealthy = true
    @Published var celebrating = false
    @Published var claudeApprovals: [ApprovalRequest] = []
    @Published var codexApprovals: [CodexTransportApproval] = []
    @Published var codexTurns: [String: CodexTurn] = [:]
    @Published var selectedSessionID: String?
    @Published var draft = ""
    @Published var codexBusy = false
    @Published var responseText: [String: String] = [:]
    private let liveEventsSince = Date()
    private let codex = CodexTransport()
    private let approvalBroker = ApprovalBroker()
    private var adapterTasks: [Task<Void, Never>] = []
    private var codexThreads: [String: CodexOwnedThread] = [:]
    var selectedSession: AgentSession? { state.sessions.first { $0.id == selectedSessionID } }
    var canSendToSelected: Bool {
        guard let session = selectedSession else { return false }
        return providers.first(where: { $0.id == session.provider })?.capabilities.contains(.sendMessage) == true && state.managedCodexProjects?[session.externalID] != nil
    }
    var onProjectPicker: ((Bool) -> Void)?
    var onModeChange: (() -> Void)?
    var active: [AgentSession] { state.sessions.filter { [.working, .attention, .idle].contains($0.status) } }
    var attention: [AgentSession] { state.sessions.filter { $0.status == .attention } }
    var attentionCount: Int {
        var ids = Set(attention.map(\.id))
        for request in claudeApprovals { ids.insert("claudeCode:" + request.sessionID) }
        for request in codexApprovals { ids.insert("codex:" + request.threadID) }
        return ids.count
    }
    var mood: SessionStatus {
        if !attention.isEmpty || !claudeApprovals.isEmpty || !codexApprovals.isEmpty { return .attention }
        if state.sessions.contains(where: { $0.status == .working }) { return .working }
        if celebrating { return .completed }
        if state.sessions.contains(where: { $0.status == .failed }) { return .failed }
        return .idle
    }
    func start() async {
        // Character pets were replaced by refined marks (2026-09-28); older choices migrate once.
        if !UserDefaults.standard.bool(forKey: "petMigratedToStethoscope") {
            UserDefaults.standard.set(PetKind.stethoscope.rawValue, forKey: "pet")
            UserDefaults.standard.set(true, forKey: "petMigratedToStethoscope")
        }
        if mediaControls { media.start() }
        volume.start()
        if calendarEnabled { calendar.start(requestIfNeeded: true) }
        if weatherEnabled { weather.start() }
        if salahEnabled { salah.start() }
        mirror.onPhoto = { [weak self] url in self?.shelf.add([url]) }
        updater.onAvailable = { [weak self] release in
            self?.raise(NotchAlert(title: "Attending \(release.version) is available", subtitle: "You have \(self?.updater.current ?? "")", symbol: "arrow.down.circle.fill", color: Theme.working, target: .settings,
                                   actionTitle: "Update", action: { [weak self] in self?.updater.install(); self?.alert = nil }))
        }
        updater.start()
        airDropSender.onSent = { [weak self] urls in
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            self?.raise(NotchAlert(title: "Sent with AirDrop", subtitle: what, symbol: "checkmark.circle.fill", color: Theme.done, target: .shelf), sound: "Glass")
        }
        airDropSender.onFailed = { [weak self] message in
            self?.raise(NotchAlert(title: "AirDrop didn't send", subtitle: message, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf), sound: "Basso")
        }
        salah.onPrayerTime = { [weak self] prayer, time in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "Time for \(prayer.title)", subtitle: "\(time.formatted(date: .omitted, time: .shortened))\(salah.place.map { " in \($0)" } ?? "")", symbol: "moon.stars.fill", color: Theme.done, target: .home,
                             actionTitle: "Prayed", action: { [weak self] in self?.salah.toggle(prayer); self?.alert = nil }), sound: "Glass")
        }
        salah.onEndingSoon = { [weak self] prayer, end in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "\(prayer.title) ends in 15 minutes", subtitle: "Until \(end.formatted(date: .omitted, time: .shortened))", symbol: "hourglass", color: Theme.attention, target: .home,
                             actionTitle: "Prayed", action: { [weak self] in self?.salah.toggle(prayer); self?.alert = nil }), sound: "Tink")
        }
        if clipboardEnabled { clipboard.start() }
        usage.start()
        assistant.onClaudeLoaded = { [weak self] in self?.usage.refreshFromClaude() }
        usage.onThreshold = { [weak self] percent, resets in
            let when = resets.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            self?.raise(NotchAlert(title: "Claude usage at \(percent)%", subtitle: "5-hour limit\(when)", symbol: "gauge.with.dots.needle.67percent", color: percent >= 95 ? Theme.failed : Theme.attention, target: .home), sound: "Tink")
        }
        battery.onChange = { [weak self] pluggedIn, low in
            guard let self, let level = battery.level else { return }
            if pluggedIn { showHUD(HUDState(kind: .battery, value: Double(level) / 100, symbol: "bolt.fill", tint: Theme.done, label: "\(level)%")) }
            else if let low { showHUD(HUDState(kind: .battery, value: Double(low) / 100, symbol: "battery.25percent", tint: Theme.failed, label: "\(low)% left")) }
        }
        battery.start()
        calendar.onImminent = { [weak self] event in
            var alert = NotchAlert(title: "\(event.title) in 5 minutes", subtitle: event.start.formatted(date: .omitted, time: .shortened), symbol: "calendar", color: Theme.working, target: .home)
            if let url = event.joinURL { alert.actionTitle = "Join"; alert.action = { NSWorkspace.shared.open(url) } }
            self?.raise(alert, sound: "Tink")
        }
        volume.onBluetoothOutput = { [weak self] name in
            Task { @MainActor in
                guard let levels = await HeadphoneBattery.lookup(named: name) else { return }
                var parts: [String] = []
                if let left = levels.left { parts.append("L \(left)%") }
                if let right = levels.right { parts.append("R \(right)%") }
                if let caseLevel = levels.caseLevel { parts.append("Case \(caseLevel)%") }
                if parts.isEmpty, let main = levels.main { parts.append("\(main)%") }
                let lowest = [levels.left, levels.right, levels.main].compactMap { $0 }.min() ?? 100
                self?.showHUD(HUDState(kind: .headphones, value: Double(lowest) / 100, symbol: HeadphoneBattery.symbol(for: name),
                                       tint: lowest <= 20 ? Theme.failed : Theme.primary, label: parts.joined(separator: "  ")), seconds: 4)
            }
        }
        mediaKeys.onVolume = { [weak self] delta in
            guard let self else { return }
            if let delta { volume.set(volume.level + delta) } else { volume.toggleMute() }
            showHUD(HUDState(kind: .volume, value: volume.muted ? 0 : Double(volume.level), symbol: volume.muted || volume.level == 0 ? "speaker.slash.fill" : volume.level < 0.34 ? "speaker.wave.1.fill" : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill", tint: Theme.primary))
        }
        mediaKeys.onBrightness = { [weak self] delta in
            guard let self, let current = DisplayBrightness.current else { return }
            let next = min(1, max(0, current + delta))
            DisplayBrightness.set(next)
            showHUD(HUDState(kind: .brightness, value: Double(next), symbol: next < 0.4 ? "sun.min.fill" : "sun.max.fill", tint: Theme.amber))
        }
        if hudEnabled { mediaKeys.start() }
        anki.start()
        outlook.start()
        meeting.start()
        drives.onMount = { [weak self] volume in
            guard let self else { return }
            raise(NotchAlert(title: "\(volume.name) connected", subtitle: volume.available.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free" } ?? "External drive", symbol: "externaldrive.fill", color: Theme.working, target: .home, actionTitle: "Eject", action: { [weak self] in self?.drives.eject(volume) }), sound: "Tink")
        }
        sheets.onGoalMet = { [weak self] summary, goal in
            let days = summary.daysLeft ?? 0
            self?.raise(NotchAlert(title: "Today's reading is done", subtitle: "\(goal.done) pages for \(summary.shortName) · \(days == 1 ? "1 day" : "\(days) days") to go", symbol: "book.closed.fill", color: Theme.done, target: .study), sound: "Glass")
        }
        drives.onEjectResult = { [weak self] name, error in
            if let error { self?.raise(NotchAlert(title: "\(name) couldn't eject", subtitle: error, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .home), sound: "Basso") }
            else { self?.showHUD(HUDState(kind: .battery, value: 1, symbol: "eject.fill", tint: Theme.done, label: "Safe to unplug")) }
        }
        drives.start()
        drives.onChange = { [weak self] in if self?.liveActivities == true { self?.activities.restartExportWatch() } }
        screenshots.onCapture = { [weak self] url in self?.screenshotTaken(url) }
        if screenshotDrops { screenshots.start() }
        activities.onFinished = { [weak self] activity in
            guard let self else { return }
            let export = activity.kind == .export
            var alert = NotchAlert(title: export ? "\(activity.appName.map { "\($0) render" } ?? "Export") finished" : "Download finished",
                                   subtitle: "\(activity.name) · \(activity.sizeText)", symbol: export ? "film.fill" : "arrow.down.circle.fill", color: Theme.done, target: .home)
            alert.image = ActivityCenter.icon(for: activity)
            alert.fileURL = activity.url
            alert.actionTitle = "Show"
            alert.action = { [weak self] in self?.activities.reveal(activity) }
            raise(alert, sound: "Glass")
        }
        if liveActivities { activities.start() }
        timer.onPhaseChange = { [weak self] session in
            let focus = session.phase == .focus
            self?.raise(NotchAlert(title: focus ? "Back to focus" : "\(session.phase.title) time", subtitle: focus ? "Cycle \(session.cycle) of \(session.cycles)" : "\(Int(session.phase == .longBreak ? session.longBreakMinutes : session.breakMinutes)) minutes. Stand up and stretch.", symbol: focus ? "brain.head.profile" : "cup.and.saucer.fill", color: focus ? Theme.done : Theme.working, target: .study), sound: focus ? "Hero" : "Glass")
        }
        timer.onSessionComplete = { [weak self] session in
            guard let self else { return }
            sessionTask?.cancel()
            let minutes = Int(Date().timeIntervalSince(session.startedAt) / 60)
            let reviews = session.reviewGoal != nil ? "\(session.reviewsDone) reviews in " : ""
            raise(NotchAlert(title: "Session complete", subtitle: "\(reviews)\(minutes) min. Nice work.", symbol: "checkmark.seal.fill", color: Theme.done, target: .study), sound: "Glass")
            anki.refresh()
        }
        timer.onFinish = { [weak self] in
            guard let self else { return }
            raise(NotchAlert(title: "\(timer.label) complete", subtitle: "Time for a break", symbol: "timer", color: Theme.done, target: .home), sound: "Glass")
        }
        do { state = try await store.load(); state.markDisconnected() }
        catch { storageHealthy = false; self.error = "Saved state could not be read. It has been preserved. Clear history in Settings to start fresh." }
        claudeDetected = FileManager.default.isExecutableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path) || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude")
        codexDetected = FileManager.default.isExecutableFile(atPath: codex.executableURL.path)
        providers = [
            .init(id: .claudeCode, capabilities: [.observe, .openProject], detail: "Documented hooks · monitoring requires hook installation"),
            codex.descriptor,
            .init(id: .chatGPT, capabilities: [], detail: "No consumer session-control API; links only in a future adapter.")
        ]
        await startAdapters()
        do {
            watcher = try EventWatcher(directory: AppPaths.events) { [weak self] events in
                Task { @MainActor in self?.receive(events) }
            }
        } catch { self.error = "Cannot monitor agent events: \(error.localizedDescription)" }
    }
    func startAdapters() async {
        do {
            try await approvalBroker.start()
            adapterTasks.append(Task { [weak self] in
                guard let self else { return }
                for await requests in approvalBroker.snapshots {
                    let known = Set(claudeApprovals.map(\.id))
                    claudeApprovals = requests
                    if let fresh = requests.first(where: { !known.contains($0.id) }) {
                        raise(NotchAlert(title: "Claude Code needs approval", subtitle: "\(fresh.toolName) · \(URL(fileURLWithPath: fresh.projectPath).lastPathComponent)", symbol: "hand.raised.fill", color: Theme.attention), sound: "Ping", agent: true)
                    }
                }
            })
        } catch { self.error = "Approval relay unavailable: \(error.localizedDescription)" }
        adapterTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in codex.events() { receive([event]) }
        })
        adapterTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in codex.transportEvents() {
                switch event {
                case .text(let threadID, _, let delta):
                    responseText[threadID] = String(((responseText[threadID] ?? "") + delta).suffix(16_000))
                case .summary(let threadID, _, let text): responseText[threadID] = String(text.suffix(16_000))
                case .turn(let threadID, let turnID, let active):
                    if active { codexTurns[threadID] = CodexTurn(id: turnID, threadID: threadID) }
                    else { codexTurns.removeValue(forKey: threadID) }
                case .approval(let request):
                    codexApprovals.append(request)
                    raise(NotchAlert(title: "Codex needs approval", subtitle: request.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Permission request", symbol: "hand.raised.fill", color: Theme.attention), sound: "Ping", agent: true)
                case .approvalResolved(let id): codexApprovals.removeAll { $0.id == id }
                case .diagnostic(let text): error = text
                }
            }
        })
    }
    func newCodexProject() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Use Project"
        onProjectPicker?(true)
        NSApp.activate()
        picker.begin { [weak self] result in
            self?.onProjectPicker?(false)
            guard result == .OK, let url = picker.url else { return }
            Task { @MainActor in await self?.createCodexProject(path: url.path) }
        }
    }
    func createCodexProject(path: String) async {
        codexBusy = true; defer { codexBusy = false }
        do {
            let thread = try await codex.start(projectPath: path)
            codexThreads[thread.id] = thread
            if state.managedCodexProjects == nil { state.managedCodexProjects = [:] }
            state.managedCodexProjects?[thread.id] = path
            selectedSessionID = ProviderID.codex.rawValue + ":" + thread.id
            receive([.init(provider: .codex, sessionID: thread.id, projectPath: path, kind: .started)])
            selectedTab = .agents
        } catch { self.error = "Codex connection: \(error.localizedDescription)" }
    }
    func sendDraft() {
        guard let session = selectedSession, canSendToSelected, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !codexBusy else { return }
        let text = draft
        codexBusy = true
        Task {
            defer { codexBusy = false }
            do {
                let thread: CodexOwnedThread
                if let loaded = codexThreads[session.externalID] { thread = loaded }
                else {
                    thread = try await codex.resume(CodexOwnedThread(id: session.externalID, projectPath: session.projectPath))
                    codexThreads[thread.id] = thread
                }
                if let turn = codexTurns[thread.id] { _ = try await codex.steer(in: thread, turn: turn, prompt: text) }
                else {
                    responseText[thread.id] = ""
                    let turn = try await codex.startTurn(in: thread, prompt: text)
                    codexTurns[thread.id] = turn
                }
                if draft == text { draft = "" }
            } catch { self.error = "Instruction was not sent: \(error.localizedDescription)" }
        }
    }
    func stopSelectedTurn() {
        guard let session = selectedSession, let thread = codexThreads[session.externalID], let turn = codexTurns[session.externalID] else { return }
        Task { do { try await codex.interrupt(in: thread, turn: turn) } catch { self.error = error.localizedDescription } }
    }
    func respondClaude(_ request: ApprovalRequest, decision: ApprovalDecision) {
        Task {
            let accepted = await approvalBroker.respond(to: request.id, decision: decision)
            claudeApprovals.removeAll { $0.id == request.id }
            if accepted { receive([.init(provider: request.provider, sessionID: request.sessionID, projectPath: request.projectPath, kind: .working)]) }
            if !accepted { error = "This permission request expired or disconnected. Respond in Claude Code." }
        }
    }
    func respondCodex(_ request: CodexTransportApproval, decision: CodexApprovalDecision) {
        Task {
            do { try await codex.respond(to: request, decision: decision); codexApprovals.removeAll { $0.id == request.id } }
            catch { self.error = "Permission response: \(error.localizedDescription)" }
        }
    }
    func receive(_ events: [AgentEvent]) {
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            if event.provider == .codex && event.kind == .ended {
                codexThreads.removeValue(forKey: event.sessionID)
                codexTurns.removeValue(forKey: event.sessionID)
            }
            let old = state
            state.apply(event, liveEventsSince: liveEventsSince)
            if state != old && event.timestamp >= liveEventsSince && event.kind == .completed && completionNotifications {
                celebrating = true
                completionTask?.cancel()
                completionTask = Task { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled else { return }; celebrating = false }
            }
            if state != old && event.timestamp >= liveEventsSince, let session = state.sessions.first(where: { $0.id == event.provider.rawValue + ":" + event.sessionID }) {
                switch event.kind {
                case .completed: raise(NotchAlert(title: "\(event.provider.title) finished", subtitle: session.title, symbol: "checkmark.circle.fill", color: Theme.done), sound: "Glass", agent: true)
                case .attention: raise(NotchAlert(title: "\(event.provider.title) needs you", subtitle: session.title, symbol: "exclamationmark.circle.fill", color: Theme.attention), sound: "Ping", agent: true)
                case .failed: raise(NotchAlert(title: "\(event.provider.title) hit an error", subtitle: session.title, symbol: "xmark.octagon.fill", color: Theme.failed), sound: "Basso", agent: true)
                default: break
                }
            }
        }
        updateWorkingAutomation()
        persist()
    }
    /// Runs the user's Focus shortcuts as agents start and stop working.
    private func updateWorkingAutomation() {
        let working = state.sessions.contains { $0.status == .working }
        guard working != wasWorking else { return }
        wasWorking = working
        ShortcutRunner.run(working ? focusStartShortcut : focusEndShortcut)
    }
    func persist() {
        guard storageHealthy else { return }
        let snapshot = state
        // One ordered task chain prevents an older snapshot overwriting a newer one.
        let prior = saveTask
        saveTask = Task {
            await prior?.value
            do { try await store.save(snapshot) } catch { self.error = "Could not save Attending state: \(error.localizedDescription)" }
        }
    }
    func shutdown() async {
        media.stop()
        activities.stop()
        mediaKeys.stop()
        mirror.stop()
        for task in adapterTasks { task.cancel() }
        await approvalBroker.stop()
        await codex.shutdown()
        await saveTask?.value
    }
    func clearHistory() {
        let pendingIDs = Set(claudeApprovals.map { "claudeCode:" + $0.sessionID } + codexApprovals.map { "codex:" + $0.threadID })
        state.sessions.removeAll { ![.working, .attention, .idle].contains($0.status) && !pendingIDs.contains($0.id) }
        let kept = Set(state.sessions.filter { $0.provider == .codex }.map(\.externalID))
        state.managedCodexProjects = state.managedCodexProjects?.filter { kept.contains($0.key) }
        responseText = responseText.filter { kept.contains($0.key) }
        codexThreads = codexThreads.filter { kept.contains($0.key) }
        if selectedSession == nil { selectedSessionID = nil; draft = "" }
        storageHealthy = true; persist()
    }
    func setMode(_ value: PanelMode) {
        if value != .preview { alertOpenedPanel = false }
        mode = value; onModeChange?()
    }
    func open(_ tab: Tab) { selectedTab = tab; alert = nil; setMode(.expanded) }

    // MARK: Drag and drop

    /// A file drag reached the notch. Collapsed or peeking, the island drops a compact
    /// panel of targets (AirDrop, Shelf, Drive) right under the pointer; expanded, the
    /// drop goes wherever it's aimed.
    func dragChanged(targeted: Bool) {
        if targeted {
            dragExitTask?.cancel()
            if mode != .expanded && !dragActive { dragActive = true; alert = nil; setMode(.preview) }
        } else if dragActive {
            // Moving between targets briefly leaves them all; only close if the drag really left.
            dragExitTask?.cancel()
            dragExitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, dragActive, !dropTargeted, !dropZoneTargeted else { return }
                dragActive = false
                if !pointerInside { setMode(.idle) }
            }
        }
    }
    private var dragExitTask: Task<Void, Never>?
    func dropOnShelf(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        shelf.add(urls)
        finishDrop()
        raise(NotchAlert(title: "On your Shelf", subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", symbol: "tray.and.arrow.down.fill", color: Theme.working, target: .shelf))
    }
    /// The island tucks away so the AirDrop window has the screen.
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        finishDrop()
        setMode(.idle)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            airDropSender.send(urls)
        }
    }
    func saveToDrive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        finishDrop()
        raise(NotchAlert(title: "Google Drive", subtitle: GoogleDrive.save(urls), symbol: "externaldrive.badge.icloud", color: Theme.working, target: .shelf))
    }
    private func finishDrop() { dragExitTask?.cancel(); dragActive = false; dropZoneTargeted = false }
    func openAssistant() { open(.assistant); assistantFocus += 1 }

    /// Drops a banner out of the notch for a few seconds, then tucks it away
    /// unless the pointer is resting on it.
    func raise(_ next: NotchAlert, sound: String? = nil, agent: Bool = false) {
        // The Settings toggle covers agent events; timers, screenshots and drives always show.
        guard awake, agentAlerts || !agent else { return }
        alert = next
        if alertSounds, let sound { NSSound(named: sound)?.play() }
        if mode == .idle { alertOpenedPanel = true; setMode(.preview) }
        alertTask?.cancel()
        alertTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            alert = nil
            if mode == .preview && alertOpenedPanel && !pointerInside { setMode(.idle) }
        }
    }
    func setMediaControls(_ enabled: Bool) {
        mediaControls = enabled
        if enabled { media.start() } else { media.stop() }
    }
    /// Starts a Pomodoro session and, with a review goal, tracks Anki progress live.
    func startStudySession(focus: Double, breakMinutes: Double, goal: Int?, openAnki: Bool) {
        sessionTask?.cancel()
        // The baseline comes from a fresh count on the first poll, never the cached stats.
        timer.startSession(focus: focus, breakMinutes: breakMinutes, longBreak: max(15, breakMinutes * 3), reviewGoal: goal, reviewBaseline: nil)
        if openAnki { anki.openAnki() }
        guard goal != nil else { return }
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, timer.session != nil else { return }
                if let today = await anki.reviewsToday() {
                    if timer.session?.reviewBaseline == nil { timer.startSessionBaseline(today) }
                    timer.updateReviews(today: today)
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
    private func screenshotTaken(_ url: URL) {
        shelf.add([url])
        let image = NSImage(contentsOf: url)
        let recording = url.lastPathComponent.hasPrefix("Screen Recording")
        var alert = NotchAlert(title: recording ? "Screen recording saved" : "Screenshot saved", subtitle: "On your Shelf · drag it anywhere", symbol: "camera.viewfinder", color: Theme.working, target: .shelf)
        alert.image = image
        alert.fileURL = url
        if let image {
            alert.actionTitle = "Copy"
            alert.action = {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        raise(alert)
    }
    func setLiveActivities(_ enabled: Bool) {
        liveActivities = enabled
        if enabled { activities.start() } else { activities.stop() }
    }
    func setScreenshotDrops(_ enabled: Bool) {
        screenshotDrops = enabled
        if enabled { screenshots.start() } else { screenshots.stop() }
    }
    func setWeather(_ enabled: Bool) {
        weatherEnabled = enabled
        if enabled { weather.start() } else { weather.stop() }
    }
    func setSalah(_ enabled: Bool) {
        salahEnabled = enabled
        if enabled { salah.start() } else { salah.stop() }
    }
    func setClipboard(_ enabled: Bool) {
        clipboardEnabled = enabled
        if enabled { clipboard.start() } else { clipboard.stop(); clipboard.clear() }
    }
    func setHUD(_ enabled: Bool) {
        hudEnabled = enabled
        if enabled { mediaKeys.trusted ? mediaKeys.start() : mediaKeys.requestPermission() } else { mediaKeys.stop() }
    }
    /// Briefly widens the collapsed wings to show a level (volume, brightness, battery).
    func showHUD(_ state: HUDState, seconds: Double = 1.6) {
        guard awake else { return }
        hud = state
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }
    /// Pastes a clipboard item into the app the user was in.
    func paste(_ item: ClipItem) {
        clipboard.copy(item)
        setMode(.idle)
        guard AXIsProcessTrusted() else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // V
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
    func setCalendar(_ enabled: Bool) {
        calendarEnabled = enabled
        if enabled { calendar.start(requestIfNeeded: true) }
    }

    // MARK: Layout

    var showsMedia: Bool { mediaControls && media.track != nil }
    /// What the hover preview's glance shows: small tiles (next event, exam, Anki,
    /// Claude usage) and the next unread chapter from the exam tracker.
    var glanceTiles: Int {
        guard previewGlance else { return 0 }
        var count = 0
        if calendarEnabled && calendar.next != nil { count += 1 }
        if sheets.primary != nil || (showExams && exams.next != nil) { count += 1 }
        if anki.stats != nil { count += 1 }
        if usage.fiveHour != nil { count += 1 }
        return count
    }
    var glanceReading: (tracker: SheetTracker.Tracker, item: SheetTracker.Item)? {
        guard previewGlance, let primary = sheets.primaryTracker, let item = primary.summary.pending.first else { return nil }
        return (primary.tracker, item)
    }
    /// Width of each wing beside the notch. Both wings match so the island stays centered.
    var idleWing: CGFloat {
        if let hud { return hud.kind == .headphones ? 132 : 96 }
        if let meeting = calendar.imminent { return max(34, 20 + 66 + (meeting.joinURL != nil ? 26 : 0) + (active.isEmpty ? 0 : 18)) }
        var items: [CGFloat] = []
        if showsMedia && media.track?.playing == true { items.append(12) }
        if timer.isActive { items.append(36) }
        if !active.isEmpty { items.append(12) }
        if meeting.micInUse { items.append(14) }
        if liveActivities && !activities.running.isEmpty { items.append(14) }
        let content = items.reduce(0, +) + CGFloat(max(0, items.count - 1)) * 6
        return max(34, content + 20)
    }
    /// Total panel size including the band hidden behind the hardware notch.
    var panelSize: CGSize {
        let band = notchHeight > 0 ? notchHeight : 34
        switch mode {
        case .idle: return CGSize(width: 2 * idleWing + notchWidth, height: band)
        case .preview:
            var height: CGFloat = 20
            if dragActive { return CGSize(width: max(480, notchWidth + 250), height: band + 118) }
            if alert != nil { height += 58 }
            else {
                if liveActivities { height += CGFloat(min(activities.visible.count, 2)) * 50 }
                if showsMedia { height += 82 }
                let glance = (glanceTiles > 0 ? 54 : 0) + (glanceReading != nil ? 38 : 0)
                height += active.isEmpty && !showsMedia && glance == 0 ? 44 : CGFloat(min(active.count, showsMedia ? 1 : 2)) * 46
                height += CGFloat(glance)
                if timer.isActive { height += 40 }
            }
            return CGSize(width: max(glanceTiles >= 4 ? 480 : 440, notchWidth + 250), height: band + height)
        case .expanded:
            // One height for every tab, sized to Home's content: switching tabs never
            // resizes the window, so nothing behind the island can flash through.
            // Other tabs scroll within it.
            return CGSize(width: max(680, notchWidth + 440), height: band + 24 + min(540, max(400, homeHeight)))
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Login registration: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
}

// Dedicated queue plus kernel directory notifications: no idle polling or main-thread I/O.
final class EventWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "attending.events", qos: .utility)
    private let source: DispatchSourceFileSystemObject
    private let directory: URL
    private let callback: @Sendable ([AgentEvent]) -> Void
    init(directory: URL, callback: @escaping @Sendable ([AgentEvent]) -> Void) throws {
        self.directory = directory; self.callback = callback
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        queue.async { [weak self] in self?.drain() }
    }
    deinit { source.cancel() }
    private func drain() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
        var events: [AgentEvent] = []
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 16_384 else { continue }
            if let data = try? Data(contentsOf: file), let event = try? JSONDecoder().decode(AgentEvent.self, from: data), event.validate() { events.append(event) }
            try? FileManager.default.removeItem(at: file)
        }
        if !events.isEmpty { callback(events) }
    }
}
