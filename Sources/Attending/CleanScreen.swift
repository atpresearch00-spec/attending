import AppKit
import SwiftUI

/// For screen recordings and presentations: hides the desktop icons and keeps private
/// details out of the notch (calendar titles, agent session names, what's playing,
/// clipboard and notes). Turned off on quit, so the icons always come back.
@MainActor final class CleanScreen: ObservableObject {
    @Published private(set) var on = false
    var onChange: ((Bool) -> Void)?
    private static let finder = "com.apple.finder" as CFString
    private static let key = "CreateDesktop" as CFString

    func toggle() { set(!on) }
    func set(_ value: Bool) {
        guard value != on else { return }
        on = value
        // Remember whether icons were showing, so turning it off restores the user's choice.
        if value { UserDefaults.standard.set(Self.iconsShown, forKey: "cleanScreenIconsWereShown") }
        let restore = UserDefaults.standard.object(forKey: "cleanScreenIconsWereShown") as? Bool ?? true
        Self.setIcons(shown: value ? false : restore)
        onChange?(value)
    }

    private static var iconsShown: Bool {
        CFPreferencesCopyAppValue(key, finder) as? Bool ?? true
    }
    /// Finder reads this at launch, so it's restarted (it reopens on its own).
    private static func setIcons(shown: Bool) {
        guard iconsShown != shown else { return }
        CFPreferencesSetAppValue(key, shown as CFBoolean, finder)
        CFPreferencesAppSynchronize(finder)
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["Finder"]
        try? killall.run()
    }
}

private struct CleanScreenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while Clean screen is on: views leave out private details.
    var cleanScreen: Bool { get { self[CleanScreenKey.self] } set { self[CleanScreenKey.self] = newValue } }
}

/// What a hidden page shows while Clean screen is on.
struct HiddenForCleanScreen: View {
    let what: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.tertiary)
            Text("\(what) is hidden while Clean screen is on").font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
