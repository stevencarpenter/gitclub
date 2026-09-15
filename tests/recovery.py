#!/usr/bin/env python3
"""Verify an offline backup/restore preserves database rows, Git objects and refs.

Stop the server before running. This invokes the supported scripts/gitclub CLI
and restores into a new directory. It never overwrites an existing data dir.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]


def psql(url, sql):
    process = subprocess.run(["psql", url, "-tAc", sql], capture_output=True, text=True, timeout=120)
    assert process.returncode == 0, process.stderr
    return process.stdout


def fingerprint(directory, url):
    tables = sorted(line for line in psql(
        url, "SELECT table_name FROM information_schema.tables "
             "WHERE table_schema='public' AND table_type='BASE TABLE'").split() if line)
    counts, digests = {}, {}
    for table in tables:
        quoted = '"' + table.replace('"', '""') + '"'
        counts[table] = int(psql(url, f"SELECT count(*) FROM {quoted}").strip())
        # Sorting the copied rows makes the digest independent of physical
        # row order, which a dump and restore does not preserve.
        rows = sorted(psql(url, f"COPY (SELECT * FROM {quoted}) TO STDOUT").splitlines())
        digests[table] = hashlib.sha256("\n".join(rows).encode()).hexdigest()
    repositories = {}
    for repository in sorted((directory / "repos").glob("*.git")):
        def git(*args):
            process = subprocess.run(["git", "--git-dir", str(repository), *args], capture_output=True, check=True, timeout=120)
            return process.stdout.decode()
        git("fsck", "--full")
        refs = git("for-each-ref", "--format=%(refname) %(objectname)")
        objects = git("cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)")
        repositories[repository.name] = {"head": (repository / "HEAD").read_text().strip(),
                                         "refs_sha256": hashlib.sha256(refs.encode()).hexdigest(),
                                         "objects_sha256": hashlib.sha256(objects.encode()).hexdigest(),
                                         "objects": len(objects.splitlines())}
    return {"table_rows": counts, "table_digests": digests, "repositories": repositories}


def checked_cli(*args):
    result = subprocess.run([sys.executable, str(ROOT / "scripts/gitclub"), *args], capture_output=True, text=True, timeout=300)
    assert result.returncode == 0, result.stderr
    return {"arguments": list(args), "stdout": result.stdout, "stderr": result.stderr, "exit_code": result.returncode}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--database-url", required=True, help="Source database")
    parser.add_argument("--restored-database-url", required=True, help="Empty database to restore into")
    parser.add_argument("--restored-dir", type=Path, help="New empty restore directory; omitted uses temporary directory")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    source = args.data_dir.resolve()
    report = {"implementation": "go", "source": str(source), "started_at_unix": time.time(), "status": "failed"}
    try:
        assert psql(args.database_url, "SELECT 1").strip() == "1", "Source database is unreachable"
        with (source / "server.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pid_file = source / "server.pid"
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text().strip()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("Server PID is alive; stop server before offline recovery test")
        before = fingerprint(source, args.database_url)
        with tempfile.TemporaryDirectory(prefix="gitclub-recovery-") as temp:
            archive = Path(temp) / "snapshot.tar.gz"
            restored = args.restored_dir.resolve() if args.restored_dir else Path(temp) / "restored"
            assert not restored.exists() or not any(restored.iterdir()), "Restore target must be empty"
            report["backup"] = checked_cli("backup", str(archive), "--data-dir", str(source), "--database-url", args.database_url)
            assert archive.stat().st_mode & 0o077 == 0, "Backup permissions expose private repositories/credentials"
            report["archive_bytes"] = archive.stat().st_size
            report["restore"] = checked_cli("restore", str(archive), "--data-dir", str(restored), "--database-url", args.restored_database_url)
            after = fingerprint(restored, args.restored_database_url)
            assert before == after, "Restored database rows, Git refs or object set differs from source"
            assert before == fingerprint(source, args.database_url), "Backup/restore changed source data"
            refusal = subprocess.run([sys.executable, str(ROOT / "scripts/gitclub"), "restore", str(archive),
                                      "--data-dir", str(restored), "--database-url", args.restored_database_url],
                                     capture_output=True, text=True, timeout=30)
            assert refusal.returncode != 0, "Restore overwrote a populated data directory"
            assert after == fingerprint(restored, args.restored_database_url), "Rejected restore changed destination"
            report.update(status="passed", preserved=after,
                          restored_directory=str(restored) if args.restored_dir else "temporary, verified and removed",
                          overwrite_refusal={"exit_code": refusal.returncode, "stderr": refusal.stderr})
    except Exception as error:
        report.update(error=str(error), traceback=traceback.format_exc())
    report["elapsed_seconds"] = time.time() - report["started_at_unix"]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(report["status"].upper() + ": offline backup/restore" + (": " + report["error"] if "error" in report else ""))
    return report["status"] != "passed"


if __name__ == "__main__":
    raise SystemExit(main())
