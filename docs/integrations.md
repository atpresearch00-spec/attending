# Provider integrations

Inspected locally: Claude Code 2.1.250; Codex CLI 0.153.4 bundled in ChatGPT.app. Research used CLI help and generated protocol schemas without inference, private transcripts or credentials.

## Claude Code
Documented hooks include SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, Stop, SessionEnd. `session_id`, `cwd` and `hook_event_name` associate events; Attending discards transcript_path and ordinary prompt/tool contents. `Notification` permission_prompt is observational. PermissionRequest can return a synchronous JSON decision; an asynchronous event alone cannot approve. A bounded private Unix socket will relay explicit allow-once/deny decisions, falling back to Claude's normal permission UI when unavailable.

`claude agents --json` can discover active interactive/background sessions, but is a snapshot rather than an event subscription. `claude attach/logs/stop` apply to supported background sessions. No external CLI injection into an arbitrary live session. Resume launches another process and must not be used concurrently as a substitute for injection. Attending will not pretend Finder opens the terminal session.

References: https://code.claude.com/docs/en/hooks ; https://code.claude.com/docs/en/agent-view ; https://code.claude.com/docs/en/cross-session-messaging ; https://code.claude.com/docs/en/remote-control

## Codex
`codex app-server --stdio` provides a documented JSONL protocol: initialize/initialized; thread/start/resume/read/list; turn/start/steer/interrupt; status, item and turn notifications; correlated command/file-change approvals. Installed CLI labels app-server experimental; stable protocol fields are used without experimentalApi. Each adapter connection owns its turns and outstanding requests. Creating a server does not attach to the running desktop app's server or a standalone CLI's pending approval.

`codex agents`, `codex queue --thread … --message …` and `codex --remote unix://` apply to shared-daemon sessions. Raw thread/queue/add is experimental in generated schema. `codex app PATH` opens a workspace, not a specific live session. Standalone Codex hooks are documented but require their own payload validation and configuration; they are not automatically equivalent to Claude hooks.

Reference: https://learn.chatgpt.com/docs/app-server ; https://learn.chatgpt.com/docs/hooks

## ChatGPT
Consumer sessions do not expose the same app-server controls. No private consumer endpoint is used. Future explicit project/session links may open the native app/browser. OpenAI API sessions are separate from consumer ChatGPT history and must not be represented as consumer session control.
