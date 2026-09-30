#!/usr/bin/env python3
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
bridge = root / '.build/debug/attending-bridge'
with tempfile.TemporaryDirectory(prefix='attending-test-') as directory:
    env = dict(os.environ, ATTENDING_DATA_DIR=directory)
    def send(event, session='fixture', **extra):
        data = dict(session_id=session, cwd='/tmp/Attending Fixture', hook_event_name=event, **extra)
        return subprocess.run([str(bridge)], input=json.dumps(data), text=True, capture_output=True, env=env, check=True)
    assert send('SessionStart').stdout == ''
    assert send('Notification', notification_type='unrelated').stdout == ''
    send('PermissionRequest', tool_input={'command': 'DO_NOT_PERSIST_SECRET'})
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda i: send('UserPromptSubmit', session=f'session-{i}'), range(20)))
    events = list((Path(directory) / 'events').glob('*.json'))
    assert len(events) == 22, len(events)
    content = '\n'.join(p.read_text() for p in events)
    assert 'DO_NOT_PERSIST_SECRET' not in content
    assert len({json.loads(p.read_text())['id'] for p in events}) == 22
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in events)
    for invalid in ['broken json', '{}', 'x' * 1_048_578]:
        result = subprocess.run([str(bridge)], input=invalid, text=True, capture_output=True, env=env, check=True)
        assert result.stdout == ''
    assert len(list((Path(directory) / 'events').glob('*.json'))) == 22
    # Status line: keeps only rate-limit numbers, prints a short line, records no lifecycle event.
    status = dict(session_id='s', cwd='/tmp/x', model={'display_name': 'Opus'}, transcript_path='/SECRET/path',
                  rate_limits={'five_hour': {'used_percentage': 42.4, 'resets_at': 1790000000}, 'seven_day': {'used_percentage': 7}})
    out = subprocess.run([str(bridge), '--statusline'], input=json.dumps(status), text=True, capture_output=True, env=env, check=True).stdout
    assert out.strip() == 'Opus · 5h 42% · week 7%', out
    usage_file = Path(directory) / 'usage.json'
    usage = json.loads(usage_file.read_text())
    assert usage['fiveHour'] == {'used': 42.4, 'resetsAt': 1790000000} and usage['sevenDay'] == {'used': 7}
    assert 'SECRET' not in usage_file.read_text() and usage_file.stat().st_mode & 0o777 == 0o600
    assert len(list((Path(directory) / 'events').glob('*.json'))) == 22
    out = subprocess.run([str(bridge), '--statusline'], input=json.dumps({'model': {'display_name': 'Opus'}}), text=True, capture_output=True, env=env, check=True).stdout
    assert out.strip() == 'Opus'
spec = importlib.util.spec_from_file_location('installer', root / 'scripts/install-claude-hooks.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
original = {'permissions': {'deny': ['Bash(sudo *)']}, 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'other-hook'}]}]}}
merged = installer.merge(original, bridge)
assert original['hooks']['Stop'][0]['hooks'][0]['command'] == 'other-hook'
assert merged['permissions'] == original['permissions']
assert installer.merge(merged, bridge) == merged
old_bridge = Path('/Applications/Old Name.app/Contents/MacOS/attending-bridge')
old_settings = installer.merge(original, old_bridge, approvals=True)
migrated = installer.merge(old_settings, bridge, approvals=True, previous_bridges=[old_bridge])
assert migrated == installer.merge(original, bridge, approvals=True)
assert installer.merge(migrated, bridge, approvals=True, previous_bridges=[old_bridge]) == migrated
with_line, added = installer.merge_status_line(original, bridge)
assert added and with_line['statusLine']['command'].endswith('--statusline') and with_line['permissions'] == original['permissions']
assert installer.merge_status_line(with_line, bridge) == (with_line, True)
custom = dict(original, statusLine={'type': 'command', 'command': 'my-own-line'})
assert installer.merge_status_line(custom, bridge) == (custom, False)
print('PASS: status line usage capture and installer preservation')
print('PASS: bridge lifecycle, concurrent ingress, malformed/oversized input, privacy, permissions, installer preservation/idempotency')
