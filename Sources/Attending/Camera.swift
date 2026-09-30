import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Camera

/// The quick camera: live preview with mirror, zoom, grid and ring light, and photos
/// with an optional self-timer. The capture session runs only while the tab is visible.
@MainActor final class MirrorController: NSObject, ObservableObject {
    @Published private(set) var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @Published private(set) var denied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    @Published private(set) var running = false
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var cameraID: String?
    /// Seconds left on the self-timer while it counts down.
    @Published private(set) var countdown: Int?
    /// Bumped on each shot so the view can flash.
    @Published private(set) var shots = 0
    @Published private(set) var lastPhoto: URL?
    @Published var zoom: Double = 1
    @AppStorage("mirrorFlip") var mirrored = true { willSet { objectWillChange.send() } }
    @AppStorage("mirrorGrid") var grid = false { willSet { objectWillChange.send() } }
    @AppStorage("mirrorRingLight") var ringLight = false { willSet { objectWillChange.send() } }
    @AppStorage("mirrorTimer") var timerSeconds = 0 { willSet { objectWillChange.send() } }
    @AppStorage("mirrorCamera") private var savedCameraID = ""
    /// Called with each saved photo (Attending puts it on the Shelf).
    var onPhoto: ((URL) -> Void)?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var countdownTask: Task<Void, Never>?
    private var pending: [Int64: PhotoRequest] = [:]
    private let queue = DispatchQueue(label: "attending.mirror")

    struct PhotoRequest { var mirrored: Bool; var zoom: Double }

    var diagnostics: String {
        "auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) running=\(running) sessionRunning=\(session.isRunning) inputs=\(session.inputs.count) camera=\(input?.device.localizedName ?? "nil") devices=\(cameras.map(\.localizedName))"
    }
    var cameraName: String? { input?.device.localizedName }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true; run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.authorized = granted; self.denied = !granted; if granted { self.run() } } }
            }
        default: denied = true
        }
    }
    func stop() {
        countdownTask?.cancel(); countdown = nil
        guard running else { return }
        running = false
        // AVCaptureSession is thread-safe; start/stop run off the main thread per Apple guidance.
        nonisolated(unsafe) let session = session
        queue.async { session.stopRunning() }
    }
    private func run() {
        refreshCameras()
        if !configured {
            let preferred = cameras.first { $0.uniqueID == savedCameraID } ?? AVCaptureDevice.default(for: .video)
            guard let device = preferred, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.addInput(input)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            self.input = input
            cameraID = device.uniqueID
            configured = true
        }
        running = true
        nonisolated(unsafe) let session = session
        queue.async { session.startRunning() }
    }

    // MARK: Cameras

    func refreshCameras() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
    }
    func select(_ device: AVCaptureDevice) {
        guard device.uniqueID != input?.device.uniqueID, let next = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.canAddInput(next) { session.addInput(next); input = next } else if let input { session.addInput(input) }
        session.commitConfiguration()
        cameraID = input?.device.uniqueID
        savedCameraID = cameraID ?? ""
    }
    /// macOS's own camera effects: Portrait blur, Studio Light, Center Stage, Reactions.
    func showEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }

    // MARK: Photos

    /// Takes a photo now, or after the self-timer. Pressing again during the countdown cancels.
    func shutter() {
        if countdown != nil { countdownTask?.cancel(); countdown = nil; return }
        guard running else { return }
        guard timerSeconds > 0 else { capture(); return }
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for left in stride(from: timerSeconds, to: 0, by: -1) {
                countdown = left
                NSSound(named: "Tink")?.play()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            capture()
        }
    }
    func cycleTimer() { timerSeconds = timerSeconds == 0 ? 3 : timerSeconds == 3 ? 10 : 0 }

    private func capture() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        pending[settings.uniqueID] = PhotoRequest(mirrored: mirrored, zoom: zoom)
        shots += 1
        Self.shutterSound?.play()
        output.capturePhoto(with: settings, delegate: self)
    }
    private static let shutterSound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif", byReference: true)

    fileprivate func finish(_ id: Int64, data: Data?) {
        guard let request = pending.removeValue(forKey: id) else { return }
        guard let data, let url = Self.save(data, mirrored: request.mirrored, zoom: request.zoom) else {
            NSSound(named: "Basso")?.play(); return
        }
        lastPhoto = url
        onPhoto?(url)
    }

    /// Crops to the zoom, flips if the preview was mirrored (so the photo matches what
    /// you saw), and saves a JPEG to ~/Pictures/Attending.
    private static func save(_ data: Data, mirrored: Bool, zoom: Double) -> URL? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = Double(image.width), h = Double(image.height)
        let crop = CGRect(x: (w - w / zoom) / 2, y: (h - h / zoom) / 2, width: w / zoom, height: h / zoom).integral
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if mirrored { context.translateBy(x: CGFloat(cropped.width), y: 0); context.scaleBy(x: -1, y: 1) }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let final = context.makeImage() else { return nil }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Attending", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twelveHour, hourCycle: .oneBased)).\(minute: .twoDigits).\(second: .twoDigits) \(dayPeriod: .standard(.abbreviated))", timeZone: .current, calendar: .current))
        var url = folder.appendingPathComponent("Photo \(stamp).jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("Photo \(stamp) \(n).jpg"); n += 1 }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, final, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    // MARK: Last photo

    func copyLastPhoto() {
        guard let url = lastPhoto, let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image, url as NSURL])
    }
    func revealLastPhoto() { if let lastPhoto { NSWorkspace.shared.activateFileViewerSelecting([lastPhoto]) } }
    func openLastPhoto() { if let lastPhoto { NSWorkspace.shared.open(lastPhoto) } }
    func trashLastPhoto() {
        guard let url = lastPhoto else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        lastPhoto = nil
    }
}

extension MirrorController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let id = photo.resolvedSettings.uniqueID
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(id, data: data) } }
    }
}

// MARK: - Preview

/// Layer-hosting view: the root layer is assigned *before* `wantsLayer`, so AppKit leaves
/// it alone instead of replacing it with its own backing layer. The preview is a sublayer
/// so zoom can scale it inside the rounded, clipped root.
final class CameraPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    var zoom: CGFloat = 1 { didSet { needsLayout = true } }
    var mirrored = true { didSet { applyMirror() } }
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        let root = CALayer()
        root.cornerRadius = 18
        root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        root.addSublayer(preview)
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        CATransaction.commit()
        applyMirror()
    }
    /// The connection exists only once the session has an input, so this retries on layout.
    func applyMirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var running: Bool
    var mirrored: Bool
    var zoom: Double
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.mirrored = mirrored
        view.zoom = zoom
        if running { view.applyMirror() }
    }
}

// MARK: - Mirror tab

struct MirrorView: View {
    @ObservedObject var mirror: MirrorController
    @State private var flash = 0.0
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(mirror.ringLight ? Color.white : Theme.card)
                .shadow(color: .white.opacity(mirror.ringLight ? 0.6 : 0), radius: 24)
            if mirror.denied {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary)
                    Text("Camera access is off").font(.system(size: 14, weight: .semibold))
                    PillButton(title: "Open Privacy Settings", symbol: nil) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            } else {
                ZStack {
                    CameraPreview(session: mirror.session, running: mirror.running, mirrored: mirror.mirrored, zoom: mirror.zoom)
                        .opacity(mirror.running ? 1 : 0)
                    if mirror.grid { GridLines().allowsHitTesting(false) }
                    if let count = mirror.countdown {
                        Text("\(count)")
                            .font(.system(size: 96, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 12)
                            .id(count).transition(.scale(scale: 1.4).combined(with: .opacity))
                    }
                    if !mirror.running { ProgressView().controlSize(.small) }
                    VStack { Spacer(); controls }.padding(12)
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white).opacity(flash).allowsHitTesting(false)
                }
                .padding(mirror.ringLight ? 22 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: mirror.countdown)
            }
        }
        .animation(.easeOut(duration: 0.25), value: mirror.ringLight)
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
        .onChange(of: mirror.shots) { _, _ in
            flash = 0.9
            withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                if mirror.cameras.count > 1 {
                    Menu {
                        ForEach(mirror.cameras, id: \.uniqueID) { device in
                            Button { mirror.select(device) } label: {
                                if device.uniqueID == mirror.cameraID { Label(device.localizedName, systemImage: "checkmark") } else { Text(device.localizedName) }
                            }
                        }
                    } label: { Image(systemName: "camera.on.rectangle").font(.system(size: 12, weight: .semibold)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 30, height: 30)
                        .help(mirror.cameraName.map { "Camera: \($0)" } ?? "Camera")
                }
                GlassToggle(symbol: "arrow.left.and.right", on: mirror.mirrored, help: "Mirror") { mirror.mirrored.toggle() }
                GlassToggle(symbol: "grid", on: mirror.grid, help: "Grid") { mirror.grid.toggle() }
                GlassToggle(symbol: mirror.ringLight ? "lightbulb.max.fill" : "lightbulb", on: mirror.ringLight, help: "Ring light: the screen lights your face") { mirror.ringLight.toggle() }
                GlassToggle(symbol: "person.crop.rectangle", on: false, help: "Video effects: Portrait, Studio Light, Center Stage") { mirror.showEffects() }
            }
            .padding(4).background(Capsule().fill(.black.opacity(0.45)))
            Spacer()
            Button { mirror.shutter() } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 3).frame(width: 52, height: 52)
                    Circle().fill(mirror.countdown == nil ? Color.white : Theme.failed).frame(width: 40, height: 40)
                }
                .shadow(color: .black.opacity(0.35), radius: 6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(mirror.countdown == nil ? "Take photo (Space)" : "Cancel timer")
            Spacer()
            HStack(spacing: 6) {
                Button { mirror.cycleTimer() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer").font(.system(size: 11, weight: .semibold))
                        if mirror.timerSeconds > 0 { Text("\(mirror.timerSeconds)s").font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                    }
                    .foregroundStyle(mirror.timerSeconds > 0 ? Theme.attention : .white)
                    .padding(.horizontal, 8).frame(height: 30)
                }
                .buttonStyle(.plain).help("Self-timer: off, 3 s or 10 s")
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Slider(value: $mirror.zoom, in: 1...3).controlSize(.mini).frame(width: 70).tint(.white).help("Zoom")
                LastPhoto(mirror: mirror)
            }
            .padding(4).padding(.trailing, 2).background(Capsule().fill(.black.opacity(0.45)))
        }
    }
}

/// A round glass button that shows whether its option is on.
private struct GlassToggle: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? Color.white : hovering ? Color.white.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(help)
    }
}

/// Thumbnail of the last photo: click to open, drag it anywhere, right-click for more.
private struct LastPhoto: View {
    @ObservedObject var mirror: MirrorController
    var body: some View {
        if let url = mirror.lastPhoto, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .onTapGesture { mirror.openLastPhoto() }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .contextMenu {
                    Button("Copy") { mirror.copyLastPhoto() }
                    Button("Show in Finder") { mirror.revealLastPhoto() }
                    ShareLink(item: url) { Text("Share…") }
                    Divider()
                    Button("Move to Trash", role: .destructive) { mirror.trashLastPhoto() }
                }
                .help("Last photo: click to open, drag to use it anywhere")
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Rule-of-thirds guides.
private struct GridLines: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
        }
    }
}
