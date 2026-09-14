#!/usr/bin/env python3
"""Check Git HTTP streaming, admission, cancellation, and the upload size bound."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import socket
import time
import traceback
from urllib.parse import urlsplit

from acceptance import Suite, git, init_repo


def response_headers(connection):
    response = b''
    while b'\r\n\r\n' not in response:
        chunk = connection.recv(1)
        if not chunk:
            break
        response += chunk
        assert len(response) <= 16384, 'Git CGI response headers exceeded 16 KiB'
    return response


def run(url):
    parsed = urlsplit(url)
    assert parsed.scheme == 'http', 'Use the direct local HTTP listener'
    suite = Suite(url)
    held = []
    report = {'url': url, 'status': 'failed', 'started_at_unix': time.time()}
    try:
        health = suite.anon.get('/health')
        report['implementation'] = health['implementation']
        suite.a, suite.ua = suite.register('streams')
        suite.r = suite.repo('stream-bounds')
        work = suite.root / 'work'
        init_repo(work)
        payload = random.Random(4729).randbytes(8 * 1024 * 1024)
        (work / 'payload.bin').write_bytes(payload)
        git(work, 'add', '.')
        git(work, 'commit', '-m', 'Streaming payload')
        started = time.monotonic()
        git(work, '-c', 'http.postBuffer=1024', 'push', suite.remote(), 'trunk', token=suite.a.token)
        report['chunked_push_seconds'] = time.monotonic() - started
        git(suite.root, 'clone', suite.remote(), str(suite.root / 'clone'), token=suite.a.token)
        assert (suite.root / 'clone/payload.bin').read_bytes() == payload
        report.update(payload_bytes=len(payload), payload_sha256=hashlib.sha256(payload).hexdigest())
        print('PASS: 8 MiB chunked push and clone byte identity', flush=True)

        def open_upload(length):
            connection = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=5)
            connection.settimeout(8)
            path = '/' + suite.r['full_name'] + '.git/git-receive-pack'
            headers = (f'POST {path} HTTP/1.1\r\nHost: {parsed.netloc}\r\n'
                       f'Authorization: Bearer {suite.a.token}\r\nContent-Length: {length}\r\n'
                       'Content-Type: application/x-git-receive-pack-request\r\nConnection: close\r\n\r\n')
            connection.sendall(headers.encode())
            return connection

        with open_upload(256 * 1024 * 1024 + 1) as oversized:
            header = response_headers(oversized)
            assert header.split(b'\r\n', 1)[0].split()[1] == b'413', header
        report['declared_oversize_rejected'] = True
        for _ in range(8):
            connection = open_upload(4096)
            held.append(connection)
            # receive-pack advertises its CGI headers before reading the pack.
            header = response_headers(connection)
            assert header.split(b'\r\n', 1)[0].split()[1] == b'200', header
        with open_upload(4096) as denied:
            header = response_headers(denied)
            assert header.split(b'\r\n', 1)[0].split()[1] == b'503', header
        started = time.monotonic()
        assert suite.a.get(suite.path())['repository']['id'] == suite.r['id']
        report['metadata_at_capacity_ms'] = (time.monotonic() - started) * 1000
        suite.a.post(suite.path() + '/git/pre-receive', {'updates': [{'old': '0' * 40, 'new': git(work, 'rev-parse', 'HEAD'), 'ref': 'refs/heads/hook-capacity'}]})
        report['hook_control_at_capacity'] = True
        report['transfer_capacity'] = 8
        print('PASS: eight transfers, ninth rejected, metadata and hook control available', flush=True)
        for connection in held:
            connection.shutdown(socket.SHUT_RDWR)
            connection.close()
        held.clear()
        deadline = time.monotonic() + 10
        while True:
            try:
                git(work, 'ls-remote', suite.remote(), token=suite.a.token)
                break
            except AssertionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        report['disconnect_releases_capacity'] = True
        report['status'] = 'passed'
        print('PASS: disconnect releases Git HTTP transfer capacity', flush=True)
    except Exception as error:
        report.update(error=str(error), traceback=traceback.format_exc())
    finally:
        for connection in held:
            connection.close()
        suite.temp.cleanup()
    report['elapsed_seconds'] = time.time() - report['started_at_unix']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    report = run(args.url)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    if report['status'] != 'passed':
        print('FAIL: ' + report['error'])
    return report['status'] != 'passed'


if __name__ == '__main__':
    raise SystemExit(main())
