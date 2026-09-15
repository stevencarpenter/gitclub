#!/usr/bin/env python3
"""Mark allowlisted Kaneo tasks done after their GitClub pull requests merge."""
from __future__ import annotations

import argparse
from contextlib import closing
from email.message import Message
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import time
from typing import IO, Iterator, TypedDict
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

MAX_RESPONSE = 4 * 1024 * 1024
ID = r"[A-Za-z0-9_-]{1,100}"
PROJECT_PATH = re.compile(rf"/dashboard/workspace/({ID})/project/({ID})/board")


class SyncError(Exception):
    """A sanitized failure that can be retried without exposing credentials."""


class RepositoryConfig(TypedDict):
    project_url: str
    done_status: str


class Config(TypedDict):
    gitclub_url: str
    gitclub_token: str
    kaneo_url: str
    kaneo_api_key: str
    repositories: dict[str, RepositoryConfig]


class Task(TypedDict):
    id: str
    projectId: str
    status: str


def origin(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"https://[a-z0-9.-]+(?::[1-9][0-9]{0,4})?", value):
        raise SyncError("URLs must be lowercase HTTPS origins without a trailing slash")
    try:
        if urlsplit(value).port == 0:
            raise ValueError
    except ValueError:
        raise SyncError("Invalid origin port") from None
    return value


def project_id(value: object, kaneo_url: str) -> str:
    if not isinstance(value, str) or not value.startswith(kaneo_url):
        raise SyncError("Project URL does not match the configured Kaneo origin")
    match = PROJECT_PATH.fullmatch(value[len(kaneo_url):])
    if match is None:
        raise SyncError("Project URL must be a canonical Kaneo board URL")
    return match[2]


def task_id(value: object, project_url: str) -> str:
    prefix = project_url.removesuffix("/board") + "/task/"
    if not isinstance(value, str) or not value.startswith(prefix) or not re.fullmatch(ID, value[len(prefix):]):
        raise SyncError("Task URL must belong to the allowlisted Kaneo project")
    return value[len(prefix):]


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise SyncError("Expected a JSON object")
    return value


def load_config(path: Path) -> Config:
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
        raise SyncError("Config must be a private file (mode 0600 or read-only 0400)")
    if metadata.st_size > 1024 * 1024:
        raise SyncError("Config exceeds 1 MiB")
    try:
        data = object_value(json.loads(path.read_bytes()))
    except (ValueError, UnicodeError, RecursionError):
        raise SyncError("Invalid config JSON") from None
    if set(data) != {"gitclub_url", "gitclub_token", "kaneo_url", "kaneo_api_key", "repositories"}:
        raise SyncError("Config fields must match config.example.json")
    gitclub_url, kaneo_url = origin(data["gitclub_url"]), origin(data["kaneo_url"])
    tokens: dict[str, str] = {}
    for key in ("gitclub_token", "kaneo_api_key"):
        value = data[key]
        if not isinstance(value, str) or not re.fullmatch(r"[\x21-\x7e]{1,8192}", value):
            raise SyncError("Credentials must be nonempty printable ASCII without whitespace")
        tokens[key] = value
    repositories: dict[str, RepositoryConfig] = {}
    for repo_id, value in object_value(data["repositories"]).items():
        if not re.fullmatch(r"[1-9][0-9]{0,18}", repo_id) or int(repo_id) > 2**63 - 1:
            raise SyncError("Repository allowlist keys must be positive GitClub IDs")
        mapping = object_value(value)
        if set(mapping) != {"project_url", "done_status"}:
            raise SyncError("Each repository needs project_url and done_status")
        project_url, done_status = mapping["project_url"], mapping["done_status"]
        project_id(project_url, kaneo_url)
        if not isinstance(done_status, str) or not 1 <= len(done_status) <= 100 or any(c.isspace() or ord(c) < 32 for c in done_status):
            raise SyncError("done_status must be a nonempty Kaneo column slug")
        assert isinstance(project_url, str)
        repositories[repo_id] = {"project_url": project_url, "done_status": done_status}
    return {"gitclub_url": gitclub_url, "gitclub_token": tokens["gitclub_token"],
            "kaneo_url": kaneo_url, "kaneo_api_key": tokens["kaneo_api_key"],
            "repositories": repositories}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req: Request, fp: IO[bytes], code: int, msg: str,
                         headers: Message, newurl: str) -> None:
        return None


def request_json(base: str, token: str, path: str, *, method: str = "GET",
                 body: dict[str, str] | None = None) -> object:
    if not re.fullmatch(r"/api/[A-Za-z0-9_/-]+(?:\?after_id=(?:0|[1-9][0-9]{0,18}))?", path):
        raise SyncError("Invalid API path")
    headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
    payload = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        payload = json.dumps(body).encode()
    request = Request(base + path, data=payload, headers=headers, method=method)
    # Refuse even same-origin redirects. Neither server can redirect a credential.
    opener = build_opener(ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=15) as response:
            if not 200 <= response.status < 300:
                raise SyncError("Unexpected HTTP status")
            raw = response.read(MAX_RESPONSE + 1)
    except HTTPError as error:
        status = error.code
        error.close()
        raise SyncError(f"HTTP {status}") from None
    except (URLError, OSError, HTTPException):
        raise SyncError("HTTP request failed") from None
    if len(raw) > MAX_RESPONSE:
        raise SyncError("HTTP response exceeds 4 MiB")
    try:
        return json.loads(raw)
    except (ValueError, UnicodeError, RecursionError):
        raise SyncError("Invalid HTTP JSON response") from None


def verified_task(value: object, expected_id: str, expected_project: str) -> Task:
    task = object_value(value)
    if task.get("id") != expected_id or task.get("projectId") != expected_project:
        raise SyncError("Kaneo task does not belong to the allowlisted project")
    status = task.get("status")
    if not isinstance(status, str):
        raise SyncError("Kaneo task has no status")
    return {"id": expected_id, "projectId": expected_project, "status": status}


def merged_pulls(config: Config, repo_id: str) -> Iterator[dict[str, object]]:
    """Read compact pages from the beginning so failed task updates remain eligible."""
    after_id = 0
    while True:
        path = f"/api/repos/{repo_id}/kaneo/merges?after_id={after_id}"
        pulls = object_value(request_json(config["gitclub_url"], config["gitclub_token"], path)).get("pulls")
        if not isinstance(pulls, list) or len(pulls) > 100:
            raise SyncError("Expected a merge feed page of at most 100 pull requests")
        for value in pulls:
            pull = object_value(value)
            pull_id = pull.get("id")
            if type(pull_id) is not int or not after_id < pull_id <= 2**63 - 1:
                raise SyncError("Merge feed IDs must increase across pages")
            after_id = pull_id
            yield pull
        if len(pulls) < 100:
            return


def sweep(config: Config, state: Path) -> int:
    """Return the failure count; successful updates are durable across restarts."""
    state.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.touch(mode=0o600, exist_ok=True)
    state.chmod(0o600)
    failures = completed = 0
    with closing(sqlite3.connect(state, timeout=20)) as ledger:
        ledger.execute("CREATE TABLE IF NOT EXISTS completed (server TEXT, repo_id TEXT, pull_id INTEGER, task_url TEXT, PRIMARY KEY (server, repo_id, pull_id, task_url))")
        for repo_id, mapping in config["repositories"].items():
            try:
                expected_project = project_id(mapping["project_url"], config["kaneo_url"])
                repo = object_value(object_value(request_json(config["gitclub_url"], config["gitclub_token"], f"/api/repos/{repo_id}")).get("repository"))
                if type(repo.get("id")) is not int or repo["id"] != int(repo_id) or repo.get("kaneo_project_url") != mapping["project_url"]:
                    raise SyncError("Repository does not match its private project allowlist")
                columns_validated = False
                for pull in merged_pulls(config, repo_id):
                    try:
                        if pull.get("state") != "merged" or pull.get("kaneo_task_url", "") == "":
                            continue
                        pull_id, task_url = pull["id"], pull.get("kaneo_task_url")
                        if type(pull.get("repo_id")) is not int or pull["repo_id"] != int(repo_id):
                            raise SyncError("Invalid merged pull request identity")
                        linked_task = task_id(task_url, mapping["project_url"])
                        key = (config["gitclub_url"], repo_id, pull_id, task_url)
                        # Serialize concurrent --once runs against the daemon's ledger.
                        with ledger:
                            ledger.execute("BEGIN IMMEDIATE")
                            if ledger.execute("SELECT 1 FROM completed WHERE server=? AND repo_id=? AND pull_id=? AND task_url=?", key).fetchone():
                                continue
                            if not columns_validated:
                                columns = request_json(config["kaneo_url"], config["kaneo_api_key"], f"/api/column/{expected_project}")
                                if not isinstance(columns, list) or not any(isinstance(c, dict) and c.get("projectId") == expected_project and c.get("slug") == mapping["done_status"] for c in columns):
                                    raise SyncError("Configured done_status is not a column in the allowlisted project")
                                columns_validated = True
                            task = verified_task(request_json(config["kaneo_url"], config["kaneo_api_key"], f"/api/task/{linked_task}"), linked_task, expected_project)
                            if task["status"] != mapping["done_status"]:
                                task = verified_task(request_json(config["kaneo_url"], config["kaneo_api_key"], f"/api/task/status/{linked_task}", method="PUT", body={"status": mapping["done_status"]}), linked_task, expected_project)
                                if task["status"] != mapping["done_status"]:
                                    raise SyncError("Kaneo did not confirm the requested status")
                            ledger.execute("INSERT INTO completed VALUES (?, ?, ?, ?)", key)
                        completed += 1
                    except SyncError as error:
                        print(f"repo {repo_id}: {error}", file=sys.stderr, flush=True)
                        failures += 1
            except SyncError as error:
                print(f"repo {repo_id}: {error}", file=sys.stderr, flush=True)
                failures += 1
    print(f"sweep: {completed} completed, {failures} failed", flush=True)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        while True:
            failures = sweep(load_config(args.config), args.state)
            if args.once:
                return int(failures != 0)
            time.sleep(60)
    except (SyncError, OSError, sqlite3.Error) as error:
        # OS/SQLite error text can include sensitive paths. Only SyncError is safe.
        print(str(error) if isinstance(error, SyncError) else "Cannot read config or persist sync state", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
