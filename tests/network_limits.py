#!/usr/bin/env python3
"""Verify slow JSON uploads cannot hold repository locks and expire promptly."""
import argparse
import json
from pathlib import Path
import secrets
import socket
import time
import traceback
import urllib.request
import urllib.parse
from acceptance import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--deadline-seconds", type=float, default=15, help="Upper bound including the contract's 10-second body deadline")
    args = parser.parse_args()
    report = {"url": args.url, "status": "failed", "started_at_unix": time.time()}
    connection = None
    try:
        url = urllib.parse.urlsplit(args.url)
        assert url.scheme == "http", "Run against the direct local HTTP listener"
        client = Client(args.url)
        username = "slow" + secrets.token_hex(5)
        auth = client.post("/api/auth/register", {"username": username, "password": "slow-body-" + secrets.token_hex(16)}, expect=201)
        client.token = auth["token"]
        repo = client.post("/api/repos", {"owner": username, "name": "slow-body"}, expect=201)["repository"]
        path = "/api/repos/" + str(repo["id"]) + "/issues"
        connection = socket.create_connection((url.hostname, url.port or 80), timeout=3)
        request = (f"POST {path} HTTP/1.1\r\nHost: {url.netloc}\r\nAuthorization: Bearer {client.token}\r\n"
                   "Content-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{")
        started = time.perf_counter()
        connection.sendall(request.encode())
        time.sleep(0.2)
        read_started = time.perf_counter()
        readable = urllib.request.Request(args.url.rstrip("/") + path, headers={"Authorization": "Bearer " + client.token})
        with urllib.request.urlopen(readable, timeout=1) as response:
            assert response.status == 200 and json.load(response)["issues"] == []
        report["concurrent_repository_read_ms"] = (time.perf_counter() - read_started) * 1000
        connection.settimeout(max(0.1, args.deadline_seconds - (time.perf_counter() - started)))
        response = b""
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
            response += chunk
            assert len(response) <= 65536, "Unexpectedly large slow-body error response"
        elapsed = time.perf_counter() - started
        assert elapsed <= args.deadline_seconds, f"Slow body lasted {elapsed:.3f}s"
        first_line = response.split(b"\r\n", 1)[0].decode(errors="replace")
        if first_line:
            assert first_line.split()[1] in ("400", "408"), first_line
        assert client.get(path)["issues"] == [], "Partial upload created an issue"
        report.update(status="passed", incomplete_body_closed_seconds=elapsed, response_status_line=first_line)
    except Exception as error:
        report.update(error=str(error), traceback=traceback.format_exc())
    finally:
        if connection:
            connection.close()
    report["elapsed_seconds"] = time.time() - report["started_at_unix"]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(report["status"].upper() + ": slow JSON body isolation/deadline" + (": " + report["error"] if "error" in report else ""))
    return report["status"] != "passed"


if __name__ == "__main__":
    raise SystemExit(main())
