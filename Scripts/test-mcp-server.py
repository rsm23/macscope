#!/usr/bin/env python3
"""Black-box MCP stdio smoke test for the native MacScope server."""

from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import sys
from pathlib import Path
from typing import Any


class MCPProcess:
    def __init__(self, command: list[str]) -> None:
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)
        response = self._read(timeout=15)
        if response.get("id") != request_id:
            raise AssertionError(f"Expected response id {request_id}, received {response!r}")
        if "error" in response:
            raise AssertionError(f"MCP request {method} failed: {response['error']!r}")
        return response["result"]

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            return_code = self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            return_code = self.process.wait(timeout=5)
        stderr = self.process.stderr.read() if self.process.stderr else ""
        if return_code not in (0, -15):
            raise AssertionError(f"Server exited with {return_code}: {stderr}")

    def _write(self, payload: dict[str, Any]) -> None:
        if not self.process.stdin:
            raise AssertionError("MCP server stdin is unavailable")
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _read(self, timeout: float) -> dict[str, Any]:
        if not self.process.stdout:
            raise AssertionError("MCP server stdout is unavailable")
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout):
            stderr = self.process.stderr.read(4096) if self.process.stderr else ""
            raise TimeoutError(f"Timed out waiting for MCP response. stderr={stderr!r}")
        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"MCP server closed stdout. stderr={stderr!r}")
        return json.loads(line)


def tool_call(process: MCPProcess, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    return process.request("tools/call", {"name": name, "arguments": arguments})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--server",
        type=Path,
        default=Path(".build/debug/MacScopeMCPServer"),
        help="Path to the MacScopeMCPServer executable",
    )
    args = parser.parse_args()
    server_path = args.server.resolve()
    if not server_path.is_file():
        raise SystemExit(f"Server executable not found: {server_path}")

    process = MCPProcess([str(server_path)])
    session_path: Path | None = None
    try:
        initialized = process.request(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "MacScope protocol test", "version": "1.0.0"},
            },
        )
        assert initialized["protocolVersion"] == "2025-11-25"
        assert initialized["serverInfo"]["name"] == "MacScope"
        assert "tools" in initialized["capabilities"]
        assert "resources" in initialized["capabilities"]
        process.notify("notifications/initialized", {})

        registry_directory = Path.home() / "Library" / "Application Support" / "MacScope" / "mcp-sessions"
        registered_sessions = []
        if registry_directory.is_dir():
            for candidate in registry_directory.glob("*.json"):
                try:
                    session = json.loads(candidate.read_text())
                except (OSError, json.JSONDecodeError):
                    continue
                if session.get("serverPID") == process.process.pid:
                    registered_sessions.append((candidate, session))
        assert len(registered_sessions) == 1
        session_path, registered_session = registered_sessions[0]
        assert registered_session["clientName"] == "MacScope protocol test"
        assert registered_session["clientVersion"] == "1.0.0"
        assert registered_session["policy"] == {
            "experimentalFeatureWrites": False,
            "featureWrites": False,
            "sensitiveReads": False,
        }

        tools = process.request("tools/list", {})["tools"]
        names = {tool["name"] for tool in tools}
        expected_tools = {
            "macscope_get_server_info",
            "macscope_get_system_snapshot",
            "macscope_get_metric_history",
            "macscope_list_macos_features",
            "macscope_get_macos_feature",
            "macscope_prepare_macos_feature_change",
            "macscope_apply_macos_feature_change",
            "macscope_undo_macos_feature_change",
        }
        assert names == expected_tools
        assert all(tool["inputSchema"]["type"] == "object" for tool in tools)

        resources = process.request("resources/list", {})["resources"]
        assert {item["uri"] for item in resources} == {
            "macscope://server/info",
            "macscope://telemetry/summary",
            "macscope://telemetry/snapshot",
            "macscope://hardware/inventory",
            "macscope://macos/features",
        }

        info = tool_call(process, "macscope_get_server_info", {})
        assert info["isError"] is False
        assert info["structuredContent"]["featureWritesEnabled"] is False
        assert info["structuredContent"]["sensitiveReadsEnabled"] is False

        snapshot = tool_call(
            process,
            "macscope_get_system_snapshot",
            {"sections": ["summary", "cpu", "thermals"], "process_limit": 10},
        )
        assert snapshot["isError"] is False
        structured = snapshot["structuredContent"]
        assert structured["redacted"] is True
        assert structured["data"]["summary"]["cpuUsage"] >= 0
        assert structured["data"]["cpu"]["cores"]
        assert "availability" in structured["data"]["thermals"]

        denied = tool_call(
            process,
            "macscope_get_system_snapshot",
            {"sections": ["all"], "include_sensitive": True},
        )
        assert denied["isError"] is True
        assert "--allow-sensitive-read" in denied["content"][0]["text"]

        feature_list = tool_call(process, "macscope_list_macos_features", {"limit": 5})
        assert feature_list["isError"] is False
        assert feature_list["structuredContent"]["total"] >= 100
        assert len(feature_list["structuredContent"]["features"]) == 5

        feature_resource = process.request(
            "resources/read", {"uri": "macscope://macos/features"}
        )
        resource_json = json.loads(feature_resource["contents"][0]["text"])
        assert resource_json["total"] >= 100

        print(
            f"MacScope MCP smoke test passed: {len(tools)} tools, "
            f"{len(resources)} resources, live connection registry, telemetry, redaction, and feature state."
        )
        return 0
    finally:
        process.close()
        if session_path is not None and session_path.exists():
            raise AssertionError(f"MCP session was not removed after disconnect: {session_path}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, TimeoutError) as error:
        print(f"MCP smoke test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
