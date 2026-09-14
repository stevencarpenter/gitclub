#!/usr/bin/env python3
"""Verify a restarted/restored server using a private acceptance --state-file."""
import argparse
import json
from pathlib import Path
import tempfile
import time
import traceback
from acceptance import Client, git


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = {"url": args.url, "started_at_unix": time.time(), "status": "failed"}
    try:
        assert args.state_file.stat().st_mode & 0o077 == 0, "Credential state file must be private (mode0600)"
        state = json.loads(args.state_file.read_text())
        client = Client(args.url, state["token"])
        assert client.get("/api/session")["user"] == state["user"], "Original session token was not recovered"
        login = Client(args.url).post("/api/auth/login", {"username": state["username"], "password": state["password"]})
        assert login["user"] == state["user"], "Recovered password authentication changed user"
        checked = []
        for request in state["requests"]:
            actual, expected = client.get(request["path"]), request["expected"]
            if request["path"] == "/api/groups":
                # Other test users can publish shared groups after this fixture snapshot.
                actual = {"groups": [g for g in actual["groups"] if g["creator_id"] == state["user"]["id"]]}
                expected = {"groups": [g for g in expected["groups"] if g["creator_id"] == state["user"]["id"]]}
            assert actual == expected, "Restored response differs: " + request["path"]
            checked.append(request["path"])
        with tempfile.TemporaryDirectory(prefix="gitclub-readback-") as temporary:
            remote = args.url.rstrip("/") + "/" + state["full_name"] + ".git"
            assert git(temporary, "ls-remote", remote, token=state["token"]) == state["refs"], "Restored Git refs changed"
            git(temporary, "clone", remote, str(Path(temporary) / "clone"), token=login["token"])
            git(Path(temporary) / "clone", "fsck", "--full")
        Client(args.url, login["token"]).post("/api/auth/logout", {})
        report.update(status="passed", checked_paths=checked, original_token=True,
                      password_login=True, git_refs_equal=True, authenticated_clone_fsck=True,
                      group_scope="Fixture-owned groups; offline recovery separately verifies every database row")
    except Exception as error:
        report.update(error=str(error), traceback=traceback.format_exc())
    report["elapsed_seconds"] = time.time() - report["started_at_unix"]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(report["status"].upper() + ": authenticated restore readback" + (": " + report["error"] if "error" in report else ""))
    return report["status"] != "passed"


if __name__ == "__main__":
    raise SystemExit(main())
