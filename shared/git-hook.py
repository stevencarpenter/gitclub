#!/usr/bin/env python3
"""Forward receive-pack hook data to the running GitClub implementation."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


def updates_from(lines: list[str]) -> list[dict[str, str]]:
    if len(lines) > 2048:
        raise ValueError('Push contains too many ref updates (maximum 2048).')
    updates = []
    for line in lines:
        parts = line.strip().split(' ')
        if len(parts) != 3:
            raise ValueError('Invalid Git ref update.')
        old, new, ref = parts
        if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', old) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', new):
            raise ValueError('Invalid Git object identifier.')
        if not ref.startswith('refs/') or len(ref) > 1024 or any(ord(c) < 32 for c in ref):
            raise ValueError('Invalid Git ref name.')
        updates.append({'old': old, 'new': new, 'ref': ref})
    return updates


def main() -> int:
    kind = sys.argv[1] if len(sys.argv) > 1 else Path(__file__).name
    if kind not in ('pre-receive', 'post-receive'):
        print('GitClub hook must be invoked as pre-receive or post-receive.', file=sys.stderr)
        return 1
    try:
        raw = sys.stdin.buffer.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError('Git update request is too large.')
        payload: dict[str, object] = {'updates': updates_from(raw.decode('utf-8').splitlines())}
        quarantine = os.environ.get('GIT_QUARANTINE_PATH')
        if quarantine:
            payload['quarantine_path'] = str(Path(quarantine).resolve())
        base, token, repo = (os.environ.get(k, '') for k in ('GITCLUB_URL', 'GITCLUB_TOKEN', 'GITCLUB_REPO_ID'))
        if not base.startswith(('http://', 'https://')) or not token or not repo.isdigit():
            raise ValueError('GitClub transport credentials are unavailable. Retry through the configured GitClub remote.')
        request = urllib.request.Request(
            f'{base.rstrip("/")}/api/repos/{repo}/git/{kind}',
            data=json.dumps(payload).encode(),
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
            method='POST',
        )
        # A hook must never follow a redirect carrying a repository access token.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=20) as response:
            response.read(65536)
        return 0
    except urllib.error.HTTPError as exc:
        try:
            reason = json.loads(exc.read(65536)).get('error', 'GitClub rejected the ref update.')
        except (ValueError, AttributeError):
            reason = 'GitClub rejected the ref update.'
        print(f'GitClub: {str(reason)[:1000]}', file=sys.stderr)
    except (ValueError, UnicodeError, OSError) as exc:
        message = str(exc) if isinstance(exc, ValueError) else 'Authorization service unavailable. Retry the push.'
        print(f'GitClub: {message}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
