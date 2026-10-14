import AppKit
import ApplicationServices

/// Gets the island out of the way: while something is full screen on its display (a
/// video, a slideshow, a game), and while an app you pick is in front (DaVinci Resolve,
/// whose toolbar sits under the notch). Clicking the menu bar icon still opens it.
@MainActor final class StepAside: ObservableObject {
    /// Video editors keep controls along the top edge of the screen.
    static let defaultApps = ["com.blackmagic-design.DaVinciResolve", "com.apple.FinalCut"]

    @Published var inFullscreen = UserDefaults.standard.object(forKey: "hideInFullscreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inFullscreen, forKey: "hideInFullscreen"); evaluate() }
    }
    @Published var whileUsing = UserDefaults.standard.object(forKey: "hideWhileUsing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(whileUsing, forKey: "hideWhileUsing"); evaluate() }
    }
    /// Bundle IDs; an entry also matches versioned IDs under it (com.adobe.PremierePro.25).
    @Published private(set) var apps: [String] = UserDefaults.standard.stringArray(forKey: "hideForApps") ?? StepAside.defaultApps
    @Published private(set) var hidden = false

    var onChange: ((Bool) -> Void)?
    /// The display the island is on.
    var screen: () -> NSScreen? = { nil }

    private var observers: [NSObjectProtocol] = []
    private var checks: [Task<Void, Never>] = []
    private var poll: Timer?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateSoon() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateSoon() }
        })
        evaluate()
    }

    /// Checks now and again as a full-screen transition finishes (it takes most of a second).
    private func evaluateSoon() {
        evaluate()
        checks.forEach { $0.cancel() }
        checks = [250, 900].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
        }
    }

    func evaluate() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let forApp = whileUsing && front.map(matches) == true
        let forFullscreen = inFullscreen && (screen().map(Self.hasFullscreenWindow) ?? false)
        let next = forApp || forFullscreen
        // Leaving full screen doesn't always switch apps or spaces (a video's Escape key),
        // so check every couple of seconds only while hidden for it.
        if forFullscreen && poll == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        } else if !forFullscreen {
            poll?.invalidate(); poll = nil
        }
        guard next != hidden else { return }
        hidden = next
        onChange?(next)
    }

    func matches(_ bundleID: String) -> Bool {
        apps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    // MARK: Apps

    func add(_ bundleID: String) {
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID); save()
    }
    func remove(_ bundleID: String) { apps.removeAll { $0 == bundleID }; save() }
    func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Hide for These"
        NSApp.activate()
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            MainActor.assumeIsolated { for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { self?.add(id) } } }
        }
    }
    /// Listed apps that are installed (defaults for apps you don't have stay out of the way).
    var installedApps: [String] { apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } }
    private func save() { UserDefaults.standard.set(apps, forKey: "hideForApps"); evaluate() }

    // MARK: Full screen

    /// True when something is full screen on this display: the front app's window in
    /// native full screen (asked through Accessibility), or any app's window covering the
    /// whole display, menu bar included (slideshows, games, editors that take it over).
    static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        let windows = appWindows(on: screen)
        if windows.contains(where: { $0.coversMenuBar }) { return true }
        if AXIsProcessTrusted() { return frontWindowIsFullscreen(on: screen) }
        // Without Accessibility: on notched Macs a full-screen window stops under the notch,
        // the same size as a zoomed one, but it's alone on its space.
        let pids = Set(windows.map(\.pid))
        return pids.count == 1 && windows.contains { $0.fillsBelowMenuBar }
    }

    private struct AppWindow { var pid: pid_t; var coversMenuBar: Bool; var fillsBelowMenuBar: Bool }
    /// Regular apps' normal windows on this display. Overlay tools (cursor highlighters,
    /// automation) run in the background, so they're left out.
    private static func appWindows(on screen: NSScreen) -> [AppWindow] {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        // Window bounds are top-left based, measured from the primary display.
        let frame = screen.frame
        let target = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let menuBar = max(screen.safeAreaInsets.top, frame.maxY - screen.visibleFrame.maxY)
        let me = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var regular: [pid_t: Bool] = [:]
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < menuLevel,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.intersects(target), rect.width > 120, rect.height > 80 else { return nil }
            let isRegular = regular[pid] ?? (NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular)
            regular[pid] = isRegular
            guard isRegular else { return nil }
            let wide = abs(rect.minX - target.minX) < 2 && rect.width >= target.width - 2
            let reachesBottom = abs(rect.maxY - target.maxY) < 2
            return AppWindow(pid: pid,
                             coversMenuBar: wide && reachesBottom && abs(rect.minY - target.minY) < 2,
                             fillsBelowMenuBar: wide && reachesBottom && rect.minY - target.minY <= menuBar + 2)
        }
    }
    /// Whether the front app's focused window is in native full screen on this display.
    private static func frontWindowIsFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?, value: CFTypeRef?, position: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success,
              (value as? Bool) == true else { return false }
        // On the island's display (window positions are top-left based from the primary display).
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &position) == .success, let position,
              let primary = NSScreen.screens.first else { return true }
        var point = CGPoint.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        let frame = screen.frame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height).insetBy(dx: -1, dy: -1).contains(CGPoint(x: point.x + 1, y: point.y + 1))
    }
}
