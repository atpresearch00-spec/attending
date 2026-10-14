import AppKit
import ApplicationServices
import Carbon

/// Rectangle-style keyboard shortcuts that move the front window into halves, thirds,
/// the center or the whole screen. Moving other apps' windows uses Accessibility.
@MainActor final class WindowSnapper: ObservableObject {
    enum Region: String, CaseIterable {
        case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center, firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
        var title: String {
            switch self {
            case .leftHalf: "Left half"; case .rightHalf: "Right half"; case .topHalf: "Top half"; case .bottomHalf: "Bottom half"
            case .maximize: "Maximize"; case .center: "Center"
            case .firstThird: "First third"; case .centerThird: "Center third"; case .lastThird: "Last third"
            case .firstTwoThirds: "First two thirds"; case .lastTwoThirds: "Last two thirds"
            }
        }
        /// Same keys as Rectangle, with ⌃⌥.
        var key: (code: Int, label: String) {
            switch self {
            case .leftHalf: (kVK_LeftArrow, "←"); case .rightHalf: (kVK_RightArrow, "→"); case .topHalf: (kVK_UpArrow, "↑"); case .bottomHalf: (kVK_DownArrow, "↓")
            case .maximize: (kVK_Return, "↩"); case .center: (kVK_ANSI_C, "C")
            case .firstThird: (kVK_ANSI_D, "D"); case .centerThird: (kVK_ANSI_F, "F"); case .lastThird: (kVK_ANSI_G, "G")
            case .firstTwoThirds: (kVK_ANSI_E, "E"); case .lastTwoThirds: (kVK_ANSI_T, "T")
            }
        }
        /// The target as fractions of the screen's usable area (x, y from top, width, height).
        var unit: CGRect {
            switch self {
            case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
            case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
            case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
            case .center: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
            case .firstThird: CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
            case .centerThird: CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
            case .lastThird: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
            case .firstTwoThirds: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
            case .lastTwoThirds: CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
            }
        }
    }

    @Published var enabled = UserDefaults.standard.bool(forKey: "windowSnapping") {
        didSet { UserDefaults.standard.set(enabled, forKey: "windowSnapping"); enabled ? start() : stop() }
    }
    /// Shortcuts another app (Rectangle, say) already holds.
    @Published private(set) var taken: [Region] = []
    private var shortcuts: [GlobalShortcut] = []

    func start() {
        stop()
        guard enabled else { return }
        var unavailable: [Region] = []
        for region in Region.allCases {
            if let shortcut = try? GlobalShortcut(keyCode: region.key.code, modifiers: controlKey | optionKey, action: { [weak self] in self?.snap(region) }) {
                shortcuts.append(shortcut)
            } else { unavailable.append(region) }
        }
        taken = unavailable
    }
    func stop() { shortcuts.forEach { $0.invalidate() }; shortcuts = []; taken = [] }

    func snap(_ region: Region) {
        guard AXIsProcessTrusted() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success, let window = value else { return }
        let element = window as! AXUIElement
        // The screen the window is on (AX coordinates have their origin at the top left of the main screen).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let current = frame(of: element)
        let center = CGPoint(x: current.midX, y: primaryHeight - current.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let area = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
        let unit = region.unit
        let target = CGRect(x: area.minX + area.width * unit.minX, y: area.minY + area.height * unit.minY, width: area.width * unit.width, height: area.height * unit.height).integral
        var origin = target.origin, size = target.size
        // Size, move, then size again: some apps clamp the size to the screen they're on.
        if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) }
        if let originValue = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue) }
        if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) }
    }
    private func frame(of window: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let value { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: position, size: size)
    }
}
