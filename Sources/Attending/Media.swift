import AppKit
import CoreAudio
import AudioToolbox
import OSLog

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var elapsedAt: Date
    var rate: Double
    var playing: Bool
    var bundleID: String?

    /// Extrapolates the playhead from the last reported position; no polling needed.
    func position(at date: Date) -> Double {
        guard playing else { return elapsed }
        let value = elapsed + date.timeIntervalSince(elapsedAt) * (rate == 0 ? 1 : rate)
        return duration > 0 ? min(duration, max(0, value)) : max(0, value)
    }
    var isSpotify: Bool { bundleID == "com.spotify.client" }
    var isMusic: Bool { bundleID == "com.apple.Music" }
}

/// Reads system-wide Now Playing (YouTube in any browser, Spotify, Music, podcasts…)
/// through a helper hosted by /usr/bin/perl. Since macOS 15.4, MediaRemote serves
/// metadata only to Apple-signed processes; the helper is Attending's own code
/// loaded into that process and talks to the app over stdin/stdout.
@MainActor final class MediaController: ObservableObject {
    @Published private(set) var track: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var available = true
    @Published private(set) var spotifyInstalled = false
    @Published var spotifyShuffle: Bool?
    @Published private(set) var musicShuffle: Bool?
    @Published private(set) var musicFavorite: Bool?
    @Published private(set) var playlists: [String] = []
    let spectrum = AudioSpectrum()
    let spotify = SpotifyService()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0
    private var stopping = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Attending", category: "media")

    var sourceName: String? {
        guard let id = track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    var sourceIcon: NSImage? {
        guard let id = track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func start() {
        spotifyInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
        stopping = false
        launch()
    }
    /// The visualizer taps audio only while something is actually playing.
    func updateSpectrum(awake: Bool) {
        let wanted = awake && (UserDefaults.standard.object(forKey: "liveVisualizer") as? Bool ?? true) && track?.playing == true
        if wanted && !spectrum.running { spectrum.start() } else if !wanted && spectrum.running { spectrum.stop() }
    }
    func stop() {
        spectrum.stop()
        stopping = true
        try? input?.close()
        process?.terminate()
        process = nil; input = nil
    }

    func toggle() { send("toggle") }
    func next() { send("next") }
    func previous() { send("previous") }
    func seek(to seconds: Double) { send("seek \(seconds)") }
    func skip(_ delta: Double) {
        guard let track else { return }
        seek(to: max(0, track.position(at: Date()) + delta))
    }
    func openSource() {
        guard let id = track?.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
    }
    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    func toggleSpotifyShuffle() {
        spotifyShuffle?.toggle()
        Task { spotifyShuffle = await Self.script("tell application \"Spotify\"\nset shuffling to not shuffling\nreturn shuffling\nend tell") == "true" }
    }
    private func refreshSpotifyState() {
        if track?.isMusic == true { refreshMusicState() } else { musicShuffle = nil; musicFavorite = nil }
        guard track?.isSpotify == true else { spotifyShuffle = nil; return }
        Task { spotifyShuffle = (await Self.script("tell application \"Spotify\" to get shuffling")).map { $0 == "true" } }
    }

    // MARK: Apple Music

    func openMusic() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    func toggleMusicShuffle() {
        musicShuffle?.toggle()
        Task { await Self.script("tell application \"Music\" to set shuffle enabled to not shuffle enabled"); refreshMusicState() }
    }
    /// Favorites (formerly "Love") the current Apple Music track.
    func toggleMusicFavorite() {
        musicFavorite?.toggle()
        Task { await Self.script("tell application \"Music\" to set favorited of current track to not (favorited of current track)"); refreshMusicState() }
    }
    func play(playlist name: String) {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        Task { await Self.script("tell application \"Music\" to play playlist \"\(escaped)\"") }
    }
    /// Shuffle, favorite and playlists, loaded when Apple Music becomes the source
    /// (Music is already running then, so asking never launches it).
    private func refreshMusicState() {
        Task {
            let state = await Self.script("tell application \"Music\"\nreturn (shuffle enabled as text) & \"|\" & ((favorited of current track) as text)\nend tell")
            let parts = state?.split(separator: "|").map(String.init) ?? []
            musicShuffle = parts.first.map { $0 == "true" }
            musicFavorite = parts.count > 1 ? parts[1] == "true" : nil
            if playlists.isEmpty, let names = await Self.script("tell application \"Music\"\nset AppleScript's text item delimiters to linefeed\nreturn (name of every user playlist whose special kind is none) as text\nend tell") {
                playlists = names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }
        }
    }
    /// Runs AppleScript in /usr/bin/osascript so neither a slow app nor the first-run
    /// Automation prompt can block the notch's main thread. Returns trimmed stdout.
    @discardableResult private static func script(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: finished.terminationStatus == 0 ? text : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func launch() {
        guard let dylib = Bundle.main.url(forResource: "libAttendingMedia", withExtension: "dylib") ?? Self.developmentLibrary else {
            available = false; return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", Self.loader, dylib.path]
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        // The main queue is FIFO, so multi-chunk lines (artwork) arrive in order.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk) } }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated() } }
        }
        do {
            try task.run()
            process = task; input = stdin.fileHandleForWriting; available = true
        } catch {
            log.error("Media helper failed to start")
            available = false
        }
    }
    private func terminated() {
        process = nil; input = nil
        guard !stopping else { return }
        restarts += 1
        // A crashed helper is restarted a few times with backoff, then media is hidden.
        guard restarts <= 5 else { available = false; track = nil; return }
        Task { try? await Task.sleep(for: .seconds(Double(restarts))); if !stopping { launch() } }
    }
    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(object) }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }
    }
    /// Screenshots and videos can leave out whatever happens to be playing.
    var hiddenForCapture = false { didSet { if hiddenForCapture { track = nil; artwork = nil } } }

    private func apply(_ object: [String: Any]) {
        if hiddenForCapture { return }
        if object["error"] != nil { available = false; return }
        restarts = 0
        if let art = object["artwork"] as? String {
            artwork = art.isEmpty ? nil : Data(base64Encoded: art).flatMap(NSImage.init(data:))
        }
        let title = object["title"] as? String ?? ""
        if (object["empty"] as? Bool) == true || title.isEmpty { track = nil; artwork = nil; return }
        let stamp = (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let previousBundle = track?.bundleID, previousTitle = track?.title
        track = NowPlaying(title: title, artist: object["artist"] as? String ?? "", album: object["album"] as? String ?? "",
                           duration: object["duration"] as? Double ?? 0, elapsed: object["elapsed"] as? Double ?? 0,
                           elapsedAt: stamp, rate: object["rate"] as? Double ?? 0, playing: object["playing"] as? Bool ?? false,
                           bundleID: object["bundle"] as? String)
        if track?.bundleID != previousBundle || track?.isSpotify == true || track?.isMusic == true { refreshSpotifyState() }
        if track?.isSpotify == true && track?.title != previousTitle { spotify.trackChanged() }
    }

    private static let loader = #"use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); my $s = DynaLoader::dl_find_symbol($h, "attending_media_run") or die "symbol"; DynaLoader::dl_install_xsub("main::run", $s); main::run();"#
    /// Unbundled `swift run` builds keep the helper next to the executable.
    private static var developmentLibrary: URL? {
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libAttendingMedia.dylib")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

/// Default output device volume via CoreAudio, with change listeners instead of polling.
@MainActor final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = 0.5
    @Published private(set) var muted = false
    @Published private(set) var adjustable = true
    /// Called with the device name when the output switches to Bluetooth headphones.
    var onBluetoothOutput: ((String) -> Void)?
    private var attachedOnce = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        addListener(AudioObjectID(kAudioObjectSystemObject), Self.defaultAddress) { [weak self] in self?.attachDefaultDevice() }
        attachDefaultDevice()
    }
    func set(_ value: Float) {
        var volume = min(1, max(0, value))
        var address = Self.volumeAddress
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr else { return }
        level = volume
        if muted && volume > 0 { toggleMute() }
    }
    func toggleMute() {
        var value: UInt32 = muted ? 0 : 1
        var address = Self.muteAddress
        if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr { muted = value == 1 }
    }
    private func attachDefaultDevice() {
        for (object, address, block) in listeners where object != AudioObjectID(kAudioObjectSystemObject) {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll { $0.0 != AudioObjectID(kAudioObjectSystemObject) }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.defaultAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { adjustable = false; return }
        device = id
        var settable: DarwinBoolean = false
        var volumeAddress = Self.volumeAddress
        adjustable = AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
        MediaKeyTap.volumeAdjustable = adjustable
        // Output switching to Bluetooth (AirPods, Beats, any headphones) after launch.
        if attachedOnce, Self.isBluetooth(device), let name = Self.name(of: device) { onBluetoothOutput?(name) }
        attachedOnce = true
        addListener(device, Self.volumeAddress) { [weak self] in self?.read() }
        addListener(device, Self.muteAddress) { [weak self] in self?.read() }
        read()
    }
    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    private static func name(of device: AudioObjectID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
    private func read() {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr { level = volume }
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.muteAddress
        muted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute == 1
    }
    private func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @MainActor () -> Void) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append((object, address, block)) }
    }
}
