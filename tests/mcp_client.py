# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp==2.2.0"]
# ///
"""Validate a disposable GitClub server with the official MCP Python SDK.

Run: uv run --isolated tests/mcp_client.py http://127.0.0.1:17701 --output mcp-client.json

Creates a private repository and issue under a disposable account on the server.
Tokens are kept in memory and revoked at the end; no client configuration changes.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import json
import logging
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


def request(base: str, path: str, body: dict[str, Any] | None = None, token: str = "") -> dict[str, Any]:
    headers = {"Content-Type": "application/json", "X-GitClub-Request": "1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    with urlopen(req, timeout=20) as response:
        return json.load(response)


async def check(base: str) -> dict[str, Any]:
    result: dict[str, Any] = {"url": base, "status": "failed", "checks": []}
    token = ""
    try:
        result["implementation"] = request(base, "/health")["implementation"]
        username = "mcpcheck" + secrets.token_hex(5)
        account = request(base, "/api/auth/register", {"username": username, "password": secrets.token_urlsafe(24)})
        token = account["token"]
        async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {token}"}, timeout=30) as http:
            async with streamable_http_client(base + "/mcp", http_client=http) as (read, write):
                async with ClientSession(read, write, read_timeout_seconds=30) as client:
                    initialized = await client.initialize()
                    result["protocol_version"] = initialized.protocol_version
                    result["server_info"] = initialized.server_info.model_dump(exclude_none=True)
                    result["checks"].append("SDK initialize and initialized notification")
                    await client.send_ping()
                    result["checks"].append("SDK ping")
                    listed = await client.list_tools()
                    expected = json.loads((Path(__file__).resolve().parents[1] / "shared/mcp-tools.json").read_text())
                    names = sorted(tool.name for tool in listed.tools)
                    assert names == sorted(tool["name"] for tool in expected), "Advertised tools differ from the shared contract"
                    assert all("http" not in tool.model_dump() for tool in listed.tools), "Private HTTP mapping leaked"
                    result["tool_count"] = len(names)
                    result["tools"] = names
                    result["checks"].append("SDK list_tools matches all shared tools and omits private mappings")

                    async def call(name: str, args: dict[str, Any]) -> dict[str, Any]:
                        response = await client.call_tool(name, args)
                        assert not response.is_error, f"Tool {name} returned isError"
                        texts = [part.text for part in response.content if part.type == "text"]
                        assert len(texts) == 1, f"Tool {name} must return one JSON text block"
                        return json.loads(texts[0])

                    initial = await call("list_repositories", {})
                    assert isinstance(initial["repositories"], list)
                    repo = (await call("create_repository", {"owner": username, "name": "sdk-check", "default_branch": "trunk", "visibility": "private"}))["repository"]
                    assert repo["default_branch"] == "trunk" and repo["visibility"] == "private"
                    found = (await call("list_repositories", {"owner": username}))["repositories"]
                    assert any(item["id"] == repo["id"] for item in found)
                    retrieved = (await call("get_repository", {"repo_id": repo["id"]}))["repository"]
                    assert retrieved["full_name"] == f"{username}/sdk-check"
                    result["checks"].append("SDK creates, finds across owners, and reads a private repository")
                    await call("set_repository_pin", {"repo_id": repo["id"], "pinned": True})
                    assert (await call("get_repository", {"repo_id": repo["id"]}))["repository"]["pinned"] is True
                    result["checks"].append("SDK repository pin write persists")
                    issue = (await call("create_issue", {"repo_id": repo["id"], "title": "Official SDK interoperability", "body": "Read and write through the native MCP surface."}))["issue"]
                    await call("comment_on_issue", {"repo_id": repo["id"], "issue_id": issue["id"], "body": "MCP check: plain text <tag> and Unicode café."})
                    await call("update_issue", {"repo_id": repo["id"], "issue_id": issue["id"], "state": "closed"})
                    detail = await call("get_issue", {"repo_id": repo["id"], "issue_id": issue["id"]})
                    assert detail["issue"]["state"] == "closed"
                    assert detail["comments"][-1]["body"] == "MCP check: plain text <tag> and Unicode café."
                    result["checks"].append("SDK creates, comments on, closes, and reads an issue with exact text")
                    group = (await call("create_group", {"name": "SDK collection", "shared": True}))["group"]
                    await call("update_group", {"group_id": group["id"], "repo_ids": [repo["id"]]})
                    groups = (await call("list_groups", {}))["groups"]
                    assert any(item["id"] == group["id"] and repo["id"] in item["repo_ids"] for item in groups)
                    result["checks"].append("SDK shared group create/update/read preserves membership")
        result["status"] = "passed"
    except Exception as exc:
        def messages(error: BaseException) -> list[str]:
            if isinstance(error, BaseExceptionGroup):
                return [message for inner in error.exceptions for message in messages(inner)]
            return [f"{type(error).__name__}: {error}"]
        result["errors"] = [message.replace(token, "[redacted]") if token else message for message in messages(exc)]
    finally:
        if token:
            try:
                request(base, "/api/auth/logout", {}, token)
                result["token_revoked"] = True
            except Exception:
                result["token_revoked"] = False
                result["status"] = "failed"
                result.setdefault("errors", []).append("Disposable test token revocation failed")
    return result


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("urls", nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    report = {
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "sdk": "official modelcontextprotocol/python-sdk",
        "sdk_version": importlib.metadata.version("mcp"),
        "python_version": sys.version.split()[0],
        "scope": "SDK transport interoperability. Does not invoke Codex or Claude agents or modify their configuration.",
        "results": [await check(url.rstrip("/")) for url in args.urls],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(any(result["status"] != "passed" for result in report["results"]))


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
