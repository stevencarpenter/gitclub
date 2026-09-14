#!/usr/bin/env python3
"""Repeatable localhost GitClub benchmark, using stdlib and native Git only.

Use fresh server data directories, identical hardware/build profiles, and the
same flags for both implementations. Results describe this fixture only.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import subprocess
import sys
import threading
import time
import traceback

from acceptance import Client, Suite, commit, git


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {"samples": len(ordered), "min_ms": ordered[0],
            **{f"p{p}_ms": ordered[max(0, math.ceil(p / 100 * len(ordered)) - 1)] for p in (50, 95, 99)},
            "max_ms": ordered[-1], "mean_ms": sum(ordered) / len(ordered)}


class MemorySampler:
    """Sample parent RSS and descendant RSS; sampled peaks are not OS high-water marks."""
    def __init__(self, pid):
        self.pid = pid
        self.samples = []
        self.error = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.is_set():
            try:
                output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True, timeout=5)
                processes = {int(parts[0]): (int(parts[1]), int(parts[2])) for line in output.splitlines()
                             if len(parts := line.split()) == 3}
                if self.pid not in processes:
                    raise RuntimeError("Server PID absent from process table")
                descendants = {self.pid}
                while True:
                    expanded = descendants | {pid for pid, (parent, _) in processes.items() if parent in descendants}
                    if expanded == descendants:
                        break
                    descendants = expanded
                self.samples.append({"monotonic_seconds": time.monotonic(), "server_rss_kib": processes[self.pid][1],
                                     "process_tree_rss_kib": sum(processes[pid][1] for pid in descendants),
                                     "process_count": len(descendants)})
            except Exception as error:
                self.error = str(error)
                break
            self.stop.wait(0.05)

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=6)
        return {"method": "ps sampled every 50ms plus ps execution time; RSS units KiB; not a kernel peak",
                "sampling_scope": "Measured HTTP and Git phases, after fixture setup and warmup",
                "process_tree_rss_definition": "Sum of server and descendant RSS; shared pages can be counted more than once",
                "server_pid": self.pid, "error": self.error, "samples": self.samples,
                "peak_server_rss_kib": max((s["server_rss_kib"] for s in self.samples), default=None),
                "peak_process_tree_rss_kib": max((s["process_tree_rss_kib"] for s in self.samples), default=None)}


def build_fixture(suite, repo_count):
    suite.setup()
    rng = random.Random(1729)
    payload = rng.randbytes(1024 * 1024)
    (suite.work / "payload.bin").write_bytes(payload)
    for n in range(100):
        (suite.work / "src" / f"module_{n:03}.txt").write_text((f"module {n:03}: fixed benchmark content\n") * 32)
    git(suite.work, "add", ".")
    git(suite.work, "commit", "-m", "Benchmark files")
    for n in range(18):
        commit(suite.work, "history.txt", f"revision {n:02}\n", f"History {n:02}")
    git(suite.work, "push", "origin", "trunk", "--tags", token=suite.a.token)
    git(suite.work, "checkout", "-b", "benchmark-diff")
    head = commit(suite.work, "src/module_000.txt", "reviewable benchmark change\n", "Benchmark change")
    git(suite.work, "push", "origin", "benchmark-diff", token=suite.a.token)
    for n in range(max(0, repo_count - 4)):
        suite.repo(f"benchmark-{n:03}", suite.org if n % 2 else None)
    group = suite.a.post("/api/groups", {"name": suite.prefix + " benchmark", "shared": True}, expect=201)["group"]
    suite.a.patch("/api/groups/" + str(group["id"]), {"repo_ids": [suite.r["id"], suite.other["id"]]})
    for n in range(10):
        suite.a.post(suite.path() + "/issues", {"title": f"Benchmark issue {n}", "body": "Fixed issue body."}, expect=201)
    pull = suite.a.post(suite.path() + "/pulls", {"title": "Benchmark review", "head_branch": "benchmark-diff"}, expect=201)["pull"]
    suite.b.post(suite.path() + "/pulls/" + str(pull["id"]) + "/reviews", {"decision": "approve", "expected_head_oid": head}, expect=201)
    return {"seed": 1729, "repositories": max(4, repo_count), "source_files": 100,
            "binary_payload_bytes": len(payload), "binary_payload_sha256": hashlib.sha256(payload).hexdigest(),
            "default_branch_commits": 20,
            "description": "One populated repository; all remaining repositories are empty. Populated default branch has 20 commits, 100 generated source files plus the base fixture, and a 1 MiB incompressible binary.",
            "head_oid": head, "pull_id": pull["id"], "group_id": group["id"]}


def benchmark(args):
    report = {"started_at_unix": time.time(), "url": args.url,
              "configuration": {"requests": args.requests, "concurrency": args.concurrency,
                                "warmup_requests": args.warmup, "repositories": args.repositories,
                                "git_rounds": args.git_rounds, "directory_only": args.directory_only},
              "environment": {"platform": platform.platform(), "machine": platform.machine(),
                              "cpu_count": os.cpu_count(), "python": sys.version,
                              "git": subprocess.check_output(["git", "--version"], text=True).strip(),
                              "server_version": args.server_version, "build_seconds": args.build_seconds},
              "limitations": ["Local fixture measurements do not establish uptime or production capacity.",
                              "HTTP latencies include client scheduling and connection overhead; urllib uses fresh requests.",
                              "Repository-list results include any pre-existing server data; use isolated fresh data directories."]}
    suite = Suite(args.url)
    sampler = MemorySampler(args.server_pid) if args.server_pid else None
    try:
        fixture_started = time.perf_counter()
        report["fixture"] = build_fixture(suite, args.repositories)
        actual_count = len(suite.a.get("/api/repos")["repositories"])
        assert actual_count == report["fixture"]["repositories"], "Benchmark data contaminated: accessible repository count differs from fixture"
        report["fixture"]["accessible_repository_count"] = actual_count
        report["fixture"]["directory_search_result_count"] = len(suite.a.get("/api/repos?q=benchmark")["repositories"])
        report["fixture_setup_seconds"] = time.perf_counter() - fixture_started
        report["implementation"] = suite.implementation
        print(f"Fixture ready: {actual_count} accessible repositories; {args.warmup} warmup requests", flush=True)
        p = suite.path()
        mix = [("repository_directory", "/api/repos"), ("repository_search", "/api/repos?q=benchmark"),
               ("tree", p + "/tree?ref=trunk&path=src"), ("blob", p + "/blob?ref=trunk&path=src/module_001.txt"),
               ("history", p + "/commits?ref=trunk"), ("diff", p + "/diff?base=trunk&head=benchmark-diff"),
               ("issues", p + "/issues"), ("pull_review", p + "/pulls/" + str(report["fixture"]["pull_id"])),
               ("groups", "/api/groups"), ("branches", p + "/branches")]
        if args.directory_only:
            mix = mix[:2]
        report["http_mix"] = [{"name": name, "path": path} for name, path in mix]
        report["percentile_method"] = "nearest rank: sorted[ceil(p * sample_count) - 1]"
        for index in range(args.warmup):
            suite.a.get(mix[index % len(mix)][1])
        if sampler:
            sampler.thread.start()

        def request_one(index):
            name, path = mix[index % len(mix)]
            started = time.perf_counter()
            error = None
            try:
                Client(args.url, suite.a.token).get(path)
            except Exception as failure:
                error = str(failure)
            return {"index": index, "operation": name, "elapsed_ms": (time.perf_counter() - started) * 1000,
                    "error": error}

        started = time.perf_counter()
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            requests = list(pool.map(request_one, range(args.requests)))
        elapsed = time.perf_counter() - started
        report["http"] = {"elapsed_seconds": elapsed, "requests_per_second": len(requests) / elapsed,
                          "errors": sum(r["error"] is not None for r in requests), "raw_samples": requests,
                          "latency": percentiles([r["elapsed_ms"] for r in requests if r["error"] is None]),
                          "by_operation": {name: percentiles([r["elapsed_ms"] for r in requests
                                                              if r["operation"] == name and r["error"] is None]) for name, _ in mix}}
        report["git"] = {"raw_samples": []}
        for index in range(args.git_rounds):
            started = time.perf_counter()
            git(suite.root, "clone", suite.remote(), str(suite.root / f"benchmark-clone-{index}"), token=suite.a.token)
            report["git"]["raw_samples"].append({"operation": "clone", "index": index,
                                                "elapsed_ms": (time.perf_counter() - started) * 1000})
            oid = commit(suite.work, "push.txt", f"push {index}\n", f"Benchmark push {index}")
            started = time.perf_counter()
            git(suite.work, "push", "origin", "benchmark-diff", token=suite.a.token)
            report["git"]["raw_samples"].append({"operation": "push", "index": index, "oid": oid,
                                                "elapsed_ms": (time.perf_counter() - started) * 1000})
        report["git"]["latency"] = {operation: percentiles([s["elapsed_ms"] for s in report["git"]["raw_samples"]
                                                            if s["operation"] == operation]) for operation in ("clone", "push")}
    except Exception as error:
        report["fatal_error"] = str(error)
        report["traceback"] = traceback.format_exc()
    finally:
        report["memory"] = sampler.finish() if sampler and sampler.thread.ident else {
            "unavailable": "Supply --server-pid for local sampled server/process-tree RSS" if not sampler else "Fixture failed before sampling"}
        suite.temp.cleanup()
    report["elapsed_seconds"] = time.time() - report["started_at_unix"]
    return report


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--requests", type=positive, default=400)
    parser.add_argument("--directory-only", action="store_true", help="Measure repository directory and search only, for large repository-count probes")
    parser.add_argument("--concurrency", type=positive, default=4)
    parser.add_argument("--warmup", type=positive, default=40)
    parser.add_argument("--repositories", type=positive, default=40)
    parser.add_argument("--git-rounds", type=positive, default=5)
    parser.add_argument("--server-pid", type=positive)
    parser.add_argument("--server-version", help="Exact server toolchain/build description supplied by operator")
    parser.add_argument("--build-seconds", type=float, help="Measured release build elapsed seconds")
    args = parser.parse_args()
    report = benchmark(args)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    if "fatal_error" in report:
        print("FAILED: " + report["fatal_error"])
        return 1
    print(json.dumps({"implementation": report["implementation"], "http": report["http"]["latency"],
                      "http_errors": report["http"]["errors"], "git": report["git"]["latency"],
                      "report": str(args.report)}, indent=2))
    return bool(report["http"]["errors"])


if __name__ == "__main__":
    raise SystemExit(main())
