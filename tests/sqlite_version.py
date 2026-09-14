#!/usr/bin/env python3
"""Prove the running server's SQLite version using a disposable database."""
import argparse
import json
from pathlib import Path
import secrets
import sqlite3

from acceptance import Client


def check(url: str, directory: Path, expected: str) -> dict:
    anonymous = Client(url)
    implementation = anonymous.get('/health')['implementation']
    username = 'sqlitecheck' + secrets.token_hex(6)
    account = anonymous.post('/api/auth/register', {
        'username': username, 'password': secrets.token_urlsafe(24),
    }, expect=201)
    client = Client(url, account['token'])
    # The trigger executes inside the server's connection, not Python's SQLite.
    with sqlite3.connect(f'file:{directory.resolve() / "gitclub.db"}?mode=rw', uri=True) as db:
        trigger = 'version_' + secrets.token_hex(6)
        db.execute(f'''CREATE TRIGGER {trigger} AFTER INSERT ON repositories
            WHEN NEW.owner = '{username}' BEGIN
            UPDATE repositories SET description = sqlite_version() WHERE id = NEW.id;
            END''')
        db.commit()
        try:
            repo = client.post('/api/repos', {'owner': username, 'name': 'sqliteprobe'}, expect=201)['repository']
            actual = db.execute('SELECT description FROM repositories WHERE id=?', (repo['id'],)).fetchone()[0]
            assert actual == expected, f'{implementation}: expected SQLite {expected}, got {actual}'
        finally:
            db.execute(f'DROP TRIGGER {trigger}')
            db.commit()
    return {'implementation': implementation, 'sqlite_version': actual, 'expected': expected, 'status': 'passed'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--expected', default='3.53.4')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = check(args.url, args.data_dir, args.expected)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
