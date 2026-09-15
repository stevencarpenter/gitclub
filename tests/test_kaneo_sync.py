"""Offline bridge contract checks: python3 tests/test_kaneo_sync.py."""
from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("kaneo_sync", Path(__file__).resolve().parents[1] / "deploy/kaneo/sync.py")
assert SPEC is not None and SPEC.loader is not None
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)

GITCLUB = "https://gitclub.example.test"
KANEO = "https://kaneo.example.test"
BOARD = KANEO + "/dashboard/workspace/workspace1/project/project1/board"
TASK = BOARD.removesuffix("/board") + "/task/task1"


class SyncChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kaneo-sync-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state.sqlite3"
        self.config_path = Path(self.temporary.name) / "config.json"
        self.config = {
            "gitclub_url": GITCLUB, "gitclub_token": "gitclub-test-token",
            "kaneo_url": KANEO, "kaneo_api_key": "kaneo-test-key",
            "repositories": {"1": {"project_url": BOARD, "done_status": "done"}},
        }
        self.task = {"id": "task1", "projectId": "project1", "status": "in-progress", "title": "Keep this title", "description": "Keep this description"}
        self.tasks = {"task1": self.task}
        self.pulls = [{"id": 7, "repo_id": 1, "state": "merged", "kaneo_task_url": TASK}]
        self.repo_project_url = BOARD
        self.columns = [{"projectId": "project1", "slug": "done"}]
        self.calls: list[tuple[str, str, str, object]] = []
        self.failed_repos: set[str] = set()
        self.failed_tasks: set[str] = set()
        self.fail_put = False
        self.output = io.StringIO()

    def api(self, base: str, token: str, path: str, *, method: str = "GET", body: dict[str, str] | None = None) -> object:
        self.calls.append((base, path, method, body))
        self.assertEqual(token, self.config["gitclub_token"] if base == GITCLUB else self.config["kaneo_api_key"])
        if base == GITCLUB and path.startswith("/api/repos/"):
            repo_id = path.split("/")[3]
            if repo_id in self.failed_repos:
                raise sync.SyncError("HTTP 503")
            if path == f"/api/repos/{repo_id}":
                return {"repository": {"id": int(repo_id), "kaneo_project_url": self.repo_project_url}}
            feed = f"/api/repos/{repo_id}/kaneo/merges?after_id="
            if path.startswith(feed):
                after_id = int(path.removeprefix(feed))
                linked = sorted((p for p in self.pulls if p["id"] > after_id and p["state"] == "merged" and p["kaneo_task_url"]), key=lambda p: p["id"])
                return {"pulls": [{"id": p["id"], "repo_id": int(repo_id), "state": p["state"], "kaneo_task_url": p["kaneo_task_url"]} for p in linked[:100]]}
        if (base, path, method) == (KANEO, "/api/column/project1", "GET"):
            return self.columns
        if base == KANEO and path.startswith("/api/task/") and method == "GET":
            return dict(self.tasks[path.removeprefix("/api/task/")])
        if base == KANEO and path.startswith("/api/task/status/") and method == "PUT":
            self.assertEqual(body, {"status": "done"})
            task_id = path.removeprefix("/api/task/status/")
            if self.fail_put or task_id in self.failed_tasks:
                raise sync.SyncError("HTTP 503")
            self.tasks[task_id]["status"] = "done"
            return dict(self.tasks[task_id])
        raise AssertionError("Unexpected API request")

    def run_sweep(self) -> int:
        with patch.object(sync, "request_json", self.api), contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            return sync.sweep(self.config, self.state)

    def writes(self) -> list[tuple[str, str, str, object]]:
        return [call for call in self.calls if call[2] != "GET"]

    def test_merge_changes_only_status_and_does_not_reclose_after_restart(self) -> None:
        self.pulls.extend([
            {"id": 8, "repo_id": 1, "state": "open", "kaneo_task_url": TASK},
            {"id": 9, "repo_id": 1, "state": "closed", "kaneo_task_url": TASK},
            {"id": 10, "repo_id": 1, "state": "merged", "kaneo_task_url": ""},
        ])
        original = dict(self.task)
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.task, dict(original, status="done"))
        self.assertEqual(len(self.writes()), 1)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.task["status"] = "in-progress"
        self.calls.clear()
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.task["status"], "in-progress")
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(call[0] == KANEO for call in self.calls))

    def test_already_done_is_recorded_without_update(self) -> None:
        self.task["status"] = "done"
        self.assertEqual(self.run_sweep(), 0)
        self.task["status"] = "in-progress"
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.task["status"], "in-progress")

    def test_upstream_failure_is_retried_and_other_repositories_continue(self) -> None:
        self.config["repositories"]["2"] = {"project_url": BOARD, "done_status": "done"}
        self.failed_repos.add("1")
        self.assertEqual(self.run_sweep(), 1)
        self.assertEqual(len(self.writes()), 1)
        self.failed_repos.clear()
        self.task["status"] = "in-progress"
        self.fail_put = True
        self.assertEqual(self.run_sweep(), 1)
        self.fail_put = False
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.task["status"], "done")
        with contextlib.closing(sqlite3.connect(self.state)) as ledger:
            self.assertEqual(ledger.execute("SELECT count(*) FROM completed").fetchone()[0], 2)
        self.assertNotIn(self.config["gitclub_token"], self.output.getvalue())
        self.assertNotIn(self.config["kaneo_api_key"], self.output.getvalue())

    def test_foreign_project_task_and_invalid_status_are_refused(self) -> None:
        self.repo_project_url = BOARD.replace("project1", "foreign")
        self.assertEqual(self.run_sweep(), 1)
        self.assertFalse(any(call[0] == KANEO for call in self.calls))
        self.repo_project_url = BOARD
        for task_url in (TASK.replace("project1", "foreign"), TASK.replace("workspace1", "foreign"), TASK.replace(KANEO, "https://attacker.test"), TASK + "?x=1", TASK + "/../task2", TASK + "%2fother"):
            with self.subTest(task_url=task_url):
                self.pulls[0]["kaneo_task_url"] = task_url
                self.assertEqual(self.run_sweep(), 1)
        self.pulls[0]["kaneo_task_url"] = TASK
        self.task["projectId"] = "foreign"
        self.assertEqual(self.run_sweep(), 1)
        self.task["projectId"] = "project1"
        self.columns = [{"projectId": "project1", "slug": "to-do"}]
        self.assertEqual(self.run_sweep(), 1)
        self.assertEqual(self.writes(), [])

    def test_only_allowlisted_repositories_are_fetched(self) -> None:
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual([c[1] for c in self.calls if c[0] == GITCLUB], ["/api/repos/1", "/api/repos/1/kaneo/merges?after_id=0"])
        self.config["repositories"] = {}
        self.calls.clear()
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual(self.calls, [])

    def test_large_pull_bodies_use_compact_pages_and_failed_tasks_retry_on_replay(self) -> None:
        self.tasks = {f"task{i}": dict(self.task, id=f"task{i}") for i in range(1, 206)}
        self.pulls = [{"id": i, "repo_id": 1, "state": "merged", "kaneo_task_url": TASK.removesuffix("task1") + f"task{i}", "body": "x" * 65536} for i in range(1, 206)]
        self.assertGreater(len(json.dumps({"pulls": self.pulls}).encode()), sync.MAX_RESPONSE)
        expected_pages = [f"/api/repos/1/kaneo/merges?after_id={cursor}" for cursor in (0, 100, 200)]
        self.failed_tasks.add("task3")
        self.assertEqual(self.run_sweep(), 1)
        self.assertEqual([c[1] for c in self.calls if "/kaneo/merges?" in c[1]], expected_pages)
        self.assertEqual(sum(t["status"] == "done" for t in self.tasks.values()), 204)
        self.assertEqual(self.tasks["task205"]["status"], "done")

        self.failed_tasks.clear()
        self.tasks["task4"]["status"] = "in-progress"
        self.calls.clear()
        self.assertEqual(self.run_sweep(), 0)
        self.assertEqual([c[1] for c in self.calls if "/kaneo/merges?" in c[1]], expected_pages)
        self.assertEqual([c[1] for c in self.writes()], ["/api/task/status/task3"])
        self.assertEqual(self.tasks["task3"]["status"], "done")
        self.assertEqual(self.tasks["task4"]["status"], "in-progress")
        with contextlib.closing(sqlite3.connect(self.state)) as ledger:
            self.assertEqual(ledger.execute("SELECT count(*) FROM completed").fetchone()[0], 205)
        self.calls.clear()
        self.assertEqual(self.run_sweep(), 0)
        self.assertFalse(any(c[0] == KANEO for c in self.calls))

    def test_merge_feed_rejects_nonincreasing_ids_and_excess_pages(self) -> None:
        pages = [[{"id": 0}], [{"id": True}], [{"id": 2}, {"id": 1}], [{"id": i} for i in range(1, 102)]]
        for page in pages:
            with self.subTest(page_length=len(page)), patch.object(sync, "request_json", return_value={"pulls": page}):
                with self.assertRaises(sync.SyncError):
                    list(sync.merged_pulls(self.config, "1"))
        full_page = [{"id": i} for i in range(1, 101)]
        with patch.object(sync, "request_json", return_value={"pulls": full_page}) as request:
            with self.assertRaisesRegex(sync.SyncError, "increase"):
                list(sync.merged_pulls(self.config, "1"))
            self.assertEqual(request.call_count, 2)
        with patch.object(sync, "request_json", side_effect=[{"pulls": full_page}, {"pulls": []}]) as request:
            self.assertEqual(len(list(sync.merged_pulls(self.config, "1"))), 100)
            self.assertEqual(request.call_args.args[2], "/api/repos/1/kaneo/merges?after_id=100")

    def test_config_requires_private_file_and_exact_mapping_schema(self) -> None:
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o644)
        with self.assertRaises(sync.SyncError):
            sync.load_config(self.config_path)
        self.config_path.chmod(0o600)
        self.assertEqual(sync.load_config(self.config_path), self.config)
        bad_configs = []
        for key, value in (("gitclub_url", "http://gitclub.example.test"), ("kaneo_url", KANEO + "/"), ("kaneo_api_key", "key\r\nInjected: yes")):
            bad_configs.append(dict(self.config, **{key: value}))
        for key, value in (("01", {"project_url": BOARD, "done_status": "done"}), ("1", {"project_url": BOARD.replace(KANEO, "https://attacker.test"), "done_status": "done"}), ("1", {"project_url": BOARD + "?x=1", "done_status": "done"}), ("1", {"project_url": BOARD, "done_status": ""})):
            bad_configs.append(dict(self.config, repositories={key: value}))
        for config in bad_configs:
            with self.subTest(config=config):
                self.config_path.write_text(json.dumps(config))
                with self.assertRaises(sync.SyncError):
                    sync.load_config(self.config_path)

    def test_malformed_repository_response_does_not_stop_next_repository(self) -> None:
        self.config["repositories"]["2"] = copy.deepcopy(self.config["repositories"]["1"])
        def malformed(base: str, token: str, path: str, **kwargs: object) -> object:
            if path == "/api/repos/1":
                return {"unexpected": "response"}
            return self.api(base, token, path, **kwargs)
        with patch.object(sync, "request_json", malformed), contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            self.assertEqual(sync.sweep(self.config, self.state), 1)
        self.assertEqual(len(self.writes()), 1)

    def test_redirects_never_forward_credentials_and_response_size_is_bounded(self) -> None:
        received: list[tuple[str, str | None]] = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                received.append((self.path, self.headers.get("Authorization")))
                self.send_response(302 if self.path == "/api/redirect" else 200)
                if self.path == "/api/redirect":
                    self.send_header("Location", f"http://localhost:{self.server.server_port}/api/stolen")
                self.end_headers()
                if self.path == "/api/large":
                    self.wfile.write(b" " * 129)
                if self.path == "/api/repos/1/kaneo/merges?after_id=0":
                    self.wfile.write(b'{"pulls":[]}')
            def log_message(self, *args: object) -> None:
                pass
        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                with self.assertRaisesRegex(sync.SyncError, "HTTP 302"):
                    sync.request_json(base, "private-test-key", "/api/redirect")
                self.assertEqual(received, [("/api/redirect", "Bearer private-test-key")])
                self.assertEqual(sync.request_json(base, "private-test-key", "/api/repos/1/kaneo/merges?after_id=0"), {"pulls": []})
                for path in ("/api/repos/1/kaneo/merges?after_id=-1", "/api/repos/1/kaneo/merges?after_id=0&extra=1"):
                    with self.assertRaisesRegex(sync.SyncError, "Invalid API path"):
                        sync.request_json(base, "private-test-key", path)
                with patch.object(sync, "MAX_RESPONSE", 128), self.assertRaisesRegex(sync.SyncError, "exceeds"):
                    sync.request_json(base, "private-test-key", "/api/large")
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
