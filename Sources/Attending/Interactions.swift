import SwiftUI
import AttendingCore

struct ChatView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.selectedSession {
                Text("Send to: \(session.provider.title) · \(session.title)").font(.headline)
                Text("Session \(session.externalID.prefix(12))").font(.caption2).foregroundStyle(.secondary)
                if model.canSendToSelected {
                    TextField("Give this session an instruction…", text: $model.draft, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($focused)
                    HStack {
                        Button("Send instruction", action: model.sendDraft).disabled(model.codexBusy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.codexTurns[session.externalID] != nil { Button("Stop turn", role: .destructive, action: model.stopSelectedTurn) }
                        if model.codexBusy { ProgressView().controlSize(.small) }
                    }
                    Text("Uses your existing Codex sign-in. Commands stay subject to Codex's sandbox and approval policy.").font(.caption2).foregroundStyle(.secondary)
                    if let response = model.responseText[session.externalID], !response.isEmpty {
                        Divider()
                        Text(response).font(.system(size: 12)).textSelection(.enabled)
                    }
                } else {
                    Text("This is an externally observed session. Its provider does not expose a supported instruction channel to Attending.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Choose a session from Active or Recent.").font(.headline)
                Text("You can also start a Codex session managed by Attending for a local project.").font(.caption).foregroundStyle(.secondary)
            }
            Button("New Codex session for project…", action: model.newCodexProject).disabled(!model.codexDetected || model.codexBusy)
        }.onAppear { focused = true }
    }
}
struct ApprovalInbox: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Waiting for approval")
            ForEach(model.claudeApprovals) { request in
                approvalCard {
                    Text("Claude Code · \(URL(fileURLWithPath: request.projectPath).lastPathComponent)").font(.system(size: 14, weight: .semibold))
                    Text(request.projectPath).font(.system(size: 10)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                    Text("Wants to use \(request.toolName)").font(.system(size: 12, weight: .medium))
                    // Complete input remains inspectable; no truncation hidden behind Allow.
                    code(request.toolInputJSON)
                    Text("This grants permission for this request only. Inspect the complete action and target before allowing.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    HStack {
                        PillButton(title: "Deny", symbol: "xmark", tint: Theme.failed) { model.respondClaude(request, decision: .deny) }
                        PillButton(title: "Allow Once", symbol: "checkmark", tint: Theme.done, prominent: true) { model.respondClaude(request, decision: .allowOnce) }
                    }
                }
            }
            ForEach(model.codexApprovals, id: \.id) { request in
                approvalCard {
                    Text("Codex permission request").font(.system(size: 14, weight: .semibold))
                    Text(request.cwd ?? "See requested action").font(.system(size: 10)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                    Text("Session \(request.threadID.prefix(12)) · Turn \(request.turnID.prefix(12))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    if let reason = request.reason { Text(reason).font(.system(size: 12)) }
                    DisclosureGroup("Complete request and scope") { code(request.contextJSON) }.font(.system(size: 11))
                    if let command = request.command { code(command) }
                    if let diff = request.diff { code(diff) }
                    if let explanation = request.unavailableReason { Text(explanation).font(.system(size: 11)).foregroundStyle(Theme.attention) }
                    HStack {
                        PillButton(title: "Deny", symbol: "xmark", tint: Theme.failed) { model.respondCodex(request, decision: .deny) }.disabled(!request.availableDecisions.contains(.deny))
                        if request.availableDecisions.contains(.cancel) { PillButton(title: "Cancel turn", symbol: nil) { model.respondCodex(request, decision: .cancel) } }
                        PillButton(title: "Allow Once", symbol: "checkmark", tint: Theme.done, prominent: true) { model.respondCodex(request, decision: .allowOnce) }.disabled(!request.canAllow)
                    }
                }
            }
        }
    }
    private func approvalCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.attention.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.attention.opacity(0.35), lineWidth: 1))
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.5)))
    }
}
