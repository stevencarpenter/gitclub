#!/usr/bin/env python3
"""Black-box GitClub contract checks. Run against an isolated running server.

python3 tests/acceptance.py --url http://127.0.0.1:7701 --report /tmp/go.json
Only the optional missed-hook recovery check writes the supplied --data-dir.
"""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import random
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request


class Client:
    def __init__(self, url: str, token: str = "", cookie: str = ""):
        self.url, self.token, self.cookie = url.rstrip("/"), token, cookie
        self.last_headers = None

    def request(self, method, path, data=None, expect=200, headers=None, raw=None):
        h = {"Accept": "application/json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.cookie:
            h["Cookie"] = self.cookie
        if data is not None:
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        body = raw if raw is not None else None if data is None else json.dumps(data).encode()
        request = urllib.request.Request(self.url + path, data=body, headers=h, method=method)
        try:
            response = urllib.request.urlopen(request, timeout=130)
        except urllib.error.HTTPError as error:
            response = error
        self.last_headers = response.headers
        status, payload = response.status, response.read()
        try:
            result = json.loads(payload) if payload else None
        except (ValueError, UnicodeDecodeError):
            result = payload.decode(errors="replace")
        allowed = (expect,) if isinstance(expect, int) else expect
        assert status in allowed, f"{method} {path}: expected {allowed}, got {status}: {str(result)[:500]}"
        if status >= 400 and path.startswith("/api/"):
            assert isinstance(result, dict) and isinstance(result.get("error"), str), result
            assert "Traceback" not in result["error"] and "password_hash" not in result["error"]
        return result

    def get(self, path, **kwargs):
        return self.request("GET", path, **kwargs)

    def post(self, path, data=None, **kwargs):
        return self.request("POST", path, data, **kwargs)

    def patch(self, path, data, **kwargs):
        return self.request("PATCH", path, data, **kwargs)


def git(directory, *args, token="", ok=True, input=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS="1",
               GIT_AUTHOR_DATE="2025-01-01T12:00:00Z", GIT_COMMITTER_DATE="2025-01-01T12:00:00Z")
    if token:
        auth = base64.b64encode(("git:" + token).encode()).decode()
        env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.extraHeader",
                   GIT_CONFIG_VALUE_0="Authorization: Basic " + auth)
    result = subprocess.run(["git", "-C", str(directory), *args], env=env, input=input,
                            capture_output=True, timeout=135)
    detail = result.stderr.decode(errors="replace")[-1200:]
    if token:
        detail = detail.replace(token, "[redacted]")
    assert ok is None or (result.returncode == 0) == ok, f"git {' '.join(args)}: exit {result.returncode}: {detail}"
    return result.stdout.decode(errors="replace").strip()


def init_repo(directory):
    directory.mkdir()
    git(directory, "init", "-b", "trunk")
    git(directory, "config", "user.name", "Acceptance User")
    git(directory, "config", "user.email", "acceptance@example.invalid")
    (directory / "README.md").write_text("GitClub acceptance fixture\n")
    (directory / "src").mkdir()
    (directory / "src" / "hello.txt").write_text("hello\n")
    (directory / "binary.bin").write_bytes(b"\x00\xff\x01")
    git(directory, "add", ".")
    git(directory, "commit", "-m", "Initial fixture")
    git(directory, "tag", "v1")
    return git(directory, "rev-parse", "HEAD")


def commit(directory, file, content, message):
    (directory / file).write_text(content)
    git(directory, "add", file)
    git(directory, "commit", "-m", message)
    return git(directory, "rev-parse", "HEAD")


class Suite:
    def __init__(self, url, data_dir=None):
        self.url = url.rstrip("/")
        self.anon = Client(url)
        self.prefix = "t" + secrets.token_hex(5)
        self.password = "acceptance-password-" + secrets.token_hex(8)
        self.temp = tempfile.TemporaryDirectory(prefix="gitclub-acceptance-")
        self.root = Path(self.temp.name)
        self.data_dir = Path(data_dir).resolve() if data_dir else None
        self.results = []
        self.mcp_called = set()

    def run_case(self, name, function):
        start = time.perf_counter()
        try:
            function()
            result = {"name": name, "status": "passed"}
        except Exception as error:
            result = {"name": name, "status": "failed", "error": str(error),
                      "traceback": traceback.format_exc()}
        result["elapsed_seconds"] = round(time.perf_counter() - start, 6)
        self.results.append(result)
        print(f"{result['status'].upper():6} {name}" + (": " + result["error"] if "error" in result else ""), flush=True)
        return result["status"] == "passed"

    def register(self, suffix):
        username = self.prefix + suffix
        response = self.anon.post("/api/auth/register", {"username": username, "password": self.password}, expect=201)
        assert response["user"]["username"] == username
        assert len(response["token"]) == 64
        return Client(self.url, response["token"]), response["user"]

    def repo(self, name, owner=None, visibility="private"):
        return self.a.post("/api/repos", {"owner": owner or self.ua["username"], "name": name,
                           "default_branch": "trunk", "visibility": visibility}, expect=201)["repository"]

    def path(self, repo=None):
        return "/api/repos/" + str((repo or self.r)["id"])

    def remote(self, repo=None):
        repo = repo or self.r
        return self.url + "/" + repo["owner"] + "/" + repo["name"] + ".git"

    def setup(self):
        health = self.anon.get("/health")
        assert health["status"] == "ok" and health["implementation"] == "go"
        self.implementation = health["implementation"]
        self.a, self.ua = self.register("a")
        self.b, self.ub = self.register("b")
        self.c, self.uc = self.register("c")
        self.org = self.prefix + "org"
        self.a.post("/api/namespaces", {"name": self.org}, expect=201)
        self.r = self.repo("project")
        self.other = self.repo("organization-project", self.org)
        self.public = self.repo("public-project", visibility="public")
        self.hidden = self.repo("private-project")
        self.a.post(self.path() + "/members", {"username": self.ub["username"], "role": "write"})
        self.work = self.root / "work"
        self.initial_oid = init_repo(self.work)
        git(self.work, "branch", "imported-branch")
        git(self.work, "tag", "-a", "annotated-v1", "-m", "Preserve annotated tag object")
        self.annotated_tag_oid = git(self.work, "rev-parse", "refs/tags/annotated-v1")
        git(self.work, "remote", "add", "origin", self.remote())

    def auth(self):
        assert self.anon.get("/api/session")["user"] is None
        assert self.a.get("/api/session")["user"]["id"] == self.ua["id"]
        users = self.a.get("/api/users?q=" + self.ub["username"])["users"]
        assert self.ub in users
        assert all(set(user) <= {"id", "username"} for user in users)
        self.anon.get("/api/users", expect=401)
        self.anon.post("/api/auth/login", {"username": self.ua["username"], "password": "incorrect-password"}, expect=401)
        session = Client(self.url)
        login = session.post("/api/auth/login", {"username": self.ua["username"], "password": self.password})
        cookie = session.last_headers.get("Set-Cookie", "")
        assert "HttpOnly" in cookie and "SameSite=Strict" in cookie, cookie
        cookie_client = Client(self.url, cookie=cookie.split(";", 1)[0])
        cookie_client.post(self.path() + "/pin", {"pinned": True}, expect=403)
        cookie_client.post(self.path() + "/pin", {"pinned": True}, headers={"Origin": "https://attacker.invalid"}, expect=403)
        cookie_client.post(self.path() + "/pin", {"pinned": False}, headers={"X-GitClub-Request": "1"})
        cookie_client.post("/api/auth/logout", {}, headers={"X-GitClub-Request": "1"})
        assert "Max-Age=0" in cookie_client.last_headers.get("Set-Cookie", "") or "1970" in cookie_client.last_headers.get("Set-Cookie", "")
        revoked = Client(self.url, login["token"])
        revoked.get("/api/users", expect=401)
        assert cookie_client.get("/api/session")["user"] is None

    def permissions(self):
        self.anon.get(self.path(), expect=(401, 404))
        self.c.get(self.path(), expect=404)
        self.anon.get(self.path(self.public))
        self.c.patch(self.path(), {"description": "forbidden"}, expect=(403, 404))
        self.b.patch(self.path(), {"description": "forbidden"}, expect=403)
        self.b.post(self.path() + "/members", {"username": self.uc["username"], "role": "admin"}, expect=403)
        self.b.post("/api/repos", {"owner": self.org, "name": "forbidden"}, expect=403)
        self.a.post("/api/namespaces/" + self.org + "/members", {"username": self.ub["username"], "role": "read"})
        assert self.b.get(self.path(self.other))["repository"]["role"] == "read"
        self.b.post(self.path(self.other) + "/issues", {"title": "forbidden"}, expect=403)
        self.a.post(self.path(self.other) + "/members", {"username": self.ub["username"], "role": "write"})
        assert self.b.get(self.path(self.other))["repository"]["role"] == "write"
        namespaces = self.a.get("/api/namespaces")["namespaces"]
        assert {self.org, self.ua["username"]} <= {n["name"] for n in namespaces}
        repositories = self.a.get("/api/repos")["repositories"]
        assert {self.r["id"], self.other["id"]} <= {r["id"] for r in repositories}
        assert all(isinstance(r["pinned"], bool) and isinstance(r["require_review"], bool) for r in repositories)
        assert self.r["id"] not in {r["id"] for r in self.c.get("/api/repos")["repositories"]}
        assert all(r["owner"] == self.org for r in self.a.get("/api/repos?owner=" + self.org)["repositories"])
        found = self.a.get("/api/repos?q=" + urllib.parse.quote(self.org.upper()))["repositories"]
        assert self.other["id"] in {r["id"] for r in found}

    def transport(self):
        git(self.work, "push", "--mirror", "origin", token=self.a.token)
        git(self.work, "ls-remote", self.remote(), token=self.c.token, ok=False)
        git(self.work, "ls-remote", self.remote(), ok=False)
        git(self.root, "clone", self.remote(), str(self.root / "clone"), token=self.b.token)
        assert git(self.root / "clone", "rev-parse", "HEAD") == self.initial_oid
        assert git(self.root / "clone", "rev-parse", "refs/tags/v1") == self.initial_oid
        assert git(self.root / "clone", "rev-parse", "refs/tags/annotated-v1") == self.annotated_tag_oid
        assert git(self.root / "clone", "rev-parse", "origin/imported-branch") == self.initial_oid
        branches = self.a.get(self.path() + "/branches")
        assert branches["default_branch"] == "trunk"
        assert {"name": "trunk", "oid": self.initial_oid} in branches["branches"]
        git(self.work, "push", self.remote(self.public), "trunk", "--tags", token=self.a.token)
        assert self.initial_oid in git(self.work, "ls-remote", self.remote(self.public))
        git(self.work, "push", self.remote(self.hidden), "trunk", token=self.b.token, ok=False)
        git(self.work, "checkout", "-b", "chunked-import", self.initial_oid)
        (self.work / "chunked.bin").write_bytes(random.Random(1729).randbytes(256 * 1024))
        git(self.work, "add", "chunked.bin")
        git(self.work, "commit", "-m", "Binary transfer fixture")
        chunk_oid = git(self.work, "rev-parse", "HEAD")
        blob_oid = git(self.work, "rev-parse", "HEAD:chunked.bin")
        git(self.work, "-c", "http.postBuffer=1024", "push", "origin", "chunked-import", token=self.a.token)
        git(self.root / "clone", "fetch", "origin", "chunked-import", token=self.b.token)
        assert git(self.root / "clone", "rev-parse", "FETCH_HEAD") == chunk_oid
        assert git(self.root / "clone", "rev-parse", "FETCH_HEAD:chunked.bin") == blob_oid
        git(self.root / "clone", "fsck", "--full")
        git(self.work, "checkout", "trunk")

    def browsing(self):
        entries = self.a.get(self.path() + "/tree?ref=trunk")["entries"]
        assert {e["name"]: e["type"] for e in entries} == {"README.md": "file", "src": "directory", "binary.bin": "file"}
        nested = self.a.get(self.path() + "/tree?ref=trunk&path=src")["entries"]
        assert any(e["path"] == "src/hello.txt" for e in nested)
        blob = self.a.get(self.path() + "/blob?ref=trunk&path=README.md")
        assert blob["content"] == "GitClub acceptance fixture\n" and blob["binary"] is False and blob["truncated"] is False
        binary = self.a.get(self.path() + "/blob?ref=trunk&path=binary.bin")
        assert binary["binary"] is True and binary["content"] == ""
        commits = self.a.get(self.path() + "/commits?ref=trunk")["commits"]
        assert commits[0]["oid"] == self.initial_oid and commits[0]["subject"] == "Initial fixture"
        assert self.a.get(self.path(self.other) + "/tree")["entries"] == []

    def freshness(self):
        before = self.a.get(self.path())["repository"]["updated_at"]
        git(self.work, "checkout", "-b", "feature")
        self.feature_oid = commit(self.work, "feature.txt", "feature one\n", "Feature one")
        git(self.work, "push", "origin", "feature", token=self.a.token)
        assert self.a.get(self.path())["repository"]["updated_at"] == before, "Feature pushes changed default-branch freshness"
        diff = self.a.get(self.path() + "/diff?base=trunk&head=feature")
        assert "+feature one" in diff["diff"] and diff["base_oid"] == self.initial_oid and diff["head_oid"] == self.feature_oid
        self.a.patch(self.path(), {"require_review": False})
        git(self.work, "checkout", "trunk")
        time.sleep(0.02)
        self.main_oid = commit(self.work, "main.txt", "default update\n", "Default branch update")
        git(self.work, "push", "origin", "trunk", token=self.a.token)
        after = self.a.get(self.path())["repository"]["updated_at"]
        assert after > before, "Default-branch push did not update freshness"
        self.a.post(self.path(self.other) + "/pin", {"pinned": True})
        own = [r for r in self.a.get("/api/repos")["repositories"] if r["owner"] in (self.org, self.ua["username"])]
        assert own[0]["id"] == self.other["id"], "Pins must precede fresher unpinned repositories"
        self.a.post(self.path() + "/pin", {"pinned": True})
        own = [r for r in self.a.get("/api/repos")["repositories"] if r["owner"] in (self.org, self.ua["username"])]
        assert own[0]["id"] == self.r["id"], "Pinned repositories must sort by freshness"
        assert self.b.get(self.path())["repository"]["pinned"] is False, "Pins leaked between users"
        self.a.post(self.path() + "/pin", {"pinned": False})
        self.a.post(self.path(self.other) + "/pin", {"pinned": False})
        self.a.patch(self.path(), {"require_review": True})

    def protected_refs(self):
        git(self.work, "checkout", "trunk")
        commit(self.work, "blocked.txt", "blocked\n", "Rejected direct update")
        git(self.work, "push", "origin", "trunk", token=self.a.token, ok=False)
        assert self.main_oid in git(self.work, "ls-remote", "origin", "refs/heads/trunk", token=self.a.token)
        self.a.patch(self.path(), {"require_review": False})
        git(self.work, "push", "--force", "origin", self.initial_oid + ":refs/heads/trunk", token=self.a.token, ok=False)
        git(self.work, "push", "origin", ":refs/heads/trunk", token=self.a.token, ok=False)
        self.a.patch(self.path(), {"require_review": True})
        git(self.work, "reset", "--hard", self.main_oid)

    def groups(self):
        group = self.a.post("/api/groups", {"name": self.prefix + " group", "shared": False}, expect=201)["group"]
        p = "/api/groups/" + str(group["id"])
        self.a.patch(p, {"repo_ids": [self.r["id"], self.other["id"], self.hidden["id"], self.public["id"]]})
        assert group["id"] not in {g["id"] for g in self.b.get("/api/groups")["groups"]}
        self.b.get("/api/repos?group=" + str(group["id"]), expect=404)
        self.a.patch(p, {"shared": True})
        visible = next(g for g in self.b.get("/api/groups")["groups"] if g["id"] == group["id"])
        assert set(visible["repo_ids"]) == {self.r["id"], self.other["id"], self.public["id"]}, visible
        outsider = next(g for g in self.c.get("/api/groups")["groups"] if g["id"] == group["id"])
        assert outsider["repo_ids"] == [self.public["id"]], outsider
        filtered = self.c.get("/api/repos?group=" + str(group["id"]))["repositories"]
        assert [r["id"] for r in filtered] == [self.public["id"]]
        self.b.patch(p, {"name": "forbidden"}, expect=403)
        self.b.request("DELETE", p, expect=403)
        own = self.c.post("/api/groups", {"name": "outsider"}, expect=201)["group"]
        self.c.patch("/api/groups/" + str(own["id"]), {"repo_ids": [self.r["id"]]}, expect=(403, 404))
        self.a.patch(p, {"name": "renamed", "repo_ids": [self.r["id"]]})
        self.a.request("DELETE", p)
        assert group["id"] not in {g["id"] for g in self.a.get("/api/groups")["groups"]}

    def issues(self):
        issue = self.b.post(self.path() + "/issues", {"title": "Import verified", "body": "Keep the history."}, expect=201)["issue"]
        p = self.path() + "/issues/" + str(issue["id"])
        assert issue["author_id"] == self.ub["id"] and issue["state"] == "open"
        comment = self.a.post(p + "/comments", {"body": "Reviewed <script>alert(1)</script>"}, expect=201)["comment"]
        detail = self.b.get(p)
        assert comment["body"] == detail["comments"][0]["body"]
        self.b.patch(p, {"state": "closed", "title": "Import completed"})
        assert self.a.get(p)["issue"]["state"] == "closed"
        assert issue["id"] in {i["id"] for i in self.a.get(self.path() + "/issues")["issues"]}
        self.a.get(self.path(self.other) + "/issues/" + str(issue["id"]), expect=404)
        self.c.post(p + "/comments", {"body": "forbidden"}, expect=(403, 404))

    def reviews_and_merge(self):
        pull = self.a.post(self.path() + "/pulls", {"title": "Feature proposal", "head_branch": "feature"}, expect=201)["pull"]
        p = self.path() + "/pulls/" + str(pull["id"])
        self.pull_path = p
        detail = self.a.get(p)
        assert detail["pull"]["base_branch"] == "trunk" and not detail["mergeable"] and detail["merge_blockers"]
        self.a.post(p + "/reviews", {"expected_head_oid": self.feature_oid, "decision": "approve"}, expect=(400, 403))
        self.a.post(p + "/comments", {"body": "Inline", "path": "feature.txt", "line": 1, "commit_oid": self.feature_oid}, expect=201)
        self.a.post(p + "/comments", {"body": "Stale", "path": "feature.txt", "line": 1, "commit_oid": self.initial_oid}, expect=(400, 409))
        self.b.post(p + "/reviews", {"expected_head_oid": self.feature_oid, "decision": "approve", "body": "Approved current diff"}, expect=201)
        assert self.a.get(p)["mergeable"] is True
        git(self.work, "checkout", "feature")
        previous_head = self.feature_oid
        self.feature_oid = commit(self.work, "feature.txt", "feature two\n", "Revise feature")
        git(self.work, "push", "origin", "feature", token=self.a.token)
        self.a.post(p + "/merge", {"expected_head_oid": previous_head}, expect=409)
        self.b.post(p + "/reviews", {"decision": "approve", "expected_head_oid": previous_head}, expect=409)
        self.a.post(p + "/merge", {"expected_head_oid": self.feature_oid}, expect=409)
        assert not self.a.get(p)["mergeable"], "Approval of old head allowed new head merge"
        self.b.post(p + "/reviews", {"expected_head_oid": self.feature_oid, "decision": "request_changes", "body": "Change requested"}, expect=201)
        self.a.post(p + "/merge", {"expected_head_oid": self.feature_oid}, expect=409)
        self.b.post(p + "/reviews", {"expected_head_oid": self.feature_oid, "decision": "approve"}, expect=201)
        merged = self.a.post(p + "/merge", {"expected_head_oid": self.feature_oid})
        assert merged["pull"]["state"] == "merged" and merged["commit_oid"] == merged["pull"]["merged_oid"]
        git(self.work, "fetch", "origin", token=self.a.token)
        assert git(self.work, "rev-parse", "origin/trunk") == merged["commit_oid"]
        parents = git(self.work, "show", "-s", "--format=%P", "origin/trunk").split()
        assert parents == [self.main_oid, self.feature_oid], parents
        assert git(self.work, "show", "-s", "--format=%an", "origin/trunk") == self.ua["username"]
        assert git(self.work, "show", "origin/trunk:feature.txt") == "feature two"
        self.a.post(p + "/merge", {"expected_head_oid": self.feature_oid}, expect=409)
        self.a.patch(p, {"state": "open"}, expect=409)

    def merge_conflict(self):
        git(self.work, "checkout", "-B", "conflict", "origin/trunk")
        conflict_oid = commit(self.work, "README.md", "head version\n", "Conflicting head")
        git(self.work, "push", "origin", "conflict", token=self.a.token)
        git(self.work, "checkout", "-B", "trunk", "origin/trunk")
        base_oid = commit(self.work, "README.md", "base version\n", "Conflicting base")
        self.a.patch(self.path(), {"require_review": False})
        git(self.work, "push", "origin", "trunk", token=self.a.token)
        self.a.patch(self.path(), {"require_review": True})
        pull = self.a.post(self.path() + "/pulls", {"title": "Conflict proposal", "head_branch": "conflict"}, expect=201)["pull"]
        p = self.path() + "/pulls/" + str(pull["id"])
        self.b.post(p + "/reviews", {"expected_head_oid": conflict_oid, "decision": "approve"}, expect=201)
        detail = self.a.get(p)
        assert not detail["mergeable"] and any("conflict" in b.lower() for b in detail["merge_blockers"]), detail
        self.a.post(p + "/merge", {"expected_head_oid": conflict_oid}, expect=409)
        assert base_oid in git(self.work, "ls-remote", "origin", "refs/heads/trunk", token=self.a.token)
        self.a.patch(p, {"state": "closed"})
        assert self.a.get(p)["pull"]["state"] == "closed"

    def reviewer_authorization_and_race(self):
        git(self.work, "fetch", "origin", token=self.a.token)
        git(self.work, "checkout", "-B", "race-feature", "origin/trunk")
        head = commit(self.work, "race.txt", "one accepted merge\n", "Concurrent merge fixture")
        git(self.work, "push", "origin", "race-feature", token=self.a.token)
        pull = self.a.post(self.path() + "/pulls", {"title": "Concurrent merge", "head_branch": "race-feature"}, expect=201)["pull"]
        p = self.path() + "/pulls/" + str(pull["id"])
        self.b.post(p + "/reviews", {"expected_head_oid": head, "decision": "approve"}, expect=201)
        self.a.post(self.path() + "/members", {"username": self.ub["username"], "role": "read"})
        self.a.post(p + "/merge", {"expected_head_oid": head}, expect=409)
        assert not self.a.get(p)["mergeable"], "Approval from a reader permitted merge"
        self.b.post(p + "/reviews", {"expected_head_oid": head, "decision": "approve"}, expect=403)
        self.a.post(self.path() + "/members", {"username": self.ub["username"], "role": "write"})
        self.b.post(p + "/reviews", {"expected_head_oid": head, "decision": "request_changes"}, expect=201)
        self.b.post(p + "/reviews", {"expected_head_oid": head, "decision": "comment", "body": "A comment does not withdraw the decision"}, expect=201)
        self.a.patch(self.path(), {"require_review": False})
        self.a.post(p + "/merge", {"expected_head_oid": head}, expect=409)
        self.a.patch(self.path(), {"require_review": True})
        self.b.post(p + "/reviews", {"expected_head_oid": head, "decision": "approve"}, expect=201)
        def merge_once(_):
            return Client(self.url, self.a.token).post(p + "/merge", {"expected_head_oid": head}, expect=(200, 409))
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(merge_once, range(2)))
        assert sum("commit_oid" in result for result in results) == 1, results
        accepted = next(result for result in results if "commit_oid" in result)
        assert accepted["commit_oid"] in git(self.work, "ls-remote", "origin", "refs/heads/trunk", token=self.a.token)

    def bounded_blob_and_default_change(self):
        git(self.work, "checkout", "-B", "published", self.initial_oid)
        text = "Large text fixture\n" * 40000
        oid = commit(self.work, "large.txt", text, "Large bounded blob")
        git(self.work, "push", self.remote(self.public), "published", token=self.a.token)
        before = self.a.get(self.path(self.public))["repository"]["updated_at"]
        blob = self.a.get(self.path(self.public) + "/blob?ref=published&path=large.txt")
        assert blob["truncated"] is True and blob["binary"] is False, {k: v for k, v in blob.items() if k != "content"}
        assert blob["size"] == len(text.encode()) and len(blob["content"].encode()) <= 512 * 1024
        self.a.patch(self.path(self.public), {"default_branch": "published"})
        after = self.a.get(self.path(self.public))["repository"]
        assert after["default_branch"] == "published" and after["updated_at"] > before
        git(self.root, "clone", self.remote(self.public), str(self.root / "changed-default"))
        assert git(self.root / "changed-default", "symbolic-ref", "--short", "HEAD") == "published"
        assert git(self.root / "changed-default", "rev-parse", "HEAD") == oid

    def validation(self):
        for name in ("../escape", "UPPERCASE", "project.git", ".", "a/b"):
            self.a.post("/api/repos", {"owner": self.ua["username"], "name": name}, expect=400)
        self.a.post("/api/repos", {"owner": self.ua["username"], "name": self.r["name"]}, expect=409)
        self.a.patch(self.path(), {"default_branch": "-malicious"}, expect=400)
        self.a.patch(self.path(), {"visibility": "world"}, expect=400)
        self.a.post(self.path() + "/members", {"username": self.ub["username"], "role": "owner"}, expect=400)
        self.a.post(self.path() + "/pin", {"pinned": "false"}, expect=400)
        self.a.post(self.path() + "/issues", {"title": ""}, expect=400)
        self.a.post("/api/groups", {"name": ""}, expect=400)
        self.a.post(self.path() + "/pulls", {"title": "Invalid", "head_branch": "trunk"}, expect=400)
        for path in ("../secret", "/etc/passwd", "src/../../secret"):
            self.a.get(self.path() + "/blob?ref=trunk&path=" + urllib.parse.quote(path), expect=400)
        self.a.get(self.path() + "/diff?base=-x&head=trunk", expect=400)
        self.a.post("/api/groups", raw=b"{", headers={"Content-Type": "application/json"}, expect=400)
        self.a.post("/api/groups", raw=b'{"name":"' + b"a" * 1_048_576 + b'"}', headers={"Content-Type": "application/json"}, expect=(400, 413))
        self.a.post("/api/ssh-keys", {"title": "bad", "public_key": 'command="evil" ssh-ed25519 AAAA'}, expect=400)

    def ssh_keys(self):
        key = self.root / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True, capture_output=True)
        public_key = key.with_suffix(".pub").read_text().strip()
        self.a.post("/api/ssh-keys", {"title": "multiline", "public_key": public_key + "\n" + public_key}, expect=400)
        item = self.a.post("/api/ssh-keys", {"title": "Acceptance key", "public_key": public_key}, expect=201)["ssh_key"]
        assert item["public_key"].split()[:2] == public_key.split()[:2], "SSH key material changed"
        duplicate = " ".join(public_key.split()[:2]) + " another-comment"
        self.b.post("/api/ssh-keys", {"title": "duplicate", "public_key": duplicate}, expect=409)
        assert item["id"] in {k["id"] for k in self.a.get("/api/ssh-keys")["ssh_keys"]}
        assert item["id"] not in {k["id"] for k in self.b.get("/api/ssh-keys")["ssh_keys"]}
        self.b.request("DELETE", "/api/ssh-keys/" + str(item["id"]), expect=(403, 404))
        self.a.request("DELETE", "/api/ssh-keys/" + str(item["id"]))
        assert item["id"] not in {k["id"] for k in self.a.get("/api/ssh-keys")["ssh_keys"]}

    def recovery(self):
        assert self.data_dir is not None
        bare = self.data_dir / "repos" / (str(self.r["id"]) + ".git")
        assert bare.is_dir(), f"--data-dir does not contain fixture repository {bare}"
        before = self.a.get(self.path())["repository"]["updated_at"]
        git(self.work, "checkout", "-B", "trunk", "origin/trunk")
        recovered_oid = commit(self.work, "recovery.txt", "missing notification\n", "Missed hook notification")
        # Bypass hooks only in this isolated data-dir to simulate a lost post-receive notification.
        git(bare, "fetch", str(self.work), "trunk:refs/heads/recovery-source")
        git(bare, "update-ref", "refs/heads/trunk", recovered_oid)
        git(bare, "pack-refs", "--all", "--prune")
        listed = next(r for r in self.a.get("/api/repos")["repositories"] if r["id"] == self.r["id"])
        assert listed["updated_at"] > before, "Repository listing failed to reconcile missed default update"
        again = self.a.get(self.path())["repository"]["updated_at"]
        assert again == listed["updated_at"], "Repeated reads changed stable freshness"

    def mcp(self, method, params=None, expect=200, client=None):
        return (client or self.a).post("/mcp", {"jsonrpc": "2.0", "id": 7, "method": method, "params": params or {}}, expect=expect)

    def mcp_protocol(self):
        initialized = self.mcp("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "acceptance", "version": "1"}})
        assert initialized["jsonrpc"] == "2.0" and initialized["id"] == 7
        assert initialized["result"]["protocolVersion"] == "2025-06-18"
        assert "tools" in initialized["result"]["capabilities"]
        for version in ("2024-11-05", "2025-03-26"):
            negotiated = self.mcp("initialize", {"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "acceptance", "version": "1"}})
            assert negotiated["result"]["protocolVersion"] == version
        fallback = self.mcp("initialize", {"protocolVersion": "2099-01-01", "capabilities": {}, "clientInfo": {"name": "acceptance", "version": "1"}})
        assert fallback["result"]["protocolVersion"] == "2025-06-18"
        self.a.post("/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, expect=202)
        assert self.mcp("ping")["result"] == {}
        assert self.mcp("unknown-method")["error"]["code"] == -32601
        assert self.mcp("tools/call", {"name": "unknown-tool", "arguments": {}})["error"]["code"] == -32602
        malformed = self.a.post("/mcp", raw=b"{", headers={"Content-Type": "application/json"}, expect=(200, 400))
        assert malformed["error"]["code"] == -32700
        self.anon.post("/mcp", {"jsonrpc": "2.0", "id": 7, "method": "tools/list"}, expect=401)
        self.a.get("/mcp", expect=405)
        self.tools = self.mcp("tools/list")["result"]["tools"]
        assert self.tools and all("http" not in t and "mapping" not in t and "inputSchema" in t for t in self.tools)
        declaration = Path(__file__).resolve().parents[1] / "shared" / "mcp-tools.json"
        self.declared = json.loads(declaration.read_text())
        if isinstance(self.declared, dict):
            self.declared = self.declared["tools"]
        expected = [{k: v for k, v in t.items() if k != "http"} for t in self.declared]
        assert sorted(self.tools, key=lambda t: t["name"]) == sorted(expected, key=lambda t: t["name"]), "MCP catalog differs from shared declaration"

    def call_tool(self, name, arguments=None, client=None, error=False):
        response = self.mcp("tools/call", {"name": name, "arguments": arguments or {}}, client=client)
        assert response["id"] == 7 and "result" in response, response
        result = response["result"]
        assert bool(result.get("isError", False)) == error, result
        assert result["content"] and result["content"][0]["type"] == "text", result
        self.mcp_called.add(name)
        return json.loads(result["content"][0]["text"])

    def mcp_operations(self):
        rid = {"repo_id": self.r["id"]}
        reads = [
            ("list_repositories", {"owner": self.ua["username"]}, "/api/repos?owner=" + self.ua["username"]),
            ("get_repository", rid, self.path()),
            ("list_branches", rid, self.path() + "/branches"),
            ("browse_tree", dict(rid, ref="trunk", path="src"), self.path() + "/tree?ref=trunk&path=src"),
            ("read_file", dict(rid, ref="trunk", path="README.md"), self.path() + "/blob?ref=trunk&path=README.md"),
            ("list_commits", dict(rid, ref="trunk"), self.path() + "/commits?ref=trunk"),
            ("compare_refs", dict(rid, base="trunk", head="conflict"), self.path() + "/diff?base=trunk&head=conflict"),
            ("list_groups", {}, "/api/groups"),
            ("list_issues", rid, self.path() + "/issues"),
            ("list_pull_requests", rid, self.path() + "/pulls"),
        ]
        for name, arguments, path in reads:
            assert self.call_tool(name, arguments) == self.a.get(path), name + " differs from HTTP API"
        denied = self.call_tool("get_repository", rid, client=self.c, error=True)
        assert "error" in denied
        self.call_tool("set_repository_pin", dict(rid, pinned=True))
        assert self.a.get(self.path())["repository"]["pinned"] is True
        self.call_tool("set_repository_pin", dict(rid, pinned=False))
        repo = self.call_tool("create_repository", {"owner": self.ua["username"], "name": "mcp-project", "default_branch": "trunk"})["repository"]
        assert self.a.get(self.path(repo))["repository"] == repo
        group = self.call_tool("create_group", {"name": self.prefix + " MCP", "shared": True})["group"]
        changed = self.call_tool("update_group", {"group_id": group["id"], "repo_ids": [self.r["id"], repo["id"]]})["group"]
        assert set(changed["repo_ids"]) == {self.r["id"], repo["id"]}
        issue = self.call_tool("create_issue", dict(rid, title="MCP issue", body="Agent-created issue"))["issue"]
        iid = dict(rid, issue_id=issue["id"])
        self.call_tool("update_issue", dict(iid, title="MCP issue updated", state="closed"))
        self.call_tool("comment_on_issue", dict(iid, body="MCP comment"))
        issue_path = self.path() + "/issues/" + str(issue["id"])
        detail = self.call_tool("get_issue", iid)
        assert detail == self.a.get(issue_path) and detail["issue"]["state"] == "closed"
        assert detail["comments"][0]["body"] == "MCP comment"
        git(self.work, "fetch", "origin", token=self.a.token)
        git(self.work, "checkout", "-B", "mcp-feature", "origin/trunk")
        oid = commit(self.work, "mcp.txt", "Agent surface\n", "Integration proposal")
        git(self.work, "push", "origin", "mcp-feature", token=self.a.token)
        pull = self.call_tool("create_pull_request", dict(rid, title="MCP proposal", head_branch="mcp-feature"))["pull"]
        pid = dict(rid, pull_id=pull["id"])
        self.call_tool("update_pull_request", dict(pid, title="MCP proposal updated", body="Native integration"))
        self.call_tool("comment_on_pull_request", dict(pid, body="Agent inline comment", path="mcp.txt", line=1, commit_oid=oid))
        self.call_tool("review_pull_request", dict(pid, decision="approve", expected_head_oid=oid), error=True)
        self.call_tool("review_pull_request", dict(pid, decision="approve", expected_head_oid=oid, body="Independent approval"), client=self.b)
        pull_path = self.path() + "/pulls/" + str(pull["id"])
        detail = self.call_tool("get_pull_request", pid)
        assert detail == self.a.get(pull_path) and detail["mergeable"]
        merged = self.call_tool("merge_pull_request", dict(pid, expected_head_oid=oid))
        assert merged["pull"]["state"] == "merged"
        git(self.work, "fetch", "origin", token=self.a.token)
        assert git(self.work, "rev-parse", "origin/trunk") == merged["commit_oid"]
        assert self.mcp_called == {t["name"] for t in self.declared}, "Untested tools: " + str({t["name"] for t in self.declared} - self.mcp_called)

    def replacement_objects(self):
        git(self.work, "fetch", "origin", token=self.a.token)
        target = git(self.work, "rev-parse", "origin/trunk")
        git(self.work, "checkout", "-B", "replacement-fixture", self.initial_oid)
        replacement = commit(self.work, "README.md", "Replacement must never change reviewed content\n", "Replacement boundary fixture")
        git(self.work, "push", "origin", "replacement-fixture", token=self.a.token)
        paths = [self.path() + "/blob?ref=trunk&path=README.md", self.path() + "/tree?ref=trunk",
                 self.path() + "/commits?ref=trunk", self.path() + "/diff?base=" + self.initial_oid + "&head=trunk"]
        expected = {path: self.a.get(path) for path in paths}
        replace_ref = "refs/replace/" + target
        git(self.work, "update-ref", replace_ref, replacement)
        bare = self.data_dir / "repos" / (str(self.r["id"]) + ".git") if self.data_dir else None
        try:
            # Both rejecting the namespace and storing inert refs are safe policies.
            git(self.work, "push", "origin", replace_ref, token=self.a.token, ok=None)
            for path, response in expected.items():
                assert self.a.get(path) == response, "Pushed replacement rewrote server content: " + path
            if bare:
                # Preexisting/imported replacement refs must also remain inert.
                git(bare, "update-ref", replace_ref, replacement)
                for path, response in expected.items():
                    assert self.a.get(path) == response, "Preexisting replacement rewrote server content: " + path
        finally:
            if bare:
                git(bare, "update-ref", "-d", replace_ref)
            else:
                git(self.work, "push", "origin", ":" + replace_ref, token=self.a.token, ok=None)
            git(self.work, "update-ref", "-d", replace_ref)

    def browser_headers(self):
        self.anon.get("/", expect=200)
        h = self.anon.last_headers
        assert h.get("X-Content-Type-Options") == "nosniff"
        assert h.get("Referrer-Policy") == "same-origin"
        csp = h.get("Content-Security-Policy", "")
        assert "frame-ancestors 'none'" in csp and "'unsafe-inline'" not in csp
        self.anon.get("/repositories", expect=200)

    def save_state(self, destination):
        paths = [self.path(), self.path() + "/branches", self.path() + "/tree?ref=trunk",
                 self.path() + "/commits?ref=trunk", self.path() + "/issues", self.path() + "/pulls", "/api/groups"]
        paths += [self.path() + "/issues/" + str(issue["id"]) for issue in self.a.get(self.path() + "/issues")["issues"]]
        paths += [self.path() + "/pulls/" + str(pull["id"]) for pull in self.a.get(self.path() + "/pulls")["pulls"]]
        state = {"username": self.ua["username"], "password": self.password, "token": self.a.token,
                 "user": self.ua, "full_name": self.r["full_name"],
                 "refs": git(self.work, "ls-remote", self.remote(), token=self.a.token),
                 "requests": [{"path": path, "expected": self.a.get(path)} for path in paths]}
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as file:
            os.fchmod(file.fileno(), 0o600)
            json.dump(state, file)

    def run(self):
        started = time.time()
        if self.run_case("fixture setup and health", self.setup):
            for name, method in [("authentication, cookies, CSRF and logout", self.auth),
                                 ("namespace and repository authorization", self.permissions),
                                 ("native Git import, private clone, branches and tags", self.transport),
                                 ("tree, blob, binary and history", self.browsing),
                                 ("default-branch freshness and personal pins", self.freshness),
                                 ("protected default branch rejects direct/force/delete pushes", self.protected_refs),
                                 ("shared groups preserve repository access", self.groups),
                                 ("issues, edits and comments", self.issues),
                                 ("reviews, stale approvals, compare-and-swap and merge", self.reviews_and_merge),
                                 ("merge conflict preserves branch tip", self.merge_conflict),
                                 ("reviewer access, decisive reviews and concurrent merge", self.reviewer_authorization_and_race),
                                 ("bounded blob and default-branch change", self.bounded_blob_and_default_change),
                                 ("invalid input boundaries", self.validation),
                                 ("SSH key lifecycle and ownership", self.ssh_keys),
                                 ("MCP protocol and declared catalog", self.mcp_protocol),
                                 ("all MCP tools execute with HTTP parity", self.mcp_operations),
                                 ("replacement refs cannot rewrite reviewed code", self.replacement_objects),
                                 ("browser security headers and SPA route", self.browser_headers)]:
                self.run_case(name, method)
            if self.data_dir:
                self.run_case("missed default-branch notification recovery", self.recovery)
            else:
                self.results.append({"name": "missed default-branch notification recovery", "status": "skipped", "reason": "--data-dir not supplied"})
        return {"implementation": getattr(self, "implementation", "unknown"), "url": self.url,
                "started_at_unix": started, "elapsed_seconds": round(time.time() - started, 6),
                "environment": {"python": sys.version, "platform": platform.platform(),
                                "git": subprocess.check_output(["git", "--version"], text=True).strip()},
                "mcp_tools_called": sorted(self.mcp_called),
                "results": self.results, "passed": sum(r["status"] == "passed" for r in self.results),
                "failed": sum(r["status"] == "failed" for r in self.results),
                "skipped": sum(r["status"] == "skipped" for r in self.results)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--data-dir", help="Isolated server data dir; enables direct missed-notification simulation")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--state-file", type=Path, help="Optional mode0600 credential/snapshot file for post-restore readback; keep outside repository")
    args = parser.parse_args()
    suite = Suite(args.url, args.data_dir)
    try:
        report = suite.run()
        if args.state_file and report["failed"] == 0:
            suite.save_state(args.state_file)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(f"{report['passed']} passed, {report['failed']} failed, {report['skipped']} skipped")
        return bool(report["failed"])
    finally:
        suite.temp.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
