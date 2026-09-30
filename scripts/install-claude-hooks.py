#!/usr/bin/env python3
"""Merge observational hooks, preserving unrelated Claude settings. No permission changes."""
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile

EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Notification', 'Stop', 'StopFailure', 'SessionEnd']

def merge(settings, bridge, approvals=False, previous_bridges=()):
    result = json.loads(json.dumps(settings))
    hooks = result.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Existing hooks field is not an object; refusing to modify it')
    command = shlex.quote(str(bridge))
    obsolete = {variant for path in previous_bridges if str(path) != str(bridge)
                for variant in (shlex.quote(str(path)), shlex.quote(str(path)) + " --approval-wait")}

    for event in EVENTS:
        selected_command = command + " --approval-wait" if event == "PermissionRequest" and approvals else command
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            raise ValueError(f'Invalid existing {event} hooks; refusing modification')
        if obsolete:
            for group in entries:
                group['hooks'] = [h for h in group.get('hooks', [])
                                  if not (h.get('type') == 'command' and h.get('command') in obsolete)]
            entries[:] = [group for group in entries if group.get('hooks')]
        if any(h.get('command') == selected_command for group in entries for h in group.get('hooks', [])):
            continue
        if event == 'PermissionRequest':
            # Remove only this bridge's superseded hook; preserve every unrelated command.
            alternate = command if approvals else command + ' --approval-wait'
            for group in entries:
                group['hooks'] = [h for h in group.get('hooks', []) if h.get('command') != alternate]
            entries[:] = [group for group in entries if group.get('hooks')]
        entries.append({'matcher': 'permission_prompt' if event == 'Notification' else '', 'hooks': [{'type': 'command', 'command': selected_command, 'timeout': 65 if event == 'PermissionRequest' and approvals else 3}]})
    return result

def merge_status_line(settings, bridge):
    """Add the usage status line unless the user already has their own."""
    result = json.loads(json.dumps(settings))
    command = shlex.quote(str(bridge)) + ' --statusline'
    existing = result.get('statusLine')
    if existing and 'attending-bridge' not in str(existing.get('command', '')):
        return result, False
    result['statusLine'] = {'type': 'command', 'command': command, 'refreshInterval': 60}
    return result, True

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', type=Path, required=True, help='Exact Claude settings.json or project .claude/settings.local.json')
    parser.add_argument('--bridge', type=Path, required=True, help='Stable installed attending-bridge executable')
    parser.add_argument('--approvals', action='store_true', help='Relay PermissionRequest to Attending for explicit allow-once or deny; timeout falls back to Claude')
    parser.add_argument('--previous-bridge', type=Path, action='append', default=[], help='Migrate only hooks matching this exact previous bridge path; repeat if needed')
    parser.add_argument('--status-line', action='store_true', help='Also add a status line that records Claude plan usage for Attending (skipped if you already have a status line)')
    parser.add_argument('--apply', action='store_true', help='Write merged settings atomically, keeping an exclusive backup')
    args = parser.parse_args()
    bridge = args.bridge.expanduser().resolve(strict=True)
    if not os.access(bridge, os.X_OK):
        parser.error('Bridge must be executable')
    target = args.settings.expanduser().absolute()
    if target.is_symlink():
        parser.error('Refusing to replace a symlink')
    raw = target.read_bytes() if target.exists() else None
    result = merge(json.loads(raw) if raw else {}, bridge, args.approvals, [p.expanduser().absolute() for p in args.previous_bridge])
    status_line_added = False
    if args.status_line:
        result, status_line_added = merge_status_line(result, bridge)
        if not status_line_added:
            print('Keeping your existing statusLine; Attending usage meter will not update.')
    encoded = (json.dumps(result, indent=2) + '\n').encode()
    if not args.apply:
        # Do not print unrelated settings, which may include credentials.
        mode = 'approval relay and lifecycle' if args.approvals else 'observational'
        print(f'Ready: add {mode} hooks for {len(EVENTS)} events to {target}. No permission settings are changed. Use --apply to write.')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if raw is not None:
        backup = target.with_name(target.name + '.attending-backup')
        if not backup.exists():
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as f:
                f.write(raw)
    # Stop if a concurrent writer changed the file during preparation.
    if (target.read_bytes() if target.exists() else None) != raw:
        raise RuntimeError('Settings changed concurrently; retry after inspecting the edit')
    fd, tmp = tempfile.mkstemp(prefix='.attending-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(encoded)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print(f'Installed observation hooks in {target}. Start a new Claude Code session to load them.')

if __name__ == '__main__':
    main()
