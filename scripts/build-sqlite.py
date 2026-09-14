#!/usr/bin/env python3
"""Build checksum-pinned SQLite as a project-local PIC static library."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

VERSION = '3.53.4'
URL = 'https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip'
# Published at https://www.sqlite.org/download.html and /changes.html.
ARCHIVE_SHA3 = '628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e'
SOURCE_SHA3 = '67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16'
DEFINES = [
    'SQLITE_DQS=0', 'SQLITE_THREADSAFE=1', 'SQLITE_USE_URI',
    'SQLITE_ENABLE_COLUMN_METADATA', 'SQLITE_ENABLE_FTS3', 'SQLITE_ENABLE_FTS3_PARENTHESIS',
    'SQLITE_ENABLE_FTS4', 'SQLITE_ENABLE_FTS5', 'SQLITE_ENABLE_MATH_FUNCTIONS',
    'SQLITE_ENABLE_RTREE', 'SQLITE_ENABLE_GEOPOLY',
]
ARTIFACTS = ('include/sqlite3.h', 'include/sqlite3ext.h', 'lib/libsqlite3.a', 'check')


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(prefix: Path) -> None:
    prefix = prefix.resolve()
    prefix.mkdir(parents=True, exist_ok=True)
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    identity = {
        'version': VERSION, 'system': platform.system(), 'machine': platform.machine(),
        'compiler': compiler,
        'compiler_version': subprocess.check_output([*compiler, '--version'], text=True),
        'recipe_sha256': digest(Path(__file__)),
    }
    with (prefix / '.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            cached = json.loads((prefix / 'build.json').read_text())
            valid = cached['identity'] == identity and all(
                digest(prefix / name) == cached['sha256'][name] for name in ARTIFACTS)
        except (OSError, ValueError, KeyError):
            valid = False
        if not valid:
            with tempfile.TemporaryDirectory(dir=prefix, prefix='staging-') as temporary:
                stage = Path(temporary)
                with urllib.request.urlopen(URL, timeout=60) as response:
                    archive = response.read(8 * 1024 * 1024 + 1)
                if hashlib.sha3_256(archive).hexdigest() != ARCHIVE_SHA3:
                    raise RuntimeError('SQLite archive SHA3-256 mismatch')
                with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                    for name in ('sqlite3.c', 'sqlite3.h', 'sqlite3ext.h'):
                        (stage / name).write_bytes(bundle.read('sqlite-amalgamation-3530400/' + name))
                if hashlib.sha3_256((stage / 'sqlite3.c').read_bytes()).hexdigest() != SOURCE_SHA3:
                    raise RuntimeError('SQLite source SHA3-256 mismatch')
                subprocess.run([*compiler, '-O2', '-fPIC', '-pthread', *['-D' + d for d in DEFINES],
                                '-c', 'sqlite3.c', '-o', 'sqlite3.o'], cwd=stage, check=True)
                (stage / 'lib').mkdir()
                (stage / 'include').mkdir()
                subprocess.run([*shlex.split(os.environ.get('AR', 'ar')), 'rcs',
                                'lib/libsqlite3.a', 'sqlite3.o'], cwd=stage, check=True)
                for name in ('sqlite3.h', 'sqlite3ext.h'):
                    shutil.copy2(stage / name, stage / 'include' / name)
                # A linked executable checks the actual library and header together.
                (stage / 'check.c').write_text(
                    '#include "sqlite3.h"\n#include <string.h>\n'
                    'int main(void) { sqlite3 *db = 0; '
                    'if (strcmp(SQLITE_VERSION, "' + VERSION + '") || '
                    'strcmp(sqlite3_libversion(), "' + VERSION + '") || '
                    'sqlite3_open(":memory:", &db) != SQLITE_OK) return 1; '
                    'return sqlite3_close(db) != SQLITE_OK; }\n')
                subprocess.run([*compiler, 'check.c', 'lib/libsqlite3.a', '-pthread', '-lm',
                                *(['-ldl'] if platform.system() == 'Linux' else []),
                                '-o', 'check'], cwd=stage, check=True)
                subprocess.run([str(stage / 'check')], check=True)
                for name in ARTIFACTS:
                    target = prefix / name
                    target.parent.mkdir(exist_ok=True)
                    (stage / name).replace(target)
                record = {'identity': identity, 'source': URL, 'source_sha3_256': SOURCE_SHA3,
                          'sha256': {name: digest(prefix / name) for name in ARTIFACTS}}
                (stage / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
                (stage / 'build.json').replace(prefix / 'build.json')
        subprocess.run([str(prefix / 'check')], check=True)
    print(f'SQLite {VERSION}: {prefix}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    build(parser.parse_args().output)
