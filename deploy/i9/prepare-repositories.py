#!/usr/bin/env python3
"""Copy DR mirrors into an empty GitClub data volume and restore server hooks.

Run as root inside the GitClub application image, with /mirrors mounted read-only
and DATABASE_URL pointing to the recovered database. The primary is never used.
"""
import os
import pwd
import shutil
import subprocess
from pathlib import Path


def main():
    data = Path(os.environ.get("DATA_DIR", "/data"))
    mirrors = Path(os.environ.get("GITCLUB_MIRRORS", "/mirrors"))
    destination = data / "repos"
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"Refusing to overwrite non-empty {destination}")
    inventory = subprocess.check_output([
        "psql", os.environ["DATABASE_URL"], "-X", "-v", "ON_ERROR_STOP=1", "-At", "-F", "|",
        "-c", "SELECT id, default_branch FROM repositories ORDER BY id",
    ], text=True).splitlines()
    account = pwd.getpwnam("git")
    hook = Path(os.environ.get("SHARED_DIR", "/app/shared")) / "git-hook.py"
    destination.mkdir(parents=True, exist_ok=True)
    for line in inventory:
        identifier, branch = line.split("|", 1)
        repository = destination / f"{int(identifier)}.git"
        shutil.copytree(mirrors / repository.name, repository)
        for name in ("pre-receive", "post-receive"):
            target = repository / "hooks" / name
            shutil.copyfile(hook, target)
            target.chmod(0o700)
        os.chown(repository, account.pw_uid, account.pw_gid)
        for path in repository.rglob("*"):
            os.chown(path, account.pw_uid, account.pw_gid, follow_symlinks=False)
        git = ["git", f"--git-dir={repository}"]
        for arguments in (["config", "http.receivepack", "true"],
                          ["config", "transfer.hideRefs", "refs/gitclub/"],
                          ["symbolic-ref", "HEAD", "refs/heads/" + branch]):
            subprocess.run(git + arguments, user=account.pw_uid, group=account.pw_gid, check=True)
    for path in (data, destination):
        os.chown(path, account.pw_uid, account.pw_gid)
        path.chmod(0o700)
    print(f"Prepared {len(inventory)} repositories with receive hooks and application ownership.")


if __name__ == "__main__":
    main()
