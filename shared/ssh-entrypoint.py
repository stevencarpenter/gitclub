#!/usr/bin/env python3
"""Initialize persistent SSH host keys and start OpenSSH in its transport container."""
import json
import os
import pwd
import subprocess
from pathlib import Path

account = pwd.getpwnam('git')
config = {key: os.environ[key] for key in ('GITCLUB_URL', 'GITCLUB_SSH_SECRET')}
if len(config['GITCLUB_SSH_SECRET']) < 32:
    raise SystemExit('GITCLUB_SSH_SECRET must contain at least 32 characters.')
config_path = Path('/etc/gitclub-ssh.json')
config_path.write_text(json.dumps(config))
config_path.chmod(0o640)
os.chown(config_path, 0, account.pw_gid)
keys = Path('/data/ssh')
keys.mkdir(parents=True, exist_ok=True, mode=0o700)
for kind in ('ed25519', 'rsa'):
    key = keys / f'ssh_host_{kind}_key'
    if not key.exists():
        subprocess.run(['ssh-keygen', '-q', '-t', kind, '-N', '', '-f', str(key)], check=True)
Path('/run/sshd').mkdir(exist_ok=True)
# sshd deliberately reconstructs child environments. The protected JSON file
# supplies the API endpoint and secret to AuthorizedKeysCommand and forced Git commands.
os.execv('/usr/sbin/sshd', ['/usr/sbin/sshd', '-D', '-e', '-f', '/app/shared/sshd_config'])
