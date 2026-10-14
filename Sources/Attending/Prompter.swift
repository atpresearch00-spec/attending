import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import AttendingCore

/// A teleprompter right under the camera, so you read while looking at it. The script
/// scrolls at a set speed in a strip that grows out of the notch; hovering pauses it, the
/// trackpad nudges it, and it's left out of screen sharing and recordings.
@MainActor final class Prompter: ObservableObject {
    static var url: URL { AppPaths.directory.appendingPathComponent("prompter.txt") }

    @Published var script = Prompter.load() { didSet { if persists { scheduleSave() } } }
    /// Off for the development demo, so its sample isn't saved.
    var persists = true
    @Published var wordsPerMinute = UserDefaults.standard.object(forKey: "prompterSpeed") as? Double ?? 140 {
        willSet { sync() }
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "prompterSpeed"); sync() }
    }
    @Published var fontSize = UserDefaults.standard.object(forKey: "prompterSize") as? Double ?? 24 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "prompterSize"); relayout() }
    }
    @Published var lines = UserDefaults.standard.object(forKey: "prompterLines") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(lines, forKey: "prompterLines"); relayout() }
    }
    @Published var hideFromSharing = UserDefaults.standard.object(forKey: "prompterPrivate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideFromSharing, forKey: "prompterPrivate"); window?.sharingType = hideFromSharing ? .none : .readOnly }
    }
    @Published var pauseOnHover = UserDefaults.standard.object(forKey: "prompterHoverPause") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnHover, forKey: "prompterHoverPause"); hoverHold = hovering && pauseOnHover }
    }

    @Published private(set) var running = false { didSet { sync() } }
    @Published private(set) var paused = false { didSet { sync() } }
    @Published private(set) var countdown: Int? { didSet { sync() } }
    @Published private(set) var finished = false { didSet { sync() } }
    @Published var hovering = false { didSet { hoverHold = hovering && pauseOnHover } }
    private var hoverHold = false { didSet { sync() } }
    var onRunningChange: ((Bool) -> Void)?
    /// Display facts for placing the strip.
    var placement: () -> (screen: NSScreen, notchHeight: CGFloat, notchWidth: CGFloat)? = { nil }

    /// Scroll position: `offset` points, plus the time since `movingSince` at `pointsPerSecond`.
    /// `movingSince` is set exactly while the script is moving; `sync()` folds the motion so
    /// far into `offset` whenever anything that affects it changes.
    private var offset: CGFloat = 0
    private var movingSince: Date?
    /// Height of the laid-out script, measured by the view.
    var contentHeight: CGFloat = 0 {
        willSet { sync() }
        didSet { sync() }
    }
    private var window: NSPanel?
    private var endCheck: Timer?
    private var countdownTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    var words: Int { script.split { $0.isWhitespace }.count }
    var readingTime: String {
        let minutes = Double(words) / max(40, wordsPerMinute)
        return minutes < 1 ? "\(Int((minutes * 60).rounded())) sec" : "\(Int(minutes.rounded())) min"
    }
    var lineHeight: CGFloat { fontSize * 1.55 }
    var viewHeight: CGFloat { CGFloat(lines) * lineHeight }
    private var moving: Bool { running && !paused && !hoverHold && countdown == nil && !finished }
    private var pointsPerSecond: CGFloat {
        guard words > 0, contentHeight > 0 else { return 0 }
        return CGFloat(wordsPerMinute / 60) * contentHeight / CGFloat(words)
    }
    /// The furthest the script scrolls: its last line at the top of the strip.
    var maxOffset: CGFloat { max(0, contentHeight - lineHeight) }

    func position(at date: Date) -> CGFloat {
        let live = movingSince.map { CGFloat(date.timeIntervalSince($0)) * pointsPerSecond } ?? 0
        return min(maxOffset, max(0, offset + live))
    }
    private func sync() {
        let now = Date()
        if movingSince != nil { offset = position(at: now) }
        movingSince = moving ? now : nil
    }

    // MARK: Control

    func start() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        countdown = 3
        offset = 0; finished = false; paused = false
        running = true
        showWindow()
        onRunningChange?(true)
        runCountdown()
    }
    func stop() {
        countdownTask?.cancel(); countdown = nil
        endCheck?.invalidate(); endCheck = nil
        running = false
        window?.orderOut(nil); window = nil
        hovering = false
        onRunningChange?(false)
    }
    func toggle() { running ? stop() : start() }
    func restart() {
        countdown = 3
        offset = 0; finished = false; paused = false
        runCountdown()
    }
    func togglePause() {
        if finished { restart() } else if countdown == nil { paused.toggle() }
    }
    func nudge(_ points: CGFloat) {
        sync()
        offset = min(maxOffset, max(0, offset + points))
        if finished && offset < maxOffset - 1 { finished = false }
    }
    func changeSpeed(by step: Double) { wordsPerMinute = min(260, max(60, wordsPerMinute + step)) }
    private func runCountdown() {
        countdownTask?.cancel()
        endCheck?.invalidate()
        countdown = 3
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                self?.countdown = n
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            self?.watchForEnd()
        }
    }
    private func watchForEnd() {
        endCheck?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.moving, self.maxOffset > 0, self.position(at: Date()) >= self.maxOffset else { return }
                self.finished = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        endCheck = timer
    }

    // MARK: Script

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd, UTType("org.openxmlformats.wordprocessingml.document")!, UTType("net.daringfireball.markdown") ?? .plainText, .pdf]
        panel.prompt = "Use Script"
        NSApp.activate()
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { if let text = Self.text(of: url) { self?.script = text } }
        }
    }
    /// Plain text from a text, Markdown, RTF, Word or PDF file.
    static func text(of url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.string }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil), !attributed.string.isEmpty { return attributed.string }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    static func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func scheduleSave() {
        saveTask?.cancel()
        let text = script
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? text.write(to: Self.url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Window

    static let width: CGFloat = 560
    static let controlsHeight: CGFloat = 34

    private func frame() -> CGRect? {
        guard let place = placement() else { return nil }
        let screen = place.screen.frame
        let width = min(max(Self.width, place.notchWidth + 260), screen.width - 40)
        let top = place.notchHeight > 0 ? place.notchHeight : 0
        let height = top + 10 + viewHeight + Self.controlsHeight
        // Under the notch it hangs from the top edge like the island; elsewhere it sits
        // just below the menu bar, still right under the camera.
        let y = place.notchHeight > 0 ? screen.maxY - height : place.screen.visibleFrame.maxY - 4 - height
        return CGRect(x: screen.midX - width / 2, y: y, width: width, height: height)
    }
    private func showWindow() {
        guard let frame = frame() else { return }
        let panel = PrompterPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false; panel.animationBehavior = .none
        panel.sharingType = hideFromSharing ? .none : .readOnly
        panel.prompter = self
        let notchHeight = placement()?.notchHeight ?? 0
        let host = PrompterHost(rootView: PrompterStrip(prompter: self, notchHeight: notchHeight))
        host.prompter = self
        panel.contentView = host
        panel.orderFrontRegardless()
        window = panel
    }
    private func relayout() {
        guard running, let window, let frame = frame() else { return }
        window.setFrame(frame, display: true)
    }
}

/// Keys work once you click the strip: Space pauses, ↑/↓ change speed, ←/→ jump a line, Esc stops.
final class PrompterPanel: NSPanel {
    weak var prompter: Prompter?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let prompter else { return super.keyDown(with: event) }
            switch event.keyCode {
            case 49: prompter.togglePause()
            case 126: prompter.changeSpeed(by: 10)
            case 125: prompter.changeSpeed(by: -10)
            case 123: prompter.nudge(-prompter.lineHeight)
            case 124: prompter.nudge(prompter.lineHeight)
            case 53: prompter.stop()
            default: super.keyDown(with: event)
            }
        }
    }
}

/// Hover and scroll reach the strip even while another app is active.
final class PrompterHost: NSHostingView<PrompterStrip> {
    weak var prompter: Prompter?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { prompter?.hovering = true } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { prompter?.hovering = false } }
    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            prompter?.nudge(-delta)
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PrompterStrip: View {
    @ObservedObject var prompter: Prompter
    let notchHeight: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + 10)
            ZStack(alignment: .top) {
                TimelineView(.animation(paused: prompter.countdown != nil || prompter.finished)) { context in
                    script.offset(y: -prompter.position(at: context.date))
                }
                .frame(height: prompter.viewHeight, alignment: .top)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                if let n = prompter.countdown {
                    Text("\(n)").font(.system(size: prompter.fontSize * 1.6, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.primary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                }
            }
            .frame(height: prompter.viewHeight)
            controls.frame(height: Prompter.controlsHeight)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IslandShape(ear: notchHeight > 0 ? 10 : 0, radius: 22).fill(Theme.background))
        .clipShape(IslandShape(ear: notchHeight > 0 ? 10 : 0, radius: 22))
        .environment(\.colorScheme, .dark)
    }
    private var script: some View {
        Text(prompter.script)
            .font(.system(size: prompter.fontSize, weight: .medium))
            .lineSpacing(prompter.lineHeight - prompter.fontSize * 1.2)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.primary)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { prompter.contentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in prompter.contentHeight = height }
            })
    }
    private var controls: some View {
        HStack(spacing: 6) {
            if prompter.hovering || prompter.paused || prompter.finished {
                IconButton(symbol: "backward.end.fill", help: "Start over", size: 24) { prompter.restart() }
                IconButton(symbol: "minus", help: "Slower (↓)", size: 24) { prompter.changeSpeed(by: -10) }
                IconButton(symbol: prompter.finished ? "arrow.counterclockwise" : (prompter.paused ? "play.fill" : "pause.fill"), help: "Play or pause (Space)", size: 26, tint: Theme.primary, filled: true) { prompter.togglePause() }
                IconButton(symbol: "plus", help: "Faster (↑)", size: 24) { prompter.changeSpeed(by: 10) }
                Text("\(Int(prompter.wordsPerMinute)) wpm").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 52)
                Spacer()
                if prompter.hideFromSharing { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(Theme.tertiary).help("Hidden from screen sharing and recordings") }
                IconButton(symbol: "xmark", help: "Close (Esc)", size: 24) { prompter.stop() }
            } else {
                Spacer()
                Text(prompter.finished ? "The end" : "Hover to pause").font(.system(size: 10)).foregroundStyle(Theme.tertiary.opacity(0.6))
                Spacer()
            }
        }
    }
}

/// The Prompter tab: write or paste a script, set the pace, start.
struct PrompterView: View {
    @ObservedObject var prompter: Prompter
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(prompter.words == 0 ? "Write or paste your script" : "\(prompter.words) words · about \(prompter.readingTime)")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                PillButton(title: "Open file", symbol: "doc") { prompter.importFile() }
                if !prompter.script.isEmpty { PillButton(title: "Clear", symbol: nil) { prompter.script = "" } }
                PillButton(title: prompter.running ? "Stop" : "Start", symbol: prompter.running ? "stop.fill" : "play.fill", tint: Theme.done, prominent: true) { prompter.toggle() }
                    .disabled(prompter.words == 0)
            }
            TextEditor(text: $prompter.script)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(alignment: .topLeading) {
                    if prompter.script.isEmpty {
                        Text("Your video script, case presentation or talk. It scrolls right under the camera so your eyes stay on the lens.")
                            .font(.system(size: 13)).foregroundStyle(Theme.tertiary).padding(15).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("Speed").foregroundStyle(Theme.secondary)
                    Slider(value: $prompter.wordsPerMinute, in: 60...260, step: 5).frame(width: 110)
                    Text("\(Int(prompter.wordsPerMinute)) wpm").monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 54, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text("Size").foregroundStyle(Theme.secondary)
                    Slider(value: $prompter.fontSize, in: 16...36, step: 1).frame(width: 80)
                }
                Picker("Lines", selection: $prompter.lines) { ForEach(2...6, id: \.self) { Text("\($0) lines").tag($0) } }
                    .labelsHidden().fixedSize()
                Spacer()
            }
            .font(.system(size: 11)).controlSize(.small)
            HStack(spacing: 14) {
                Toggle("Hide from screen sharing", isOn: $prompter.hideFromSharing)
                Toggle("Pause on hover", isOn: $prompter.pauseOnHover)
                Spacer()
            }
            .font(.system(size: 11)).toggleStyle(.checkbox).controlSize(.small)
            Text("While it runs: hover to pause, scroll to move, click it for keys (Space pause, ↑↓ speed, Esc close). The island stays out of the way until you close it.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if prompter.script.isEmpty { focused = true } }
    }
}
