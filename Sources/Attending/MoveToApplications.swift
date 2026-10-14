import AppKit

/// Offers to move a downloaded copy into Applications. Run from Downloads (or straight out
/// of the zip, where macOS runs it from a hidden read-only copy), Attending can't update
/// itself and macOS may forget its permissions. Public builds only.
@MainActor enum MoveToApplications {
    /// Returns true when Attending is moving (and about to relaunch from Applications).
    @discardableResult
    static func offerIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        // Development runs (any --flag) skip it.
        guard Bundle.main.bundleIdentifier == Updater.publicBundleID, !isInApplications(bundle),
              !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
              !UserDefaults.standard.bool(forKey: "moveToApplicationsDeclined") else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Attending to Applications?"
        alert.informativeText = "It's running from \(where_(bundle)). In Applications it can update itself and macOS keeps its permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate()
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "moveToApplicationsDeclined") }
        guard answer == .alertFirstButtonReturn else { return false }
        do { try move(bundle); return true } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move Attending"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag Attending into your Applications folder in Finder, then open it from there."
            failed.runModal()
            return false
        }
    }

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }
    /// macOS runs apps opened from a download in a randomized read-only location.
    private static func isTranslocated(_ url: URL) -> Bool { url.path.contains("/AppTranslocation/") }
    private static func where_(_ url: URL) -> String {
        if isTranslocated(url) { return "your download" }
        let parent = url.deletingLastPathComponent()
        return parent.lastPathComponent.isEmpty ? "another folder" : "your \(parent.lastPathComponent) folder"
    }

    static func move(_ bundle: URL) throws {
        let fm = FileManager.default
        // /Applications needs an admin account; otherwise use ~/Applications.
        // ATTENDING_APPLICATIONS_DIR points elsewhere for tests.
        let override = ProcessInfo.processInfo.environment["ATTENDING_APPLICATIONS_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        var folder = override ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
        if override == nil && !fm.isWritableFile(atPath: folder.path) {
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appendingPathComponent("Attending.app")
        if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
        try fm.copyItem(at: bundle, to: destination)
        // The person already chose to open this copy; the moved one shouldn't ask again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run(); xattr.waitUntilExit()
        // The original goes to the Trash when we know where it is (not a translocated copy).
        if !isTranslocated(bundle) { try? fm.trashItem(at: bundle, resultingItemURL: nil) }
        relaunch(destination)
    }

    /// Opens the moved copy once this process has quit (only one copy runs at a time).
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
