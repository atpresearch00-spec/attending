import Foundation

/// Turns Codex rollout files (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl) into session
/// lifecycle events. Every Codex client writes them: the ChatGPT and Codex desktop apps,
/// the IDE extension and the CLI, so this sees sessions Attending didn't start.
///
/// Only the session header and turn boundaries are read. Messages, commands and tool
/// output are skipped without being decoded.
public struct CodexRolloutReader: Sendable {
    public private(set) var threadID: String?
    public private(set) var projectPath: String?
    /// Helper threads Codex spawns for itself (reviewers, guardians) aren't shown.
    public private(set) var isSubagent = false
    /// Whether the newest turn in what's been read so far is still running.
    public private(set) var turnOpen = false
    public private(set) var lastTurnEvent: Date?
    /// Questions Codex asked (request_user_input) that haven't been answered yet.
    public private(set) var openQuestions: Set<String> = []

    public init() {}

    /// Marks the open turn as over, for a session that went silent (Codex quit mid-turn).
    public mutating func closeTurn() { turnOpen = false }

    /// Reads complete lines and returns the lifecycle events they contain.
    public mutating func consume<Lines: Sequence>(_ lines: Lines) -> [AgentEvent] where Lines.Element: StringProtocol {
        var events: [AgentEvent] = []
        for line in lines {
            // Cheap filter first: the lines that matter are a tiny fraction of the file.
            guard line.contains("\"session_meta\"") || line.contains("\"task_started\"") || line.contains("\"task_complete\"") || line.contains("\"turn_aborted\"")
                    || line.contains("request_user_input") || (!openQuestions.isEmpty && line.contains("\"function_call_output\"")) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let time = (object["timestamp"] as? String).flatMap(Self.date) ?? Date()
            switch object["type"] as? String {
            case "session_meta":
                guard threadID == nil else { continue }
                threadID = payload["id"] as? String
                projectPath = payload["cwd"] as? String
                isSubagent = payload["source"] is [String: Any]
            case "event_msg":
                let kind: AgentEvent.Kind
                switch payload["type"] as? String {
                case "task_started": kind = .working; turnOpen = true
                case "task_complete": kind = .completed; turnOpen = false; openQuestions = []
                case "turn_aborted": kind = .stopped; turnOpen = false; openQuestions = []
                default: continue
                }
                lastTurnEvent = time
                if let threadID, let projectPath, !isSubagent {
                    events.append(AgentEvent(provider: .codex, sessionID: threadID, projectPath: projectPath, kind: kind, timestamp: time))
                }
            case "response_item":
                // Codex asks multiple-choice questions with a request_user_input tool call, and the
                // answer arrives as that call's output. Only the call's name and ID are read.
                let kind: AgentEvent.Kind
                switch payload["type"] as? String {
                case "function_call":
                    guard (payload["name"] as? String)?.hasPrefix("request_user_input") == true, let call = payload["call_id"] as? String else { continue }
                    openQuestions.insert(call); kind = .attention
                case "function_call_output":
                    guard let call = payload["call_id"] as? String, openQuestions.remove(call) != nil, openQuestions.isEmpty else { continue }
                    kind = .working
                default: continue
                }
                if let threadID, let projectPath, !isSubagent {
                    events.append(AgentEvent(provider: .codex, sessionID: threadID, projectPath: projectPath, kind: kind, timestamp: time))
                }
            default: continue
            }
        }
        return events
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Thread names Codex keeps in ~/.codex/session_index.jsonl (one JSON object per line,
/// newest last), so sessions show the name you see in the Codex sidebar.
public enum CodexThreadNames {
    public static func parse(_ text: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}

/// The name Claude Code shows for a session, read from the end of its transcript: a name you
/// gave it wins over the one Claude generated. Only the title records are decoded.
public enum ClaudeSessionTitle {
    public static func parse(_ tail: String) -> String? {
        var custom: String?, generated: String?
        for line in tail.split(separator: "\n") where line.contains("\"custom-title\"") || line.contains("\"ai-title\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "custom-title": custom = (object["customTitle"] as? String) ?? custom
            case "ai-title": generated = (object["aiTitle"] as? String) ?? generated
            default: continue
            }
        }
        return [custom, generated].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
