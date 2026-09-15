#!/usr/bin/env python3
"""Run the GitClub server and the OpenSSH transport in one Railway container.

Compose keeps these in separate services sharing a volume. Railway attaches a
volume to one service only, and the SSH transport needs the same /data, so both
processes live here.

Either process exiting takes the container down, so Railway restarts a whole
container rather than leaving a half-serving one. SSH is optional: when
GITCLUB_SSH_SECRET is unset the container serves HTTP Git only and says so,
rather than failing to start.
"""
from __future__ import annotations

import os
import pwd
import signal
import subprocess
import sys
import time
from pathlib import Path

SHARED = Path(os.environ.get("SHARED_DIR", "/app/shared"))
DATA = Path(os.environ.get("DATA_DIR", "/data"))


def log(message: str) -> None:
    print(f"entrypoint: {message}", flush=True)


def main() -> int:
    account = pwd.getpwnam("git")
    for directory in (DATA, DATA / "repos"):
        directory.mkdir(parents=True, exist_ok=True)
        os.chown(directory, account.pw_uid, account.pw_gid)

    children: list[tuple[str, subprocess.Popen]] = []

    secret = os.environ.get("GITCLUB_SSH_SECRET", "")
    if secret:
        if len(secret) < 32:
            raise SystemExit("entrypoint: GITCLUB_SSH_SECRET must contain at least 32 characters.")
        os.environ.setdefault("GITCLUB_URL", f"http://127.0.0.1:{os.environ.get('PORT', '7701')}")
        log("starting the OpenSSH transport on 2222")
        children.append(("sshd", subprocess.Popen(
            [sys.executable, str(SHARED / "ssh-entrypoint.py")], env=dict(os.environ))))
    else:
        log("GITCLUB_SSH_SECRET is unset; serving HTTP Git only, SSH disabled")

    log("starting the GitClub server")
    children.append(("gitclub", subprocess.Popen(
        [sys.executable, "/app/scripts/gitclub", "run", "--no-build",
         "--host", "0.0.0.0", "--data-dir", str(DATA)],
        env=dict(os.environ), user=account.pw_uid, group=account.pw_gid)))

    stopping = False

    def stop(signum, _frame):
        nonlocal stopping
        stopping = True
        for name, child in children:
            if child.poll() is None:
                log(f"forwarding signal {signum} to {name}")
                child.send_signal(signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    # Either process failing takes the container down. A container serving HTTP
    # with a dead SSH transport, or the reverse, looks healthy and is not.
    status = 0
    while True:
        for name, child in children:
            code = child.poll()
            if code is not None:
                if not stopping:
                    log(f"{name} exited with status {code}; stopping the container")
                    status = code or 1
                    stop(signal.SIGTERM, None)
                    deadline = time.monotonic() + 20
                    for other_name, other in children:
                        remaining = max(0.0, deadline - time.monotonic())
                        try:
                            other.wait(timeout=remaining)
                        except subprocess.TimeoutExpired:
                            log(f"killing {other_name}")
                            other.kill()
                return status
        if stopping and all(child.poll() is not None for _, child in children):
            return 0
        time.sleep(0.5)


if __name__ == "__main__":
    raise SystemExit(main())
