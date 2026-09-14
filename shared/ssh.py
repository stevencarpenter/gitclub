#!/usr/bin/env python3
"""OpenSSH transport adapter. GitClub owns authentication and repository policy."""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def configuration() -> dict[str, str]:
    path = Path(os.environ.get('GITCLUB_SSH_CONFIG', '/etc/gitclub-ssh.json'))
    config = json.loads(path.read_text()) if path.is_file() else {}
    return {**config, **{key: os.environ[key] for key in ('GITCLUB_URL', 'GITCLUB_SSH_SECRET') if key in os.environ}}


def call(path: str, payload: dict | None = None, token: str | None = None) -> dict:
    config = configuration()
    base = config.get('GITCLUB_URL', '').rstrip('/')
    if not base.startswith(('http://', 'https://')):
        raise ValueError('GITCLUB_URL is not configured.')
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    else:
        secret = config.get('GITCLUB_SSH_SECRET', '')
        if not secret:
            raise ValueError('GITCLUB_SSH_SECRET is not configured.')
        headers['X-GitClub-SSH-Secret'] = secret
    request = urllib.request.Request(base + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers, method='GET' if payload is None else 'POST')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=15) as response:
        return json.load(response)


def authorized_keys() -> None:
    command_path = shlex.quote(str(Path(__file__).resolve()))
    python_path = shlex.quote(sys.executable)
    for key in call('/api/ssh/authorized-keys').get('keys', []):
        key_id, public = key.get('id'), key.get('public_key', '')
        if not isinstance(key_id, int) or key_id <= 0 or '\n' in public or '\r' in public:
            continue
        if not re.match(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]+(?: |$)', public):
            continue
        command = f'{python_path} {command_path} serve {key_id}'.replace('\\', '\\\\').replace('"', '\\"')
        print(f'restrict,command="{command}" {public}')


@contextlib.contextmanager
def transfer_slot(data: Path):
    directory = data / 'ssh-transfer-locks'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    held = None
    for index in range(8):
        candidate = (directory / str(index)).open('a+')
        try:
            fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = candidate
            break
        except BlockingIOError:
            candidate.close()
    if held is None:
        raise ValueError('All 8 SSH transfer slots are in use. Retry shortly.')
    try:
        yield
    finally:
        held.close()


def serve(key_id: int) -> int:
    authorization = call('/api/ssh/authorize', {'key_id': key_id, 'command': os.environ.get('SSH_ORIGINAL_COMMAND', '')})
    token = authorization['token']
    child: subprocess.Popen | None = None
    slot = None
    try:
        operation = authorization['operation']
        if operation not in ('git-upload-pack', 'git-receive-pack'):
            raise ValueError('Git operation is not supported.')
        repository = authorization['repository_path']
        if not os.path.isabs(repository) or not repository.endswith('.git'):
            raise ValueError('Repository path is invalid.')
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LANG': 'C.UTF-8',
               'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_NO_REPLACE_OBJECTS': '1',
               'GITCLUB_URL': configuration()['GITCLUB_URL'],
               'GITCLUB_TOKEN': token, 'GITCLUB_REPO_ID': str(authorization['repo_id'])}
        if os.environ.get('GIT_PROTOCOL') == 'version=2':
            env['GIT_PROTOCOL'] = 'version=2'
        slot = transfer_slot(Path(repository).parent.parent)
        slot.__enter__()
        child = subprocess.Popen(['git', operation.removeprefix('git-'), repository], env=env, start_new_session=True)
        def cancel(signum, frame):
            if child and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGHUP, cancel)
        signal.signal(signal.SIGINT, cancel)
        try:
            return child.wait(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            print('GitClub: transfer exceeded 120 seconds.', file=sys.stderr)
            return 1
    finally:
        if child and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        if slot is not None:
            slot.__exit__(None, None, None)
        try:
            call('/api/auth/logout', {}, token=token)
        except (OSError, ValueError):
            pass  # The server also expires SSH tokens after a bounded lifetime.


def main() -> int:
    try:
        if len(sys.argv) == 2 and sys.argv[1] == 'authorized-keys':
            authorized_keys()
            return 0
        if len(sys.argv) == 3 and sys.argv[1] == 'serve' and sys.argv[2].isdigit():
            return serve(int(sys.argv[2]))
        raise ValueError('GitClub SSH only supports authenticated Git operations.')
    except urllib.error.HTTPError as exc:
        try:
            message = json.loads(exc.read(65536)).get('error', 'Git authorization failed.')
        except ValueError:
            message = 'Git authorization failed.'
        print(f'GitClub: {str(message)[:500]}', file=sys.stderr)
    except (OSError, ValueError, KeyError):
        print('GitClub: SSH service unavailable or command rejected.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
