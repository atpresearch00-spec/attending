import Foundation
import CoreGraphics

public enum PanelMode: Sendable { case idle, preview, expanded }

/// Measured notch facts for one screen, in global screen coordinates (y up).
public struct NotchMetrics: Sendable, Equatable {
    public var screen: CGRect
    public var visible: CGRect
    /// Right edge of the menu-bar area left of the notch (auxiliaryTopLeftArea.maxX).
    public var notchLeft: CGFloat?
    /// Left edge of the menu-bar area right of the notch (auxiliaryTopRightArea.minX).
    public var notchRight: CGFloat?
    public var height: CGFloat
    public var scale: CGFloat
    public init(screen: CGRect, visible: CGRect, notchLeft: CGFloat?, notchRight: CGFloat?, height: CGFloat, scale: CGFloat = 2) {
        self.screen = screen; self.visible = visible; self.notchLeft = notchLeft; self.notchRight = notchRight; self.height = height; self.scale = scale
    }
    /// Only a measured notch counts; never guess one from a hardware model.
    public var hasNotch: Bool {
        guard let left = notchLeft, let right = notchRight else { return false }
        return height >= 20 && right > left && left >= screen.minX && right <= screen.maxX
    }
    public var notchWidth: CGFloat { hasNotch ? notchRight! - notchLeft! : 0 }
    public var center: CGFloat { hasNotch ? (notchLeft! + notchRight!) / 2 : screen.midX }
}

public enum IslandGeometry {
    /// Concave "ear" width where the island meets the top of the screen.
    public static let ear: CGFloat = 6

    /// Collapsed band hugging the notch, with an equal wing on each side so it reads
    /// as part of the hardware. Its bottom edge is snapped to the physical pixel row of
    /// the notch's own bottom edge, so the wings and the notch share one straight line.
    public static func collapsed(_ m: NotchMetrics, wing: CGFloat) -> CGRect {
        if m.hasNotch {
            let scale = max(1, m.scale)
            let bottom = ((m.screen.maxY - m.height) * scale).rounded() / scale
            let width = m.notchWidth + 2 * (wing + ear)
            return clamp(CGRect(x: m.center - width / 2, y: bottom, width: width, height: m.screen.maxY - bottom), to: m.screen)
        }
        // No notch: a small pill centered just below the menu bar.
        let width = 2 * wing + 24, height: CGFloat = 26
        return clamp(CGRect(x: m.center - width / 2, y: m.visible.maxY - 4 - height, width: width, height: height), to: m.visible)
    }

    /// Preview and expanded panels grow out of the notch: flush with the top of the
    /// screen and centered on the notch, so the notch becomes part of the island.
    public static func panel(_ m: NotchMetrics, size: CGSize) -> CGRect {
        if m.hasNotch {
            let width = min(size.width, m.screen.width - 24), height = min(size.height, m.screen.height - 24)
            return clamp(CGRect(x: m.center - width / 2, y: m.screen.maxY - height, width: width, height: height), to: m.screen)
        }
        let width = min(size.width, m.visible.width - 24), height = min(size.height, m.visible.height - 24)
        return clamp(CGRect(x: m.center - width / 2, y: m.visible.maxY - 6 - height, width: width, height: height), to: m.visible)
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
