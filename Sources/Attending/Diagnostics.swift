import AppKit
import AVFoundation
import CoreLocation
import EventKit
import ApplicationServices

/// A short, non-personal summary for bug reports: versions, hardware, where the app runs
/// from and which permissions it has. No names, paths, calendars or sessions.
@MainActor enum Diagnostics {
    static func summary() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let bundle = Bundle.main.bundleURL.path
        let location = bundle.contains("/AppTranslocation/") ? "translocated (opened from a download)"
            : MoveToApplications.isInApplications(Bundle.main.bundleURL) ? "Applications" : "outside Applications"
        let screens = NSScreen.screens
        func status(_ value: Int, _ names: [Int: String]) -> String { names[value] ?? "unknown" }
        let camera = status(AVCaptureDevice.authorizationStatus(for: .video).rawValue, [0: "not asked", 1: "restricted", 2: "denied", 3: "allowed"])
        let calendar = status(EKEventStore.authorizationStatus(for: .event).rawValue, [0: "not asked", 1: "restricted", 2: "denied", 3: "allowed", 4: "write only"])
        let location2 = status(Int(CLLocationManager().authorizationStatus.rawValue), [0: "not asked", 1: "restricted", 2: "denied", 3: "allowed", 4: "allowed"])
        return [
            "Attending \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · \(Bundle.main.bundleIdentifier == Updater.publicBundleID ? "release" : "own build")",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string"))",
            "Runs from: \(location)",
            "Displays: \(screens.count), notch: \(screens.contains { $0.safeAreaInsets.top > 0 } ? "yes" : "no")",
            "Permissions: Accessibility \(AXIsProcessTrusted() ? "allowed" : "off"), Calendar \(calendar), Camera \(camera), Location \(location2)",
        ].joined(separator: "\n")
    }

    /// Opens a new GitHub issue with the diagnostics filled in, for the person to finish.
    static func report() {
        var components = URLComponents(string: "https://github.com/\(Updater.repository)/issues/new")!
        components.queryItems = [URLQueryItem(name: "template", value: "bug-report.yml"), URLQueryItem(name: "diagnostics", value: summary())]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(), forType: .string)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}
