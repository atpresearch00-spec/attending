#!/usr/bin/env python3
"""Offline contract checks for the bounded Codex app-server adapter.

This intentionally does not send a prompt to Codex. It verifies the generated
protocol schemas and the security-critical source contract without requiring an
account, network, or a running provider process.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
codex = next((p for p in [Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), Path("/Applications/ChatGPT.app/Contents/Resources/codex")] if p.exists()), Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"))
fixture = root / "scripts/fixtures/fake-codex-app-server.py"
harness = root / "scripts/fixtures/CodexTransportHarness.swift"

with tempfile.TemporaryDirectory(prefix="attending-codex-schema-") as temporary:
    subprocess.run(
        [str(codex), "app-server", "generate-json-schema", "--out", temporary],
        check=True,
        capture_output=True,
        text=True,
    )
    schema_root = Path(temporary)
    turn_start = json.loads((schema_root / "v2/TurnStartParams.json").read_text())
    thread_start = json.loads((schema_root / "v2/ThreadStartParams.json").read_text())
    steer = json.loads((schema_root / "v2/TurnSteerResponse.json").read_text())
    command_reply = json.loads((schema_root / "CommandExecutionRequestApprovalResponse.json").read_text())
    file_reply = json.loads((schema_root / "FileChangeRequestApprovalResponse.json").read_text())
    assert {"threadId", "input"}.issubset(turn_start["required"])
    assert {"approvalPolicy", "sandboxPolicy"}.issubset(turn_start["properties"])
    assert {"cwd", "approvalPolicy", "sandbox"}.issubset(thread_start["properties"])
    assert steer["required"] == ["turnId"]
    for reply in (command_reply, file_reply):
        decision = reply["definitions"]
        assert "accept" in json.dumps(decision) and "decline" in json.dumps(decision)

with tempfile.TemporaryDirectory(prefix="attending-codex-harness-") as temporary:
    temporary = Path(temporary)
    fixture.chmod(0o755)
    executable = temporary / "codex-transport-harness"
    compiler_env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / ".build/clang-cache"))
    subprocess.run([
        "swiftc", "-parse-as-library",
        str(root / "Sources/AttendingCore/Models.swift"),
        str(root / "Sources/AttendingCore/CodexTransport.swift"),
        str(harness),
        "-o", str(executable),
    ], check=True, capture_output=True, text=True, env=compiler_env)
    result = subprocess.run([str(executable), str(fixture)], check=True, capture_output=True, text=True, timeout=10)
    assert "PASS: fake app-server" in result.stdout, result.stdout + result.stderr

# This is intentionally readiness-only: no thread or turn is started, so no model
# inference is requested. It proves the installed app bundle accepts the documented
# initialize -> initialized JSONL handshake used by the Swift transport.
process = subprocess.Popen(
    [str(codex), "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    assert process.stdin and process.stdout
    process.stdin.write(json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"clientInfo": {"name": "attending-transport-test", "version": "0"}},
    }) + "\n")
    process.stdin.flush()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    events = selector.select(timeout=15)
    assert events, "Codex app-server did not answer initialize within 15 seconds"
    response = json.loads(process.stdout.readline())
    assert response.get("id") == 1 and "result" in response, response
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
    process.stdin.flush()
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)

print("PASS: Codex transport schema, fake-process behavior, real initialize readiness, and bounded fail-closed approvals")
