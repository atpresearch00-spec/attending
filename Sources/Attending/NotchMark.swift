import SwiftUI
import AttendingCore

enum PetKind: String, CaseIterable, Identifiable {
    case stethoscope, pulse, dot
    var id: String { rawValue }
    var title: String { switch self { case .stethoscope: "Stethoscope"; case .pulse: "Pulse"; case .dot: "Dot" } }
    /// Earlier builds offered character pets; those choices map to the stethoscope.
    static func stored(_ raw: String) -> PetKind { PetKind(rawValue: raw) ?? .stethoscope }
}

/// Attending's companion mark: refined line art rather than a character. Status is
/// carried by one small accent — the stethoscope's chestpiece, the pulse line, or a
/// dot — which beats while agents work, turns orange and sways when one needs you,
/// and shows a check when a turn completes. Short bursts only; nothing animates for
/// Reduce Motion, sleep or screen lock.
struct NotchMark: View {
    let mood: SessionStatus
    let animate: Bool
    var height: CGFloat = 20
    @AppStorage("pet") private var petRaw = PetKind.stethoscope.rawValue
    @AppStorage("ecgWhenActive") private var ecgWhenActive = true
    @State private var beat = false
    @State private var sway: Double = 0

    private var pet: PetKind { PetKind.stored(petRaw) }
    /// Resting accent is a quiet silver; status colors only when something is happening.
    private var accent: Color { mood == .idle || mood == .stale ? Color.white.opacity(0.28) : mood.color }

    /// While agents work (or need you), the mark becomes a live, scrolling ECG trace.
    private var showsECG: Bool { pet != .dot && ecgWhenActive && (mood == .working || mood == .attention) }

    var body: some View {
        let scale = height / 22
        ZStack {
            if showsECG {
                Color.clear
            } else {
                Group {
                    switch pet {
                    case .stethoscope: StethoscopeMark(accent: accent, beat: beat, done: mood == .completed)
                    case .pulse: PulseMark(accent: accent, resting: mood == .idle || mood == .stale, beat: beat)
                    case .dot: DotMark(accent: accent, beat: beat, done: mood == .completed)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showsECG)
        .frame(width: showsECG ? 30 : 24, height: 22)
        .rotationEffect(.degrees(sway), anchor: .top)
        .scaleEffect(scale)
        .frame(width: (showsECG ? 30 : 24) * scale, height: 22 * scale)
        .overlay {
            if showsECG {
                LiveECG(color: accent, bpm: mood == .attention ? 110 : 72, animate: animate)
                    .frame(width: 30 * scale, height: 22 * scale)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showsECG)
        .accessibilityElement()
        .accessibilityLabel("Attending, \(mood.title)")
        .task(id: "\(animate)-\(mood.rawValue)-\(petRaw)") { await run() }
    }

    private func run() async {
        // The live ECG animates itself; the discrete beat/sway only drive the static marks.
        guard animate, !showsECG else { beat = false; sway = 0; return }
        while !Task.isCancelled {
            switch mood {
            case .working:
                // A resting heart rate: lub-dub, then a pause.
                for _ in 0..<2 {
                    withAnimation(.easeOut(duration: 0.1)) { beat = true }
                    guard await pause(0.14) else { return }
                    withAnimation(.easeIn(duration: 0.22)) { beat = false }
                    guard await pause(0.16) else { return }
                }
                guard await pause(0.7) else { return }
            case .attention:
                for angle in [5.0, -4, 2.5, 0] {
                    withAnimation(.easeInOut(duration: 0.16)) { sway = angle }
                    guard await pause(0.16) else { return }
                }
                guard await pause(3.5) else { return }
            default:
                return
            }
        }
    }
    private func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)); return true } catch { return false }
    }
}

// MARK: - Live ECG

/// A heart-monitor trace that scrolls right to left, brightest at the leading edge.
/// The waveform is drawn once into a Core Animation shape layer and slid by the
/// window server (a repeating position animation), so it is perfectly smooth and
/// costs almost no CPU — no per-frame redraw on the main thread.
struct LiveECG: NSViewRepresentable {
    let color: Color
    let bpm: Double
    let animate: Bool
    func makeNSView(context: Context) -> ECGLayerView { ECGLayerView() }
    func updateNSView(_ view: ECGLayerView, context: Context) {
        view.configure(color: NSColor(color), bpm: bpm, animate: animate)
    }
    /// One cardiac cycle as a polyline (x in 0...1): P wave, QRS complex, T wave.
    static let cycle: [CGPoint] = {
        var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0)]
        for i in 0...8 { let u = CGFloat(i) / 8; points.append(CGPoint(x: 0.1 + 0.1 * u, y: 0.13 * sin(.pi * u))) }  // P
        points += [CGPoint(x: 0.28, y: 0), CGPoint(x: 0.31, y: -0.12), CGPoint(x: 0.345, y: 1), CGPoint(x: 0.38, y: -0.3), CGPoint(x: 0.41, y: 0)] // QRS
        for i in 0...10 { let u = CGFloat(i) / 10; points.append(CGPoint(x: 0.52 + 0.16 * u, y: 0.24 * sin(.pi * u))) } // T
        points.append(CGPoint(x: 1, y: 0))
        return points
    }()
}

final class ECGLayerView: NSView {
    private let wave = CAShapeLayer()
    private let fade = CAGradientLayer()
    private var current: (NSColor, Double, Bool, CGSize)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        wave.fillColor = nil
        wave.lineWidth = 1.4
        wave.lineCap = .round
        wave.lineJoin = .round
        wave.shadowOpacity = 0.8
        wave.shadowRadius = 1.6
        wave.shadowOffset = .zero
        layer?.addSublayer(wave)
        // Fade the trailing (left) side like a monitor sweep.
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.45, 1]
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        if let current { configure(color: current.0, bpm: current.1, animate: current.2, force: true) }
    }

    func configure(color: NSColor, bpm: Double, animate: Bool, force: Bool = false) {
        let size = bounds.size
        if !force, let current, current.0 == color, current.1 == bpm, current.2 == animate, current.3 == size { return }
        current = (color, bpm, animate, size)
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        let beatWidth = size.width / 1.6
        let mid = size.height * 0.56, amplitude = size.height * 0.42
        let path = CGMutablePath()
        for beat in 0..<4 {
            for (index, point) in LiveECG.cycle.enumerated() {
                let p = CGPoint(x: CGFloat(beat) * beatWidth + point.x * beatWidth, y: mid - point.y * amplitude)
                if beat == 0 && index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        wave.path = path
        wave.frame = CGRect(x: 0, y: 0, width: beatWidth * 4, height: size.height)
        wave.strokeColor = color.cgColor
        wave.shadowColor = color.cgColor
        CATransaction.commit()
        wave.removeAnimation(forKey: "scroll")
        guard animate else { return }
        // Slide exactly one beat to the left, then repeat seamlessly.
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = wave.position.x
        slide.toValue = wave.position.x - beatWidth
        slide.duration = 60 / bpm
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        wave.add(slide, forKey: "scroll")
    }
}

// MARK: - Marks

/// Stethoscope line art in a 24×22 grid: binaurals from the top, a Y-yoke, tubing
/// that curves to a chestpiece at lower right.
struct StethoscopeMark: View {
    let accent: Color
    var beat = false
    var done = false
    var lineWidth: CGFloat = 1.35
    var body: some View {
        ZStack {
            StethoscopePath()
                .stroke(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.62)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            Circle().fill(Color.white.opacity(0.95)).frame(width: lineWidth * 1.5, height: lineWidth * 1.5).position(x: 5.2, y: 1.6)
            Circle().fill(Color.white.opacity(0.95)).frame(width: lineWidth * 1.5, height: lineWidth * 1.5).position(x: 12.8, y: 1.6)
            // Chestpiece: silver rim, status-colored diaphragm.
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: lineWidth)
                Circle().fill(accent).padding(lineWidth + 0.7)
                    .shadow(color: accent.opacity(beat ? 0.95 : 0.5), radius: beat ? 2.2 : 1)
                if done {
                    Checkmark().stroke(Color.black.opacity(0.75), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                        .padding(lineWidth + 1.8)
                }
            }
            .frame(width: 8.2, height: 8.2)
            .scaleEffect(beat ? 1.12 : 1)
            .position(x: 18.4, y: 16.4)
        }
    }
}

struct StethoscopePath: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 22
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        // Binaurals.
        p.move(to: pt(5.2, 1.6)); p.addQuadCurve(to: pt(9, 10), control: pt(4.4, 8.2))
        p.move(to: pt(12.8, 1.6)); p.addQuadCurve(to: pt(9, 10), control: pt(13.6, 8.2))
        // Tubing to the chestpiece.
        p.move(to: pt(9, 10))
        p.addCurve(to: pt(14.3, 16.4), control1: pt(8.7, 15.6), control2: pt(10.6, 16.4))
        return p
    }
}

/// Minimal ECG line; the complex spikes with each beat.
struct PulseMark: View {
    let accent: Color
    var resting = true
    var beat = false
    var body: some View {
        let line = resting ? Color.white.opacity(0.85) : accent
        ECGPath(spike: beat ? 1.2 : 1)
            .stroke(line, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .shadow(color: line.opacity(beat ? 0.9 : 0.35), radius: beat ? 2 : 0.8)
            .padding(.vertical, 3)
    }
}
struct ECGPath: Shape {
    var spike: CGFloat
    var animatableData: CGFloat { get { spike } set { spike = newValue } }
    func path(in rect: CGRect) -> Path {
        let mid = rect.midY, h = rect.height / 2 * spike
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0.28, 0), (0.36, -0.18), (0.42, 0), (0.48, 0.3), (0.55, -1), (0.62, 0.55), (0.68, 0), (0.78, -0.22), (0.86, 0), (1, 0)]
        var p = Path()
        for (i, point) in points.enumerated() {
            let cg = CGPoint(x: rect.minX + point.0 * rect.width, y: mid + point.1 * h)
            if i == 0 { p.move(to: cg) } else { p.addLine(to: cg) }
        }
        return p
    }
}

struct DotMark: View {
    let accent: Color
    var beat = false
    var done = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            Circle().fill(accent).padding(3.2).shadow(color: accent.opacity(beat ? 0.9 : 0.4), radius: beat ? 2.4 : 1)
            if done { Checkmark().stroke(Color.black.opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)).padding(5.4) }
        }
        .frame(width: 13, height: 13)
        .scaleEffect(beat ? 1.12 : 1)
    }
}

struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return p
    }
}

// MARK: - App icon

/// Attending's icon: a silver stethoscope hanging from a notch island on a deep
/// navy squircle, the chestpiece lit in the app's teal. Rendered by `--render-icons`.
struct AppIconArt: View {
    var body: some View {
        let teal = Color(red: 0.3, green: 0.86, blue: 0.82)
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.2), Color(red: 0.02, green: 0.03, blue: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center), lineWidth: 3))
                .frame(width: 824, height: 824)
            // Notch island.
            Capsule().fill(Color.black).frame(width: 300, height: 76).offset(y: -306)
            // Stethoscope: ear tips tuck under the island, chestpiece lower right.
            IconStethoscope().stroke(LinearGradient(colors: [Color.white, Color(white: 0.72)], startPoint: .top, endPoint: .bottom),
                                     style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                .frame(width: 824, height: 824)
            Circle().fill(RadialGradient(colors: [teal.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 200))
                .frame(width: 400, height: 400).offset(x: 150, y: 190)
            ZStack {
                Circle().strokeBorder(LinearGradient(colors: [Color.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom), lineWidth: 26)
                Circle().fill(RadialGradient(colors: [teal, Color(red: 0.08, green: 0.45, blue: 0.48)], center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 90)).padding(40)
            }
            .frame(width: 220, height: 220)
            .shadow(color: teal.opacity(0.6), radius: 30)
            .offset(x: 150, y: 190)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Icon-scale stethoscope, centered on the 1024 canvas.
struct IconStethoscope: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.midX + x, y: rect.midY + y) }
        var p = Path()
        p.move(to: pt(-110, -290)); p.addQuadCurve(to: pt(-40, 20), control: pt(-150, -40))
        p.move(to: pt(30, -290)); p.addQuadCurve(to: pt(-40, 20), control: pt(70, -40))
        p.move(to: pt(-40, 20))
        p.addCurve(to: pt(150, 80), control1: pt(-60, 330), control2: pt(150, 330))
        return p
    }
}
