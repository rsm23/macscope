#!/usr/bin/env python3
"""Black-box MCP stdio smoke test for the native MacScope server."""

from __future__ import annotations

import argparse
import base64
import json
import selectors
import subprocess
import sys
import time
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
    parser.add_argument("--server-arg", action="append", default=[], help="Argument passed to the MCP server process")
    parser.add_argument("--live-utilities", action="store_true", help="Exercise the bundled server against a running matching MacScope.app")
    parser.add_argument("--capture-test-artifact", action="store_true", help="Create a full-screen capture through MCP and verify its PNG bytes")
    args = parser.parse_args()
    server_path = args.server.resolve()
    if not server_path.is_file():
        raise SystemExit(f"Server executable not found: {server_path}")

    process = MCPProcess([str(server_path), *args.server_arg])
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
        expected_policy = {
            "artifactReads": "--allow-artifact-read" in args.server_arg,
            "experimentalFeatureWrites": "--allow-experimental-feature-writes" in args.server_arg,
            "featureWrites": "--allow-feature-writes" in args.server_arg or "--allow-experimental-feature-writes" in args.server_arg,
            "sensitiveReads": "--allow-sensitive-read" in args.server_arg,
            "utilityWrites": "--allow-utility-writes" in args.server_arg,
        }
        assert registered_session["policy"] == expected_policy

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
            "macscope_list_utilities",
            "macscope_get_utility_state",
            "macscope_run_utility",
            "macscope_list_artifacts",
            "macscope_read_artifact",
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
            "macscope://utilities/catalog",
            "macscope://artifacts",
        }

        info = tool_call(process, "macscope_get_server_info", {})
        assert info["isError"] is False
        assert info["structuredContent"]["featureWritesEnabled"] is expected_policy["featureWrites"]
        assert info["structuredContent"]["sensitiveReadsEnabled"] is expected_policy["sensitiveReads"]
        assert info["structuredContent"]["utilityWritesEnabled"] is expected_policy["utilityWrites"]
        assert info["structuredContent"]["artifactReadsEnabled"] is expected_policy["artifactReads"]
        assert info["structuredContent"]["utilityActionCount"] >= 75

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

        if not expected_policy["sensitiveReads"]:
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

        utilities = tool_call(process, "macscope_list_utilities", {})
        assert utilities["isError"] is False
        assert utilities["structuredContent"]["count"] >= 75
        assert {item["module"] for item in utilities["structuredContent"]["actions"]} == {
            "sound", "capture", "windows", "clipboard", "notes", "maintenance", "power"
        }
        assert any(item["id"] == "capture.screenshot" for item in utilities["structuredContent"]["actions"])
        assert any(item["id"] == "capture.recording-start" for item in utilities["structuredContent"]["actions"])

        if not expected_policy["utilityWrites"]:
            utility_denied = tool_call(process, "macscope_run_utility", {"action_id": "sound.refresh"})
            assert utility_denied["isError"] is True
            assert "--allow-utility-writes" in utility_denied["content"][0]["text"]

        artifacts = tool_call(process, "macscope_list_artifacts", {"limit": 1})
        assert artifacts["isError"] is False
        if not expected_policy["artifactReads"]:
            artifact_denied = tool_call(process, "macscope_read_artifact", {"id": "missing"})
            assert artifact_denied["isError"] is True
            assert "--allow-artifact-read" in artifact_denied["content"][0]["text"]

        if args.live_utilities:
            assert expected_policy["utilityWrites"]
            sound = tool_call(process, "macscope_get_utility_state", {"module": "sound"})
            assert sound["isError"] is False
            assert "applications" in sound["structuredContent"]["state"]
            refresh = tool_call(process, "macscope_run_utility", {"action_id": "sound.refresh"})
            assert refresh["isError"] is False
            assert refresh["structuredContent"]["accepted"] is True
            if expected_policy["sensitiveReads"]:
                notes = tool_call(process, "macscope_get_utility_state", {"module": "notes", "include_sensitive": True})
                assert notes["isError"] is False
                assert "pads" in notes["structuredContent"]["state"]
            if expected_policy["artifactReads"] and artifacts["structuredContent"]["artifacts"]:
                artifact_id = artifacts["structuredContent"]["artifacts"][0]["id"]
                chunk = tool_call(process, "macscope_read_artifact", {"id": artifact_id, "length": 64})
                assert chunk["isError"] is False
                assert chunk["structuredContent"]["chunk"]["byteCount"] > 0

        if args.capture_test_artifact:
            assert args.live_utilities and expected_policy["utilityWrites"] and expected_policy["artifactReads"]
            before = tool_call(process, "macscope_list_artifacts", {"kind": "screenshot", "limit": 100})
            before_ids = {item["id"] for item in before["structuredContent"]["artifacts"]}
            capture = tool_call(
                process,
                "macscope_run_utility",
                {"action_id": "capture.screenshot", "arguments": {"mode": "full_screen", "copy_to_clipboard": False}},
            )
            assert capture["isError"] is False
            created = None
            for _ in range(40):
                time.sleep(0.25)
                current = tool_call(process, "macscope_list_artifacts", {"kind": "screenshot", "limit": 100})
                created = next((item for item in current["structuredContent"]["artifacts"] if item["id"] not in before_ids), None)
                if created is not None:
                    break
            if created is None:
                state = tool_call(process, "macscope_get_utility_state", {"module": "capture"})
                screenshot_state = state.get("structuredContent", {}).get("state", {}).get("screenshot", {})
                raise AssertionError(f"MCP screenshot did not produce an artifact: {screenshot_state}")
            chunk = tool_call(process, "macscope_read_artifact", {"id": created["id"], "length": 64})
            assert chunk["isError"] is False
            raw = base64.b64decode(chunk["structuredContent"]["chunk"]["base64"])
            assert raw.startswith(b"\x89PNG\r\n\x1a\n")

        print(
            f"MacScope MCP smoke test passed: {len(tools)} tools, "
            f"{len(resources)} resources, live connection registry, telemetry, utility catalog, artifact policy, redaction, and feature state."
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
