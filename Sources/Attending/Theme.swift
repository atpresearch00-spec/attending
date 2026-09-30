import SwiftUI
import AttendingCore

enum Theme {
    static let background = Color(red: 0, green: 0, blue: 0)
    static let card = Color.white.opacity(0.065)
    static let raised = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.08)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let working = Color(red: 0.36, green: 0.80, blue: 1.00)
    static let attention = Color(red: 1.00, green: 0.62, blue: 0.26)
    static let done = Color(red: 0.42, green: 0.90, blue: 0.66)
    static let failed = Color(red: 1.00, green: 0.38, blue: 0.38)
    static let amber = Color(red: 1.00, green: 0.82, blue: 0.46)
    static let cardRadius: CGFloat = 16
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: Theme.working
        case .attention: Theme.attention
        case .completed: Theme.done
        case .failed: Theme.failed
        case .stale: Color.gray
        case .idle: Theme.secondary
        }
    }
}

/// Island that grows out of the hardware notch: flush top edge with concave
/// "ears" into the menu bar, and rounded lower corners.
struct IslandShape: Shape {
    var ear: CGFloat = 10
    var radius: CGFloat = 24
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let e = min(ear, rect.width / 4), r = min(radius, (rect.width - 2 * e) / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + r, y: rect.maxY), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - r), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 26
    var weight: Font.Weight = .semibold
    var tint: Color = Theme.secondary
    var filled = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: weight))
                .foregroundStyle(hovering ? Theme.primary : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(filled || hovering ? Theme.raised : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.primary
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 11).frame(height: 24)
            .foregroundStyle(prominent ? Color.black : tint)
            .background(Capsule().fill(prominent ? tint : (hovering ? Theme.raised : Theme.card)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.tertiary)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: pulsing ? color.opacity(0.8) : .clear, radius: 3)
    }
}

/// Settings-style switch: label on the left, switch aligned to the trailing edge.
struct TrailingSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.done)
        }
    }
}
