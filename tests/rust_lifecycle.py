#!/usr/bin/env python3
"""Exercise Rust HTTP and subprocess lifecycle against an isolated server."""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from acceptance import Suite, init_repo, git
parser = argparse.ArgumentParser(description='Verify HTTP header timeout and Git process cleanup during running/startup shutdown.')
parser.add_argument('--binary', type=Path, default=ROOT / '.build/gitclub-rust')
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
binary = args.binary.resolve()
report = {'status': 'failed', 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
root = Path(tempfile.mkdtemp(prefix='gitclub-rust-shutdown-proof-'))
wrapper = root / 'bin'
wrapper.mkdir()
marker = root / 'pids.json'
active = root / 'active'
realgit = shutil.which('git')
python = sys.executable
(wrapper / 'git').write_text('#!' + python + '\n' + f'import json,os,subprocess,sys,time\nfrom pathlib import Path\nif "log" in sys.argv and Path({str(active)!r}).exists():\n    child=subprocess.Popen([{python!r}, "-c", "import time; time.sleep(180)"])\n    Path({str(marker)!r}).write_text(json.dumps([os.getpid(),child.pid]))\n    time.sleep(180)\nos.execv({realgit!r},[{realgit!r}]+sys.argv[1:])\n')
(wrapper / 'git').chmod(0o700)
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
url = f'http://127.0.0.1:{port}'
env = os.environ | {'PORT': str(port), 'HOST': '127.0.0.1', 'PUBLIC_URL': url, 'DATA_DIR': str(root / 'data'), 'SHARED_DIR': str(ROOT / 'shared'), 'WEB_DIR': str(ROOT / 'web'), 'PATH': str(wrapper) + os.pathsep + os.environ['PATH']}
log = (root / 'server.log').open('wb')
server = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=log, stderr=log)
suite = Suite(url)
held = None
pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
pids = []

def live(pid):
    status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], text=True, capture_output=True).stdout.strip()
    return bool(status) and (not status.startswith('Z'))
try:
    deadline = time.monotonic() + 20
    while True:
        try:
            suite.anon.get('/health')
            break
        except Exception:
            assert server.poll() is None, (root / 'server.log').read_text()
            if time.monotonic() > deadline:
                raise
            time.sleep(0.05)
    with socket.create_connection(('127.0.0.1', port), timeout=5) as partial:
        partial.settimeout(8)
        started = time.monotonic()
        partial.sendall(b'GET /health HTTP/1.1\r\nHost: localhost\r\n')
        response = partial.recv(4096)
        elapsed = time.monotonic() - started
        assert 4 <= elapsed < 7 and (not response or b'408' in response), (elapsed, response)
        report['partial_header_seconds'] = elapsed
    suite.a, suite.ua = suite.register('shutdown')
    suite.r = suite.repo('shutdown')
    work = suite.root / 'work'
    init_repo(work)
    git(work, 'push', suite.remote(), 'trunk', token=suite.a.token)
    held = socket.create_connection(('127.0.0.1', port), timeout=5)
    held.settimeout(5)
    held.sendall(f"POST /{suite.r['full_name']}.git/git-receive-pack HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {suite.a.token}\r\nContent-Type: application/x-git-receive-pack-request\r\nContent-Length: 4096\r\n\r\n".encode())
    response = b''
    while b'\r\n\r\n' not in response:
        chunk = held.recv(1)
        assert chunk, 'Git HTTP response closed before its headers'
        response += chunk
        assert len(response) <= 16384, 'Git HTTP response headers exceed 16 KiB'
    assert b'200' in response.split(b'\r\n')[0], response
    active.touch()
    operation = pool.submit(suite.a.get, suite.path() + '/commits')
    deadline = time.monotonic() + 10
    while not marker.exists():
        assert time.monotonic() < deadline, 'ordinary Git did not start'
        time.sleep(0.01)
    pids = json.loads(marker.read_text())
    assert all((live(pid) for pid in pids))
    # Capture all inherited Git/hook processes before terminating the server.
    rows = [line.split(None, 3) for line in subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,command='], capture_output=True, text=True).stdout.splitlines()]
    descendants = {server.pid}
    while True:
        expanded = descendants | {int(row[0]) for row in rows if int(row[1]) in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    pids = sorted(descendants - {server.pid})
    report['descendant_count'] = len(pids)
    report['pre_shutdown_commands'] = [row[3] for row in rows if int(row[0]) in descendants and len(row) > 3]
    started = time.monotonic()
    server.send_signal(signal.SIGTERM)
    server.wait(timeout=35)
    report['shutdown_seconds'] = time.monotonic() - started
    report['exit_code'] = server.returncode
    deadline = time.monotonic() + 3
    while any((live(pid) for pid in pids)) and time.monotonic() < deadline:
        time.sleep(0.02)
    survivors = [pid for pid in pids if live(pid)]
    report['survivors'] = survivors
    assert not survivors, f'External child processes survived shutdown: {survivors}'
    assert server.returncode == 0, server.returncode
    held.close()
    held = None
    # Restart with stale HEAD and cancel while startup repair owns a Git process.
    script = wrapper / 'git'
    script.write_text(script.read_text().replace('"log" in sys.argv', '"symbolic-ref" in sys.argv'))
    marker.unlink()
    (root / 'data/repos/1.git/HEAD').write_text('ref: refs/heads/wrong\n')
    server = subprocess.Popen([str(binary)], cwd=ROOT, env=env, stdout=log, stderr=log)
    deadline = time.monotonic() + 10
    while not marker.exists():
        assert time.monotonic() < deadline and server.poll() is None, 'startup did not enter Git HEAD repair'
        time.sleep(0.01)
    pids = json.loads(marker.read_text())
    assert all((live(pid) for pid in pids))
    started = time.monotonic()
    server.send_signal(signal.SIGTERM)
    server.wait(timeout=35)
    report['startup_shutdown_seconds'] = time.monotonic() - started
    deadline = time.monotonic() + 3
    while any((live(pid) for pid in pids)) and time.monotonic() < deadline:
        time.sleep(0.02)
    report['startup_survivors'] = [pid for pid in pids if live(pid)]
    assert not report['startup_survivors'] and server.returncode == 0, (report['startup_survivors'], server.returncode)
    report['status'] = 'passed'
except Exception as error:
    report['error'] = str(error)
    raise
finally:
    if held:
        held.close()
    if server.poll() is None:
        server.kill()
        server.wait()
    for pid in pids:
        if live(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    pool.shutdown(wait=True, cancel_futures=True)
    suite.temp.cleanup()
    log.close()
    report['proof_directory'] = str(root)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
