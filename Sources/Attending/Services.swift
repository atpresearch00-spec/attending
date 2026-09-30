import AppKit
import AVFoundation
import CoreLocation
import SwiftUI
import WebKit
import AttendingCore

// MARK: - Claude usage

/// Claude plan usage as reported by Claude Code to its status line. `attending-bridge
/// --statusline` stores the rate-limit percentages in usage.json; this watches it.
@MainActor final class UsageMonitor: ObservableObject {
    struct Window: Equatable { var used: Double; var resetsAt: Date? }
    @Published private(set) var fiveHour: Window?
    @Published private(set) var sevenDay: Window?
    @Published private(set) var updatedAt: Date?
    var onThreshold: ((_ percent: Int, _ resetsAt: Date?) -> Void)?
    /// Where the numbers came from: Claude Code's status line (Terminal) or claude.ai.
    @Published private(set) var sourceName: String?
    /// True when claude.ai says Attending isn't signed in (Ask AI › Claude).
    @Published private(set) var needsClaudeSignIn = false
    private var source: DispatchSourceFileSystemObject?
    private var web: WKWebView?
    private var webTimer: Timer?
    private var warned: Int = 0
    private var url: URL { AppPaths.directory.appendingPathComponent("usage.json") }

    var configured: Bool { updatedAt != nil }
    var stale: Bool { (updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity) > 6 * 3600 }

    func start() {
        read()
        let directory = AppPaths.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // The bridge replaces usage.json atomically, which is a write to the directory.
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        source = watcher
        // The desktop app never runs Claude Code's status line, so also read claude.ai's
        // own usage (Settings › Usage) every 5 minutes through Attending's Claude sign-in.
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshFromClaude() } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        webTimer = timer
        refreshFromClaude()
    }

    /// Reads plan usage from claude.ai with the session signed in under Ask AI. This is
    /// the endpoint claude.ai's usage page uses — not a documented API — so failures
    /// simply leave the card on its last reading.
    func refreshFromClaude() {
        // A fresh Terminal status line reading takes precedence.
        if sourceName == "Claude Code", let updatedAt, Date().timeIntervalSince(updatedAt) < 600 { return }
        let view = web ?? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
            view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
            web = view
            return view
        }()
        Task {
            if view.url?.host != "claude.ai" {
                view.load(URLRequest(url: URL(string: "https://claude.ai/api/organizations")!))
                for _ in 0..<40 where view.isLoading || view.url?.host != "claude.ai" { try? await Task.sleep(for: .milliseconds(250)) }
            }
            let script = """
            const orgsResponse = await fetch('/api/organizations', {credentials: 'include'});
            if (orgsResponse.status === 401 || orgsResponse.status === 403) return {signedOut: true};
            const orgs = await orgsResponse.json();
            if (!Array.isArray(orgs) || orgs.length === 0) return {signedOut: true};
            const org = orgs.find(o => (o.capabilities || []).some(c => String(c).startsWith('claude_'))) || orgs[0];
            const usage = await (await fetch(`/api/organizations/${org.uuid}/usage`, {credentials: 'include'})).json();
            return usage;
            """
            guard let result = try? await view.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any] else { return }
            if result["signedOut"] as? Bool == true { needsClaudeSignIn = true; return }
            needsClaudeSignIn = false
            func window(_ key: String) -> Window? {
                guard let value = result[key] as? [String: Any], let used = (value["utilization"] as? NSNumber)?.doubleValue else { return nil }
                let reset = (value["resets_at"] as? String).flatMap { ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                return Window(used: min(100, max(0, used)), resetsAt: reset)
            }
            let five = window("five_hour"), week = window("seven_day")
            guard five != nil || week != nil else { return }
            fiveHour = five; sevenDay = week; updatedAt = Date(); sourceName = "claude.ai"
            checkThresholds()
        }
    }
    private func read() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Only a removed status-line file clears the card; claude.ai readings stay.
            if sourceName == "Claude Code" { fiveHour = nil; sevenDay = nil; updatedAt = nil; sourceName = nil }
            return
        }
        guard let data = try? Data(contentsOf: url), data.count < 8192,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func window(_ key: String) -> Window? {
            guard let value = object[key] as? [String: Any], let used = value["used"] as? Double else { return nil }
            return Window(used: min(100, max(0, used)), resetsAt: (value["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        let next = window("fiveHour")
        if next != fiveHour || window("sevenDay") != sevenDay {
            fiveHour = next; sevenDay = window("sevenDay")
        }
        updatedAt = (object["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        sourceName = "Claude Code"
        checkThresholds()
    }
    /// Warn once per window as usage crosses 80% and 95%.
    private func checkThresholds() {
        if let five = fiveHour {
            if five.used < 50 { warned = 0 }
            if let threshold = [95, 80].first(where: { Int(five.used) >= $0 && warned < $0 }) {
                warned = threshold; onThreshold?(threshold, five.resetsAt)
            }
        }
    }
}

// MARK: - Clipboard history

struct ClipItem: Identifiable, Equatable {
    enum Content: Equatable { case text(String), image(NSImage), files([URL]) }
    let id = UUID()
    var content: Content
    var copiedAt = Date()
    var sourceApp: String?
    var preview: String {
        switch content {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ")
        case .image: "Image"
        case .files(let urls): urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }
}

/// Recent clipboard history, kept in memory only and cleared when Attending quits.
/// Items that password managers mark as concealed or transient are never recorded.
/// macOS has no clipboard-change notification, so the change counter is checked
/// about once a second (a single integer read), and not at all while the Mac sleeps.
@MainActor final class ClipboardHistory: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// Pinned text stays at the top, is never trimmed, and is kept across restarts.
    @Published private(set) var pinned: [ClipItem] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let limit = 30
    private static let skipped: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType"]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "clipboardPins") ?? []
        pinned = saved.map { ClipItem(content: .text($0), sourceApp: "Pinned") }
    }
    func pin(_ item: ClipItem) {
        guard case .text = item.content, !pinned.contains(where: { $0.content == item.content }) else { return }
        pinned.insert(ClipItem(content: item.content, sourceApp: item.sourceApp), at: 0)
        items.removeAll { $0.id == item.id }
        savePins()
    }
    func unpin(_ item: ClipItem) { pinned.removeAll { $0.id == item.id }; savePins() }
    private func savePins() {
        UserDefaults.standard.set(pinned.compactMap { if case .text(let text) = $0.content { return text }; return nil }, forKey: "clipboardPins")
    }
    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        // A generous tolerance lets macOS coalesce this check with other wakeups.
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    func clear() { items.removeAll() }
    func remove(_ item: ClipItem) { items.removeAll { $0.id == item.id } }

    /// Puts an item back on the clipboard without recording it again.
    func copy(_ item: ClipItem) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.content {
        case .text(let text): board.setString(text, forType: .string)
        case .image(let image): board.writeObjects([image])
        case .files(let urls): board.writeObjects(urls as [NSURL])
        }
        lastChange = board.changeCount
        // Pasting a pin leaves it pinned; other items move to the top of the history.
        guard !pinned.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        items.insert(ClipItem(content: item.content, sourceApp: item.sourceApp), at: 0)
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipped) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        let content: ClipItem.Content
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            content = .files(urls)
        } else if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = .text(String(text.prefix(20_000)))
        } else if let image = NSImage(pasteboard: board), image.size.width * image.size.height < 25_000_000 {
            content = .image(image)
        } else { return }
        items.removeAll { $0.content == content }
        guard !pinned.contains(where: { $0.content == content }) else { return }
        items.insert(ClipItem(content: content, sourceApp: source), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }
}

// MARK: - Weather

/// Current conditions from Open-Meteo (free, no account or key). Location is
/// requested only when the user turns weather on, and rounded to about 1 km
/// before it leaves the Mac.
@MainActor final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Conditions: Equatable { var temperature: Int; var high: Int; var low: Int; var code: Int; var isDay: Bool; var place: String? }
    @Published private(set) var current: Conditions?
    @Published private(set) var denied = false
    @Published private(set) var loading = false
    private let manager = CLLocationManager()
    private var refreshTask: Task<Void, Never>?
    private var location: CLLocation?

    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }

    func start() {
        switch manager.authorizationStatus {
        case .denied, .restricted: denied = true
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: loading = true; manager.requestLocation()
        }
    }
    func stop() { refreshTask?.cancel(); current = nil }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            denied = status == .denied || status == .restricted
            if status == .authorizedAlways || status == .authorized { loading = true; self.manager.requestLocation() }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { location = last; fetch() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { loading = false }
    }

    private func fetch() {
        guard let location else { return }
        let lat = (location.coordinate.latitude * 100).rounded() / 100, lon = (location.coordinate.longitude * 100).rounded() / 100
        let fahrenheit = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: "\(lat)"), .init(name: "longitude", value: "\(lon)"),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"), .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius")
        ]
        let url = components.url!
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let now = object["current"] as? [String: Any], let daily = object["daily"] as? [String: Any] {
                    let place = await Self.placeName(for: location)
                    self?.current = Conditions(temperature: Int(((now["temperature_2m"] as? Double) ?? 0).rounded()),
                                               high: Int(((daily["temperature_2m_max"] as? [Double])?.first ?? 0).rounded()),
                                               low: Int(((daily["temperature_2m_min"] as? [Double])?.first ?? 0).rounded()),
                                               code: now["weather_code"] as? Int ?? 0, isDay: (now["is_day"] as? Int ?? 1) == 1, place: place)
                }
                self?.loading = false
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }
    private static func placeName(for location: CLLocation) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return marks?.first?.locality
    }
    static func describe(_ code: Int, day: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82: ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorms")
        default: ("cloud.fill", "—")
        }
    }
}

