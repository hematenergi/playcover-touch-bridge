"""Read-only transport and authentication checks; no gameplay input."""
import io
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from host import read_exact, validate_settings, DEFAULT_SETTINGS

assert read_exact(io.BytesIO(b'abcd'), 4) == b'abcd'
try:
    read_exact(io.BytesIO(b'ab'), 3)
except EOFError:
    pass
else:
    raise AssertionError('A truncated capture frame must fail')

for change in ({'fps': True}, {'fps': 0}, {'fps': 120}, {'width': 1}, {'quality': 100}, {'showTouches': 1}, {'unexpected': 1}):
    try:
        validate_settings({**DEFAULT_SETTINGS, **change})
    except ValueError:
        pass
    else:
        raise AssertionError(f'Invalid stream settings accepted: {change}')

token = json.loads((Path(__file__).parent / 'build/session.json').read_text())['token']
base = 'http://127.0.0.1:19470'


def request(path, headers=None, body=None):
    try:
        with urlopen(Request(base + path, headers=headers or {}, data=body), timeout=4) as reply:
            return reply.status, json.load(reply)
    except HTTPError as error:
        return error.code, json.load(error)


code, status = request('/health', {'X-PlayTouch-Token': token})
assert code == 200 and status['windowReady'] and status['videoFrames'] > 0, status
assert request('/health')[0] == 403
assert request('/input', body=b'{"op":"status"}')[0] == 403
assert request('/input', {'X-PlayTouch-Token': token, 'Origin': 'https://example.invalid'}, b'{"op":"status"}')[0] == 403
assert request('/', {'Host': 'example.invalid'})[0] == 403
assert request('/settings')[0] == 403
assert request('/settings', body=b'{}')[0] == 403
assert request('/frame')[0] == 403
code, config = request('/settings', {'X-PlayTouch-Token': token})
assert code == 200 and config['settings'] == config['applied'], config
code, invalid = request('/settings', {'X-PlayTouch-Token': token}, json.dumps({**config['settings'], 'fps': 999}).encode())
assert code == 400 and 'error' in invalid
assert request('/settings', {'X-PlayTouch-Token': token})[1] == config, 'Invalid request changed stream settings'
# A browser may retain its frame cursor when only the host is restarted.
with urlopen(Request(base + '/frame?after=' + str(status['videoFrames'] + 1000000), headers={'X-PlayTouch-Token': token}), timeout=2) as reply:
    assert reply.headers['Content-Type'] == 'image/jpeg'
    assert reply.read(2) == b'\xff\xd8'
print('PASS: live video, native receiver, authentication/origin/host checks, settings validation, and truncated-frame handling.')
