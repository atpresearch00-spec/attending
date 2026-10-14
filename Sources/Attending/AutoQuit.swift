import AppKit
import ApplicationServices

/// Quits an app when you close its last window, like Swift Quit. It never quits
/// Attending, Finder or menu bar utilities (DockDoor and the like), skips apps you exclude, and asks apps to quit the normal way,
/// so anything with unsaved work still prompts.
///
/// Closing windows is seen through Accessibility. Every window an app opens is tracked,
/// on any desktop, so it quits only when all of them have closed, none is minimized, and
/// nothing of the app is still on screen.
@MainActor final class AutoQuit: ObservableObject {
    static let protected: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "app.attending.Attending", "app.attending.Attending"]

    @Published var enabled = UserDefaults.standard.bool(forKey: "autoQuit") {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoQuit"); enabled ? start() : stop() }
    }
    /// Bundle IDs that are never quit.
    @Published private(set) var excluded: [String] = UserDefaults.standard.stringArray(forKey: "autoQuitExcluded") ?? []
    @Published private(set) var trusted = AXIsProcessTrusted()

    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: [pid_t: Set<CFHashCode>] = [:]
    private var pending: [pid_t: Task<Void, Never>] = [:]
    private var launchObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?

    func start() {
        trusted = AXIsProcessTrusted()
        guard enabled, trusted else { return }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = launchObserver ?? center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                // Give the app a moment to make its first window.
                Task { try? await Task.sleep(for: .seconds(1.5)); self?.watch(app) }
            }
        }
        quitObserver = quitObserver ?? center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.unwatch(app.processIdentifier) }
        }
    }
    func stop() {
        for pid in Array(observers.keys) { unwatch(pid) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        launchObserver = nil; quitObserver = nil
    }
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }
    func refreshTrust() { let was = trusted; trusted = AXIsProcessTrusted(); if trusted && !was { start() } }

    // MARK: Exclusions

    func exclude(_ bundleID: String) {
        guard !excluded.contains(bundleID) else { return }
        excluded.append(bundleID); save()
    }
    func include(_ bundleID: String) { excluded.removeAll { $0 == bundleID }; save() }
    /// Lets the user pick apps from Applications to exclude.
    func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Never Quit"
        NSApp.activate()
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            MainActor.assumeIsolated { for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { self?.exclude(id) } } }
        }
    }
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    private func save() { UserDefaults.standard.set(excluded, forKey: "autoQuitExcluded") }
    private func isSkipped(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return true }
        return app.activationPolicy != .regular || Self.protected.contains(id) || excluded.contains(id) || app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || isMenuBarApp(app)
    }
    private var menuBarApps: [String: Bool] = [:]
    /// Menu bar and background utilities (DockDoor, Raycast, Rectangle…) say so in their
    /// Info.plist. They're never quit, even while one briefly shows a settings or setup
    /// window as a regular app: closing that window isn't quitting the utility.
    private func isMenuBarApp(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, let url = app.bundleURL else { return false }
        if let known = menuBarApps[id] { return known }
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        func flag(_ key: String) -> Bool { (info[key] as? Bool) ?? ((info[key] as? NSNumber)?.boolValue ?? ((info[key] as? String).map { $0 == "1" || $0.lowercased() == "yes" || $0.lowercased() == "true" } ?? false)) }
        let value = flag("LSUIElement") || flag("LSBackgroundOnly")
        menuBarApps[id] = value
        return value
    }

    // MARK: Watching windows

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard enabled, observers[pid] == nil, !isSkipped(app), !app.isTerminated else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let quitter = Unmanaged<AutoQuit>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let name = notification as String
            MainActor.assumeIsolated { quitter.handle(name, element: element, pid: pid) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        for window in Self.windows(of: pid) { track(window, pid: pid) }
    }
    private func unwatch(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        watchedWindows[pid] = nil
        pending.removeValue(forKey: pid)?.cancel()
    }
    private func track(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid], watchedWindows[pid, default: []].insert(CFHash(window)).inserted else { return }
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
    }
    private func handle(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXWindowCreatedNotification:
            pending.removeValue(forKey: pid)?.cancel()
            track(element, pid: pid)
        case kAXUIElementDestroyedNotification:
            watchedWindows[pid]?.remove(CFHash(element))
            // Wait a beat: apps often close one window and open another (a sheet, a new document).
            pending[pid]?.cancel()
            pending[pid] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.quitIfWindowless(pid)
            }
        default: break
        }
    }
    private func quitIfWindowless(_ pid: pid_t) {
        pending[pid] = nil
        guard enabled, let app = NSRunningApplication(processIdentifier: pid), !isSkipped(app), !app.isTerminated else { return }
        guard watchedWindows[pid, default: []].isEmpty, Self.windows(of: pid).isEmpty, !Self.hasVisibleWindows(pid) else { return }
        app.terminate()
    }

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { return [] }
        return list
    }
    /// Normal windows of the app on screen now. (Apps such as TextEdit keep hidden offscreen
    /// windows after the last document closes, so offscreen ones don't count; windows on
    /// other desktops are covered by tracking every window the app opens.)
    private static func hasVisibleWindows(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            // Ignore tiny helper windows apps keep offscreen.
            return (bounds["Width"] ?? 0) > 120 && (bounds["Height"] ?? 0) > 80 && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
    }
}
