#!/usr/bin/env python3
"""Exercise Attending's Claude approval bridge with a local Unix-socket fixture; starts no agent."""

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(os.environ.get("ATTENDING_BRIDGE_BIN", ROOT / ".build" / "debug" / "attending-bridge"))
MAX_MESSAGE = 131_072


def temporary_root():
    # The Codex workspace sandbox allows Unix-domain sockets under /private/tmp.
    return tempfile.TemporaryDirectory(prefix="attending-approvals-", dir="/private/tmp")


def hook_payload(command="printf 'full command with spaces\\n'"):
    return {
        "session_id": "approval-test-session",
        "cwd": "/tmp/approval-test-project",
        "permission_mode": "default",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {
            "command": command,
            "description": "Exercise the local approval transport",
        },
    }


def run_bridge(root, payload, *arguments, timeout=3):
    environment = os.environ.copy()
    environment["ATTENDING_DATA_DIR"] = str(root)
    return subprocess.run(
        [str(BRIDGE), *arguments],
        input=json.dumps(payload).encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=timeout,
        check=True,
    )


def read_exact(connection, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("bridge disconnected before completing a frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(connection):
    length = struct.unpack("!I", read_exact(connection, 4))[0]
    assert 0 < length <= MAX_MESSAGE
    return json.loads(read_exact(connection, length))


def write_frame(connection, value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    connection.sendall(struct.pack("!I", len(payload)) + payload)


class ApprovalFixture:
    def __init__(self, root, decision="allowOnce", corrupt_token=False, delay=0, answers=None):
        self.run_directory = Path(root) / "run"
        self.run_directory.mkdir(mode=0o700)
        os.chmod(self.run_directory, 0o700)
        self.path = self.run_directory / "approval.sock"
        self.decision = decision
        self.answers = answers
        self.corrupt_token = corrupt_token
        self.delay = delay
        self.envelope = None
        self.error = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        assert self.ready.wait(1), "fixture did not bind"
        return self

    def __exit__(self, *_):
        self.thread.join(2)
        if self.error:
            raise self.error

    def serve(self):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.path))
            os.chmod(self.path, 0o600)
            server.listen(1)
            server.settimeout(2)
            self.ready.set()
            connection, _ = server.accept()
            with connection:
                self.envelope = read_frame(connection)
                if self.delay:
                    time.sleep(self.delay)
                token = self.envelope["token"]
                if self.corrupt_token:
                    token = "0" * len(token)
                try:
                    response = {
                        "requestID": self.envelope["request"]["id"],
                        "token": token,
                        "decision": self.decision,
                    }
                    if self.answers is not None:
                        response["answers"] = self.answers
                    write_frame(connection, response)
                except BrokenPipeError:
                    if not self.delay:
                        raise
        except Exception as error:
            self.error = error
            self.ready.set()
        finally:
            server.close()


def assert_sanitized_event(root):
    files = list((Path(root) / "events").glob("*.json"))
    assert len(files) == 1
    data = files[0].read_text()
    assert "full command" not in data and "tool_input" not in data
    assert (files[0].stat().st_mode & 0o777) == 0o600


def test_observation_unchanged():
    with temporary_root() as root:
        result = run_bridge(root, hook_payload())
        assert result.stdout == b"" and result.stderr == b""
        assert_sanitized_event(root)


def test_absent_app_returns_immediately():
    with temporary_root() as root:
        started = time.monotonic()
        result = run_bridge(root, hook_payload(), "--approval-wait=0.3")
        assert result.stdout == b""
        assert time.monotonic() - started < 0.5


def test_allow_once_and_full_input():
    with temporary_root() as root:
        payload = hook_payload()
        with ApprovalFixture(root, decision="allowOnce") as fixture:
            result = run_bridge(root, payload, "--approval-wait=1")
        output = json.loads(result.stdout)
        assert output == {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }
        request = fixture.envelope["request"]
        assert request["command"] == payload["tool_input"]["command"]
        assert json.loads(request["toolInputJSON"]) == payload["tool_input"]
        assert len(fixture.envelope["token"]) == 64
        assert_sanitized_event(root)


def question_payload():
    payload = hook_payload()
    payload["tool_name"] = "AskUserQuestion"
    payload["tool_input"] = {"questions": [{
        "question": "Which format?", "header": "Format", "multiSelect": False,
        "options": [{"label": "Summary", "description": "Brief"}, {"label": "Detailed", "description": "Full"}],
    }]}
    return payload


def test_question_answers_and_pass_through():
    with temporary_root() as root:
        payload = question_payload()
        with ApprovalFixture(root, decision="allowOnce", answers={"Which format?": "Detailed"}):
            result = run_bridge(root, payload, "--approval-wait=1")
        decision = json.loads(result.stdout)["hookSpecificOutput"]["decision"]
        assert decision == {"behavior": "allow", "updatedInput": {**payload["tool_input"], "answers": {"Which format?": "Detailed"}}}
    with temporary_root() as root:
        # Allow without answers would leave the question blank, so Claude asks instead.
        with ApprovalFixture(root, decision="allowOnce"):
            result = run_bridge(root, question_payload(), "--approval-wait=1")
        assert result.stdout == b""
    with temporary_root() as root:
        with ApprovalFixture(root, decision="askInProvider"):
            result = run_bridge(root, hook_payload(), "--approval-wait=1")
        assert result.stdout == b""


def test_deny():
    with temporary_root() as root:
        with ApprovalFixture(root, decision="deny"):
            result = run_bridge(root, hook_payload(), "--approval-wait", "1")
        decision = json.loads(result.stdout)["hookSpecificOutput"]["decision"]
        assert decision == {"behavior": "deny", "message": "Denied in Attending.", "interrupt": False}


def test_mismatched_response_falls_back():
    with temporary_root() as root:
        with ApprovalFixture(root, corrupt_token=True):
            result = run_bridge(root, hook_payload(), "--approval-wait=1")
        assert result.stdout == b""


def test_timeout_falls_back():
    with temporary_root() as root:
        started = time.monotonic()
        with ApprovalFixture(root, delay=0.5):
            result = run_bridge(root, hook_payload(), "--approval-wait=0.2")
        assert result.stdout == b""
        assert time.monotonic() - started < 1


def test_oversized_tool_input_never_connects():
    with temporary_root() as root:
        payload = hook_payload("x" * 70_000)
        result = run_bridge(root, payload, "--approval-wait=1")
        assert result.stdout == b""
        assert_sanitized_event(root)


def main():
    if not BRIDGE.is_file():
        raise SystemExit(f"Bridge executable not found: {BRIDGE}; build Attending or set ATTENDING_BRIDGE_BIN")
    tests = [
        test_observation_unchanged,
        test_absent_app_returns_immediately,
        test_allow_once_and_full_input,
        test_question_answers_and_pass_through,
        test_deny,
        test_mismatched_response_falls_back,
        test_timeout_falls_back,
        test_oversized_tool_input_never_connects,
    ]
    for test in tests:
        test()
    print(f"PASS: {len(tests)} approval transport checks")


if __name__ == "__main__":
    main()

with temporary_root() as native_root:
    executable = Path(native_root) / "broker-check"
    compiler_env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / ".build/clang-cache"))
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Sources/AttendingCore/Models.swift"), str(ROOT / "Sources/AttendingCore/Approvals.swift"), str(ROOT / "scripts/fixtures/ApprovalBrokerHarness.swift"), "-o", str(executable)], check=True, env=compiler_env)
    subprocess.run([str(executable), str(BRIDGE)], check=True, timeout=10)
