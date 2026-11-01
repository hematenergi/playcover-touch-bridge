#!/usr/bin/env python3
"""USB-only HSR video and independent native touch contacts. No dependencies."""
import hmac
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
RUNTIME = Path.home() / 'Library/Containers/io.playcover.PlayCover/TouchBridge'
APP = Path.home() / 'Library/Containers/io.playcover.PlayCover/Applications/com.HoYoverse.hkrpgoversea.app/hkrpg'
PORT = 19470
NATIVE_PORT = 19471
TOKEN = ''
native_lock = threading.Lock()
frames = threading.Condition()
latest_frame = b''
frame_number = 0
capture_error = ''
children = []
DEFAULT_SETTINGS = {'fps': 60, 'width': 960, 'quality': 45, 'showTouches': True}
stream_settings = DEFAULT_SETTINGS.copy()
applied_settings = {}
settings_lock = threading.Lock()
capture_command_lock = threading.Lock()
capture_process = None
frame_times = deque(maxlen=120)


def validate_settings(value):
    if not isinstance(value, dict) or set(value) != set(DEFAULT_SETTINGS):
        raise ValueError('Incomplete stream settings')
    if any(type(value[key]) is not int for key in ('fps', 'width', 'quality')) or type(value['showTouches']) is not bool:
        raise ValueError('Invalid setting types')
    if value['fps'] not in (30, 45, 60) or value['width'] not in (640, 960, 1280, 1600) or not 20 <= value['quality'] <= 90:
        raise ValueError('FPS, resolution, or quality outside the available choices')
    return value.copy()


def send_capture(message):
    with capture_command_lock:
        if capture_process is None or capture_process.poll() is not None:
            raise OSError('Capture is not ready yet')
        capture_process.stdin.write((json.dumps(message) + '\n').encode())
        capture_process.stdin.flush()


def show_contacts(status):
    if not status.get('width') or not status.get('height'):
        return
    points = []
    for contact in status.get('active', []):
        x, y = map(float, contact['point'].strip('{}').split(','))
        points.append({'id': contact['id'], 'x': x / status['width'], 'y': y / status['height']})
    try:
        send_capture({'type': 'touches', 'points': points})
    except OSError:
        pass


def apply_settings(value):
    global stream_settings
    wanted = validate_settings(value)
    with settings_lock:
        send_capture({'type': 'settings', 'settings': wanted})
        with frames:
            if not frames.wait_for(lambda: applied_settings == wanted or bool(capture_error), timeout=6) or applied_settings != wanted:
                raise ValueError('Settings have not been applied yet. Try again after the picture appears.')
            stream_settings = wanted
        temporary = BUILD / 'stream-settings.tmp'
        temporary.write_text(json.dumps(wanted))
        temporary.replace(BUILD / 'stream-settings.json')
    return wanted


def native(req):
    with native_lock, socket.create_connection(('127.0.0.1', NATIVE_PORT), timeout=2) as conn:
        conn.sendall((json.dumps({**req, 'token': TOKEN}) + '\n').encode())
        data = bytearray()
        while block := conn.recv(16384):
            data.extend(block)
            if len(data) > 65536:
                raise ValueError('Native reply too large')
        result = json.loads(data)
    show_contacts(result)
    return result


def build():
    BUILD.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    dylib = BUILD / 'TouchBridge.dylib'
    if not dylib.exists() or dylib.stat().st_mtime < (ROOT / 'TouchBridge.m').stat().st_mtime:
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios15.0-macabi', '-isysroot', sdk,
                        '-iframework', sdk + '/System/iOSSupport/System/Library/Frameworks', '-framework', 'UIKit', '-framework', 'Foundation',
                        str(ROOT / 'TouchBridge.m'), '-o', str(dylib)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(dylib)], check=True)
    capture = BUILD / 'capture'
    if not capture.exists() or capture.stat().st_mtime < (ROOT / 'Capture.swift').stat().st_mtime:
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macos14.0', str(ROOT / 'Capture.swift'), '-o', str(capture)], check=True)
    RUNTIME.mkdir(exist_ok=True)
    shutil.copy2(dylib, RUNTIME / dylib.name)


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        block = stream.read(count - len(result))
        if not block:
            raise EOFError('Capture ended')
        result.extend(block)
    return bytes(result)


def capture_video(status):
    global latest_frame, frame_number, capture_error, capture_process, applied_settings
    log = open(BUILD / 'capture.log', 'ab')
    process = subprocess.Popen([str(BUILD / 'capture'), str(status['pid']), str(status['width']), str(status['height']), json.dumps(stream_settings)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    capture_process = process
    children.append(process)
    show_contacts(status)
    try:
        while True:
            size, = struct.unpack('!I', read_exact(process.stdout, 4))
            if not 0 < size <= 10_000_000:
                raise ValueError('Invalid capture frame size')
            frame = read_exact(process.stdout, size)
            if frame.startswith(b'{'):
                message = json.loads(frame)
                if message.get('type') == 'settings':
                    with frames:
                        applied_settings = validate_settings(message['settings'])
                        frames.notify_all()
                continue
            with frames:
                latest_frame = frame
                frame_number += 1
                frame_times.append(time.monotonic())
                frames.notify_all()
    except (EOFError, ValueError) as error:
        capture_error = str(error)
        print('The picture stopped. Check the Screen Recording permission and build/capture.log.', flush=True)
    finally:
        process.terminate()
        log.close()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Tokens and game frames must not end up in access logs.

    def reply(self, code, body, content_type='application/json'):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def allowed_host(self):
        return self.headers.get('Host') == f'127.0.0.1:{PORT}'

    def valid_token(self, value):
        return bool(TOKEN and value and hmac.compare_digest(value, TOKEN))

    def do_GET(self):
        url = urlsplit(self.path)
        if not self.allowed_host():
            return self.reply(403, {'error': 'Invalid host'})
        if url.path == '/':
            return self.reply(200, (ROOT / 'index.html').read_bytes(), 'text/html; charset=utf-8')
        authenticated = self.valid_token(self.headers.get('X-PlayTouch-Token'))
        if url.path == '/settings' and authenticated:
            return self.reply(200, {'settings': stream_settings, 'applied': applied_settings})
        if url.path == '/frame' and authenticated:
            try:
                after = int(parse_qs(url.query).get('after', ['-1'])[0])
            except ValueError:
                return self.reply(400, {'error': 'Invalid frame number'})
            with frames:
                # A restarted host resets its counter; an old browser cursor must also resume.
                fresh = frames.wait_for(lambda: frame_number != after and bool(latest_frame), timeout=5)
                data, number = latest_frame, frame_number
            if not fresh:
                return self.reply(204, b'')
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('X-Frame-Number', str(number))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)
            return
        if url.path == '/health' and authenticated:
            try:
                now = time.monotonic()
                with frames:
                    recent = [t for t in frame_times if now - t < 2]
                capture_fps = round((len(recent) - 1) / (recent[-1] - recent[0]), 1) if len(recent) > 1 else 0
                return self.reply(200, {**native({'op': 'status'}), 'videoFrames': frame_number, 'captureError': capture_error, 'settings': stream_settings, 'captureFPS': capture_fps})
            except (OSError, ValueError) as error:
                return self.reply(503, {'error': str(error)})
        if url.path != '/video' or not self.valid_token(parse_qs(url.query).get('token', [''])[0]):
            return self.reply(403, {'error': 'Unauthorized'})
        self.send_response(200)
        self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        previous = -1
        try:
            while True:
                with frames:
                    frames.wait_for(lambda: frame_number != previous and bool(latest_frame), timeout=5)
                    if not latest_frame:
                        continue
                    data, previous = latest_frame, frame_number
                self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ' + str(len(data)).encode() + b'\r\n\r\n' + data + b'\r\n')
                self.wfile.flush()
        except (OSError, ConnectionError):
            pass
        self.close_connection = True

    def do_POST(self):
        if self.path not in ('/input', '/settings') or not self.allowed_host() or not self.valid_token(self.headers.get('X-PlayTouch-Token')):
            self.close_connection = True
            return self.reply(403, {'error': 'Unauthorized'})
        if self.headers.get('Origin') not in (None, f'http://127.0.0.1:{PORT}'):
            self.close_connection = True
            return self.reply(403, {'error': 'Invalid origin'})
        try:
            count = int(self.headers.get('Content-Length', '0'))
            if not 0 < count <= 16000:
                raise ValueError('Invalid request size')
            req = json.loads(self.rfile.read(count))
            if self.path == '/settings':
                return self.reply(200, {'settings': apply_settings(req)})
            if not isinstance(req, dict) or req.get('op') not in ('touch', 'reset', 'status', 'keepalive'):
                raise ValueError('Invalid operation')
            result = native(req)
            return self.reply(400 if 'error' in result else 200, result)
        except (ValueError, OSError) as error:
            self.close_connection = True
            return self.reply(400, {'error': str(error)})


def main():
    global TOKEN, stream_settings
    build()
    try:
        stream_settings = validate_settings(json.loads((BUILD / 'stream-settings.json').read_text()))
    except (OSError, ValueError):
        stream_settings = DEFAULT_SETTINGS.copy()
    session = BUILD / 'session.json'
    if session.exists():
        TOKEN = json.loads(session.read_text())['token']
    else:
        TOKEN = secrets.token_hex(32)
    try:
        status = native({'op': 'status'})
    except OSError:
        running = subprocess.run(['pgrep', '-x', 'hkrpg'], capture_output=True, text=True)
        if running.returncode == 0:
            raise SystemExit('Quit HSR first, then run Start.command again. The game has to be started with the temporary touch module.')
        TOKEN = secrets.token_hex(32)
        session.write_text(json.dumps({'token': TOKEN}))
        session.chmod(0o600)
        env = {**os.environ, 'DYLD_INSERT_LIBRARIES': str(RUNTIME / 'TouchBridge.dylib'), 'PLAYTOUCH_TOKEN': TOKEN}
        game_log = open(BUILD / 'game.log', 'ab')
        subprocess.Popen([str(APP)], env=env, stdout=game_log, stderr=game_log, start_new_session=True)
        for _ in range(120):
            try:
                status = native({'op': 'status'})
                if status.get('windowReady'):
                    break
            except OSError:
                pass
            time.sleep(.5)
        else:
            raise SystemExit('The HSR window is not ready yet; see build/game.log.')
    if 'error' in status:
        raise SystemExit(status['error'])
    class Server(http.server.ThreadingHTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connection.settimeout(15)
            return connection, address
    server = Server(('127.0.0.1', PORT), Handler)
    server.daemon_threads = True
    devices = subprocess.check_output(['adb', 'devices'], text=True).splitlines()[1:]
    ready = [line.split()[0] for line in devices if line.endswith('\tdevice')]
    if len(ready) != 1:
        raise SystemExit('Connect exactly one Android phone over USB and allow USB debugging.')
    serial = ready[0]
    subprocess.run(['adb', '-s', serial, 'reverse', f'tcp:{PORT}', f'tcp:{PORT}'], check=True, stdout=subprocess.DEVNULL)
    threading.Thread(target=capture_video, args=(status,), daemon=True).start()
    subprocess.run(['adb', '-s', serial, 'shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', f'http://127.0.0.1:{PORT}/#{TOKEN}', '-p', 'com.android.chrome'], check=True, stdout=subprocess.DEVNULL)
    print('HSR Touch is active over USB. On Android: tap Fullscreen, rotate to landscape, then touch the game picture. Ctrl+C to stop.', flush=True)
    def stop(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('Releasing all touches and stopping the bridge.', flush=True)
    finally:
        try:
            native({'op': 'reset'})
        except OSError:
            pass
        server.server_close()
        for process in children:
            process.terminate()
        subprocess.run(['adb', '-s', serial, 'reverse', '--remove', f'tcp:{PORT}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
