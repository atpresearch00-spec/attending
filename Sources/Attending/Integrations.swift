import AppKit
import ApplicationServices
import CoreAudio
import CoreMediaIO
import UniformTypeIdentifiers

// MARK: - External drives

struct ExternalVolume: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var name: String
    var capacity: Int64?
    var available: Int64?
}

/// External and removable volumes, updated from mount notifications, with eject.
@MainActor final class VolumeMonitor: ObservableObject {
    @Published private(set) var volumes: [ExternalVolume] = []
    @Published private(set) var ejecting: Set<String> = []
    var onMount: ((ExternalVolume) -> Void)?
    var onEjectResult: ((_ name: String, _ error: String?) -> Void)?
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        scan()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scan()
                if let url, let volume = self.volumes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { self.onMount?(volume) }
            }
        })
        for name in [NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } })
        }
    }
    func scan() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        defer { onChange?() }
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                  values.volumeIsInternal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            return ExternalVolume(url: url, name: values.volumeName ?? url.lastPathComponent,
                                  capacity: values.volumeTotalCapacity.map(Int64.init), available: values.volumeAvailableCapacity.map(Int64.init))
        }
    }
    func eject(_ volume: ExternalVolume) {
        guard !ejecting.contains(volume.id) else { return }
        ejecting.insert(volume.id)
        let url = volume.url
        Task.detached(priority: .userInitiated) {
            var message: String?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch { message = "Close any files or apps using it, then try again." }
            await MainActor.run { [weak self] in
                self?.ejecting.remove(volume.id)
                self?.scan()
                self?.onEjectResult?(volume.name, message)
            }
        }
    }
    func reveal(_ volume: ExternalVolume) { NSWorkspace.shared.open(volume.url) }
}

// MARK: - Outlook

/// Outlook's unread count, read from its Dock badge through Accessibility, so no
/// Microsoft sign-in is needed. Calendar events come through macOS Calendar.
@MainActor final class OutlookService: ObservableObject {
    static let bundleID = "com.microsoft.Outlook"
    @Published private(set) var unread: Int?
    @Published private(set) var installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OutlookService.bundleID) != nil
    private var timer: Timer?

    func start() {
        guard installed, timer == nil else { return }
        read()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    func compose() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID), let mail = URL(string: "mailto:") else { return }
        NSWorkspace.shared.open([mail], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    func read() {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { unread = nil; return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = AX.children(app).first(where: { AX.role($0) == "AXList" }) else { return }
        for item in AX.children(list) where AX.title(item)?.localizedCaseInsensitiveContains("Outlook") == true {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &value)
            unread = (value as? String).flatMap { Int($0.filter(\.isNumber)) } ?? 0
            return
        }
        unread = nil
    }
}

/// Accessibility attribute helpers shared by the Outlook and Zoom readers.
enum AX {
    static func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func role(_ element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) as? String }
    static func title(_ element: AXUIElement) -> String? { attribute(element, kAXTitleAttribute) as? String }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

// MARK: - Quick launch

struct LaunchItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String?
    var link: String?
    var name: String
    var url: URL? { path.map { URL(fileURLWithPath: $0) } ?? link.flatMap(URL.init(string:)) }
}

/// Pinned apps, folders and links. Drag anything onto the strip to pin it.
@MainActor final class LauncherStore: ObservableObject {
    @Published private(set) var items: [LaunchItem] = []
    private let key = "launcherItems"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([LaunchItem].self, from: data) {
            items = saved
            // 0.4.0 fixed Anki's bundle identifier; pin it once for existing launchers.
            if !UserDefaults.standard.bool(forKey: "launcherAnkiSeeded"), let anki = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.ankiweb.anki"),
               !items.contains(where: { $0.path == anki.path }) {
                items.insert(LaunchItem(path: anki.path, name: "Anki"), at: 0)
                save()
            }
            UserDefaults.standard.set(true, forKey: "launcherAnkiSeeded")
        } else {
            UserDefaults.standard.set(true, forKey: "launcherAnkiSeeded")
            // First run: the apps this Mac actually uses for school and projects.
            let seeds = ["net.ankiweb.anki", "com.microsoft.Outlook", "md.obsidian", "org.zotero.zotero", "com.blackmagic-design.DaVinciResolve", "com.spotify.client"]
            items = seeds.compactMap { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { LaunchItem(path: $0.path, name: FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")) }
            }
            items.append(LaunchItem(link: "https://drive.google.com", name: "Google Drive"))
            save()
        }
    }
    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            items.append(LaunchItem(path: url.path, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
        save()
    }
    func remove(_ item: LaunchItem) { items.removeAll { $0.id == item.id }; save() }
    func move(_ item: LaunchItem, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = min(max(0, index + offset), items.count - 1)
        items.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        save()
    }
    func launch(_ item: LaunchItem) {
        guard let url = item.url else { return }
        if url.pathExtension == "app" { NSWorkspace.shared.openApplication(at: url, configuration: .init()) } else { NSWorkspace.shared.open(url) }
    }
    func icon(for item: LaunchItem) -> NSImage {
        if let path = item.path { return NSWorkspace.shared.icon(forFile: path) }
        if item.link?.contains("drive.google.com") == true, let drive = GoogleDrive.folder { return NSWorkspace.shared.icon(forFile: drive.path) }
        return NSWorkspace.shared.icon(for: .internetLocation)
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key) }
}

// MARK: - Google Drive

/// Google Drive for desktop, when installed, exposes My Drive as a local folder.
enum GoogleDrive {
    static var folder: URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cloud.path),
              let account = names.first(where: { $0.hasPrefix("GoogleDrive-") }) else { return nil }
        let root = cloud.appendingPathComponent(account)
        let myDrive = root.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : root
    }
    /// Copies files into My Drive/Attending so Drive uploads them.
    static func save(_ urls: [URL]) -> String {
        guard let folder else { return "Install Google Drive for desktop to save files to Drive." }
        let target = folder.appendingPathComponent("Attending", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for url in urls {
                var destination = target.appendingPathComponent(url.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = target.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"); n += 1
                }
                try FileManager.default.copyItem(at: url, to: destination)
            }
            return "Copied to Drive › Attending. Drive uploads it in the background."
        } catch { return "Couldn't copy to Drive." }
    }
}

// MARK: - Microphone and Zoom

/// Tracks whether any app is using the microphone (CoreAudio listener, no polling)
/// and, during a Zoom call, Zoom's mute state via its Meeting menu (Accessibility).
@MainActor final class MeetingMonitor: ObservableObject {
    enum ZoomState: Equatable { case muted, live }
    @Published private(set) var micInUse = false
    /// Some app (other than Attending's own mirror) has a camera on.
    @Published private(set) var cameraInUse = false
    /// True while Attending's mirror has the camera, so it isn't reported as another app.
    var ownCameraActive = false { didSet { readCameras() } }
    @Published private(set) var zoom: ZoomState?
    private var cameraDevices: [CMIOObjectID] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pollTask: Task<Void, Never>?
    private static let zoomID = "us.zoom.xos"

    func start() {
        guard listeners.isEmpty else { return }
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { [weak self] in self?.attach() } }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, block) == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), defaultInput, block))
        }
        attach()
        watchCameras()
    }

    // MARK: Camera

    /// Listens for any camera starting or stopping (CoreMediaIO, no polling).
    private func watchCameras() {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, &devices) == noErr else { return }
        cameraDevices = devices
        for device in devices {
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            CMIOObjectAddPropertyListenerBlock(device, &running, .main) { _, _ in MainActor.assumeIsolated { [weak self] in self?.readCameras() } }
        }
        readCameras()
    }
    private func readCameras() {
        let running = cameraDevices.contains { device in
            var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(device, &address, 0, nil, size, &size, &value) == noErr && value != 0
        }
        let inUse = running && !ownCameraActive
        if cameraInUse != inUse { cameraInUse = inUse }
    }
    /// Toggles Zoom's microphone through its own menu item.
    func toggleZoomMute() {
        guard let item = zoomMenuItem() else { return }
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        Task { try? await Task.sleep(for: .milliseconds(250)); readZoom() }
    }
    private func attach() {
        for (object, address, block) in listeners.dropFirst() {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = Array(listeners.prefix(1))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return }
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { [weak self] in self?.readMic() } }
        if AudioObjectAddPropertyListenerBlock(device, &running, .main, block) == noErr { listeners.append((device, running, block)) }
        readMic()
    }
    private func readMic() {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        micInUse = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
        // Zoom's state is only polled while the mic is live (i.e. during a call).
        pollTask?.cancel()
        guard micInUse else { zoom = nil; return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readZoom()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
    private func readZoom() {
        guard let item = zoomMenuItem() else { zoom = nil; return }
        zoom = item.title.lowercased().hasPrefix("unmute") ? .muted : .live
    }
    private func zoomMenuItem() -> (element: AXUIElement, title: String)? {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.zoomID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        for menu in AX.children(bar as! AXUIElement) where AX.title(menu) == "Meeting" {
            for list in AX.children(menu) {
                for item in AX.children(list) {
                    if let text = AX.title(item), text.lowercased().hasPrefix("mute audio") || text.lowercased().hasPrefix("unmute audio") { return (item, text) }
                }
            }
        }
        return nil
    }
}

// MARK: - Shortcuts automation

/// Runs the user's own Shortcuts when agents start and finish (for example a Focus
/// mode). macOS doesn't let apps switch Focus directly; Shortcuts can.
enum ShortcutRunner {
    static func run(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", trimmed]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - Screenshot drops

/// Watches the screenshot folder (Desktop unless changed in Screenshot options) and
/// reports new screenshots and screen recordings. Directory events only; no polling.
@MainActor final class ScreenshotWatcher {
    var onCapture: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []

    /// macOS's floating thumbnail after a screenshot; while it shows, the file isn't written.
    static var thumbnailEnabled: Bool {
        get { UserDefaults(suiteName: "com.apple.screencapture")?.object(forKey: "show-thumbnail") as? Bool ?? true }
        set {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", newValue ? "true" : "false"]
            try? process.run(); process.waitUntilExit()
        }
    }
    static var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
    func start() {
        guard source == nil else { return }
        let folder = Self.folder
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in
            // screencapture writes a hidden temp file, then renames it; let that settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.scan(folder) } }
        }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        source = watcher
    }
    func stop() { source?.cancel(); source = nil }
    private func scan(_ folder: URL) {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let fresh = names.subtracting(seen)
        seen = names
        for name in fresh.sorted() where !name.hasPrefix(".") && ["Screenshot", "Screen Shot", "Screen Recording"].contains(where: name.hasPrefix) {
            let url = folder.appendingPathComponent(name)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) < 30 { onCapture?(url) }
        }
    }
}
