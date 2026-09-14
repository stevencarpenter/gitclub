#!/usr/bin/env python3
"""Exercise an isolated GitClub installation through real OpenSSH and native Git."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import select
import shlex
import subprocess
import time

from acceptance import Suite, git, init_repo


class SSHSuite(Suite):
    def __init__(self, url: str, host: str, port: int):
        super().__init__(url)
        self.host, self.port = host, port
        self.processes: list[subprocess.Popen] = []

    def setup(self):
        health = self.anon.get('/health')
        assert health['status'] == 'ok'
        self.implementation = health['implementation']
        self.a, self.ua = self.register('ssh')
        self.r = self.repo('ssh-project')
        self.key = self.root / 'identity'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True, capture_output=True)
        public = self.key.with_suffix('.pub').read_text().strip()
        self.key_id = self.a.post('/api/ssh-keys', {'title': 'SSH acceptance', 'public_key': public}, expect=201)['ssh_key']['id']
        self.ssh_args = ['ssh', '-i', str(self.key), '-p', str(self.port), '-o', 'BatchMode=yes',
                         '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=no',
                         '-o', 'UserKnownHostsFile=' + os.devnull, '-o', 'ConnectTimeout=5',
                         '-o', 'LogLevel=ERROR']
        self.remote_path = self.r['owner'] + '/' + self.r['name'] + '.git'
        self.ssh_remote = 'git@' + self.host + ':' + self.remote_path
        self.work = self.root / 'work'
        init_repo(self.work)
        self.binary = bytes(range(256)) * 1024
        (self.work / 'payload.bin').write_bytes(self.binary)
        git(self.work, 'add', 'payload.bin')
        git(self.work, 'commit', '-m', 'Binary transport fixture')
        self.initial_oid = git(self.work, 'rev-parse', 'HEAD')
        self.ssh_git(self.work, 'push', self.ssh_remote, '--all')
        self.ssh_git(self.work, 'push', self.ssh_remote, '--tags')

    def ssh_git(self, directory, *args, ok=True):
        return git(directory, '-c', 'core.sshCommand=' + shlex.join(self.ssh_args), *args, ok=ok)

    def clone_and_push(self):
        clone = self.root / 'clone'
        self.ssh_git(self.root, 'clone', self.ssh_remote, str(clone))
        assert (clone / 'payload.bin').read_bytes() == self.binary, 'SSH clone corrupted binary data'
        assert git(clone, 'rev-parse', 'HEAD') == self.initial_oid
        assert 'v1' in git(clone, 'tag').splitlines()
        git(self.work, 'checkout', '-b', 'ssh-feature')
        (self.work / 'feature.txt').write_text('SSH feature branch\n')
        git(self.work, 'add', 'feature.txt')
        git(self.work, 'commit', '-m', 'Feature over SSH')
        self.ssh_git(self.work, 'push', self.ssh_remote, 'ssh-feature')
        branches = self.a.get(self.path() + '/branches')['branches']
        assert any(branch['name'] == 'ssh-feature' for branch in branches)

    def protected_default(self):
        self.ssh_git(self.work, 'push', self.ssh_remote, 'ssh-feature:trunk', ok=False)
        refs = self.ssh_git(self.work, 'ls-remote', self.ssh_remote, 'refs/heads/trunk')
        assert refs.split()[0] == self.initial_oid, 'Rejected SSH push changed protected default branch'

    def reject_shell(self):
        result = subprocess.run(self.ssh_args + ['git@' + self.host, 'id'], capture_output=True, timeout=15)
        assert result.returncode != 0, 'SSH permitted arbitrary shell execution'
        assert b'uid=' not in result.stdout, 'SSH executed id despite rejection'
        result = subprocess.run(self.ssh_args + ['git@' + self.host, "git-upload-pack '../outside.git'"], capture_output=True, timeout=15)
        assert result.returncode != 0, 'SSH permitted path traversal'

    def capacity_and_disconnect(self):
        command = "git-upload-pack '" + self.remote_path + "'"
        probe = subprocess.run(self.ssh_args + ['git@' + self.host, command], input=b'0000', capture_output=True, timeout=15)
        assert probe.returncode == 0, 'Control Git protocol exchange failed before capacity test'
        try:
            for index in range(8):
                process = subprocess.Popen(self.ssh_args + ['git@' + self.host, command], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.processes.append(process)
                ready, _, _ = select.select([process.stdout], [], [], 15)
                assert ready, f'SSH transfer {index + 1} did not advertise refs'
                data = os.read(process.stdout.fileno(), 4096)
                assert data and process.poll() is None, f'SSH transfer {index + 1} exited before capacity filled'
            denied = subprocess.run(self.ssh_args + ['git@' + self.host, command], input=b'0000', capture_output=True, timeout=15)
            assert denied.returncode != 0, 'Ninth SSH transfer was accepted while eight transfers stalled'
            assert all(process.poll() is None for process in self.processes), 'Existing transfers were interrupted at capacity'
        finally:
            self.close_processes()
        deadline = time.monotonic() + 15
        while True:
            try:
                refs = self.ssh_git(self.work, 'ls-remote', self.ssh_remote, 'refs/heads/trunk')
                assert self.initial_oid in refs
                break
            except AssertionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)

    def revoke_key(self):
        self.a.request('DELETE', '/api/ssh-keys/' + str(self.key_id))
        self.ssh_git(self.work, 'ls-remote', self.ssh_remote, ok=False)

    def close_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
        for process in self.processes:
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        self.processes.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--ssh-host', default='127.0.0.1')
    parser.add_argument('--ssh-port', type=int, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    suite = SSHSuite(args.url, args.ssh_host, args.ssh_port)
    started = time.time()
    try:
        ready = suite.run_case('OpenSSH key registration and native Git import', suite.setup)
        if ready:
            suite.run_case('SSH clone binary identity, tags and feature push', suite.clone_and_push)
            suite.run_case('SSH protected default branch rejects direct push', suite.protected_default)
            suite.run_case('SSH arbitrary shell and traversal rejection', suite.reject_shell)
            suite.run_case('SSH eight-transfer bound and disconnect releases slots', suite.capacity_and_disconnect)
            suite.run_case('SSH revoked key denies subsequent authentication', suite.revoke_key)
    finally:
        suite.close_processes()
        report = {'implementation': getattr(suite, 'implementation', 'unknown'), 'url': args.url,
                  'ssh_host': args.ssh_host, 'ssh_port': args.ssh_port, 'started_at_unix': started,
                  'elapsed_seconds': round(time.time() - started, 6), 'environment': {'platform': platform.platform(),
                  'ssh': subprocess.run(['ssh', '-V'], capture_output=True, text=True).stderr.strip()},
                  'results': suite.results, 'passed': sum(r['status'] == 'passed' for r in suite.results),
                  'failed': sum(r['status'] == 'failed' for r in suite.results)}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        suite.temp.cleanup()
    return bool(report['failed'])


if __name__ == '__main__':
    raise SystemExit(main())
