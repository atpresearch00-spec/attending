#!/usr/bin/env python3
"""Offline app-server fixture for Attending's transport harness; never calls a model."""
import json
import sys
import time


def send(value, split=False):
    payload = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    if split:
        midpoint = max(1, len(payload) // 2)
        sys.stdout.buffer.write(payload[:midpoint])
        sys.stdout.buffer.flush()
        time.sleep(0.02)
        sys.stdout.buffer.write(payload[midpoint:])
    else:
        sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"serverInfo": {"name": "fixture"}}}, split=True)
    elif method == "initialized":
        continue
    elif method == "thread/start":
        assert request["params"]["approvalsReviewer"] == "user"
        send({"jsonrpc": "2.0", "id": request_id, "result": {"thread": {"id": "owned-thread"}}})
    elif method == "turn/start":
        assert request["params"]["approvalsReviewer"] == "user"
        send({"jsonrpc": "2.0", "id": request_id, "result": {"turn": {"id": "turn-1"}}}, split=True)
        # No item-specific patch or broad permission can be safely approved.
        send({"jsonrpc": "2.0", "id": "missing-file-approval", "method": "item/fileChange/requestApproval", "params": {
            "threadId": "owned-thread", "turnId": "turn-1", "itemId": "file-item", "startedAtMs": 1,
            "grantRoot": "/outside-project", "reason": "fixture permission request"
        }})
    elif method == "turn/steer":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"turnId": "turn-1"}})
        send({"jsonrpc": "2.0", "id": 99, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": "owned-thread", "turnId": "turn-1", "itemId": "command-item", "startedAtMs": 2,
            "command": "curl https://example.com", "networkApprovalContext": {"host": "example.com"}
        }})
    elif request_id == 99:
        assert request["result"]["decision"] == "decline", request
        send({"jsonrpc": "2.0", "id": 100, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": "owned-thread", "turnId": "turn-1", "itemId": "restricted-command", "startedAtMs": 3,
            "command": "printf fixture", "availableDecisions": ["decline"]
        }})
    elif request_id == 100:
        assert request["result"]["decision"] == "decline", request
    elif method == "turn/interrupt":
        # Exercise rejection of an outstanding request on process death.
        sys.exit(17)
    elif request_id == "missing-file-approval":
        assert request["result"]["decision"] == "decline", request
    elif request_id == 99:
        assert request["result"]["decision"] == "decline", request
    else:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "fixture unknown method"}})
