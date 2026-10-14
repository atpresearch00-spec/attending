import Foundation

/// Connects Claude Code to Attending from inside the app: adds the bridge as a hook for
/// each lifecycle event (questions and approvals wait up to 65 s for an answer from the
/// notch, then fall back to Claude), and the usage status line if there isn't one.
/// The same merge as scripts/install-claude-hooks.py: other hooks and settings are kept,
/// the first original is backed up, and nothing about permissions changes.
@MainActor enum ClaudeHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true) }
    static var settingsURL: URL { folder.appendingPathComponent("settings.json") }

    /// Claude Code has been used on this Mac.
    static var claudeInstalled: Bool { FileManager.default.fileExists(atPath: folder.path) }
    static var bridge: URL? {
        Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("attending-bridge") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
    /// Every event already points at this copy's bridge.
    static var installed: Bool {
        guard let bridge, let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        let command = quote(bridge.path)
        return events.allSatisfy { event in
            let wanted = event == "PermissionRequest" ? command + " --approval-wait" : command
            return (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == wanted }
            }
        }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    /// Writes the hooks (and the status line when free). Returns a short note for the UI.
    @discardableResult
    static func install() throws -> String {
        guard let bridge else { throw Failure.message("The bridge is missing from this copy of Attending.") }
        guard MoveToApplications.isInApplications(Bundle.main.bundleURL) || Bundle.main.bundleIdentifier != Updater.publicBundleID else {
            throw Failure.message("Move Attending to Applications first, so Claude Code can always find it.")
        }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: settingsURL.path)) != nil { throw Failure.message("Claude's settings file is a link, so Attending left it alone.") }
        let raw = try? Data(contentsOf: settingsURL)
        var settings: [String: Any] = [:]
        if let raw, !raw.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Failure.message("Claude's settings couldn't be read, so nothing was changed.") }
            settings = parsed
        }
        settings = try merged(settings, bridge: bridge.path)
        var note = "Connected. Start a new Claude Code session to see it in the notch."
        if let line = settings["statusLine"] as? [String: Any], !(line["command"] as? String ?? "").contains("attending-bridge") {
            note += " Your own status line was kept, so the usage meter stays off."
        } else {
            settings["statusLine"] = ["type": "command", "command": quote(bridge.path) + " --statusline", "refreshInterval": 60]
        }
        let encoded = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let raw {
            let backup = settingsURL.appendingPathExtension("attending-backup")
            if !fm.fileExists(atPath: backup.path) { fm.createFile(atPath: backup.path, contents: raw, attributes: [.posixPermissions: 0o600]) }
        }
        // Stop if something else changed the file meanwhile.
        guard (try? Data(contentsOf: settingsURL)) == raw else { throw Failure.message("Claude's settings changed while connecting. Try again.") }
        try encoded.write(to: settingsURL, options: .atomic)
        return note
    }

    static func merged(_ settings: [String: Any], bridge: String) throws -> [String: Any] {
        var result = settings
        if let existing = result["hooks"], !(existing is [String: Any]) { throw Failure.message("Claude's hooks setting isn't in the expected shape, so nothing was changed.") }
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let command = quote(bridge)
        for event in events {
            let selected = event == "PermissionRequest" ? command + " --approval-wait" : command
            guard var entries = (hooks[event] ?? [[String: Any]]()) as? [[String: Any]] else { throw Failure.message("Claude's \(event) hooks aren't in the expected shape, so nothing was changed.") }
            // Drop only Attending's own hooks that point elsewhere (an older copy, the other
            // approval mode); every other command stays.
            entries = entries.compactMap { group in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { hook in
                    let text = hook["command"] as? String ?? ""
                    return !(text.contains("attending-bridge") && text != selected)
                }
                group["hooks"] = kept
                return kept.isEmpty ? nil : group
            }
            let present = entries.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == selected } }
            if !present {
                entries.append(["matcher": event == "Notification" ? "permission_prompt" : "",
                                "hooks": [["type": "command", "command": selected, "timeout": event == "PermissionRequest" ? 65 : 3]]])
            }
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    /// Shell quoting that matches Python's shlex.quote, so both installers agree.
    static func quote(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if !text.isEmpty && text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
