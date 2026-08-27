# MacScope MCP server

MacScope includes a local Model Context Protocol server so AI agents can inspect the same telemetry and macOS feature catalog as the app. The server runs as a child process over standard input/output. It does not open a network port, upload telemetry, or accept arbitrary shell commands, preference domains, keys, or executable paths.

The bundled server implements MCP `2025-11-25` with the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). The newer sessionless `2026-07-28` protocol is documented by the [MCP project](https://blog.modelcontextprotocol.io/posts/2026-07-28/), but the current Swift SDK has not adopted it yet. Codex, ChatGPT desktop, Claude Code, and other clients that support local stdio MCP servers can use this server.

## Build and locate the server

Build the complete application bundle:

```bash
./Scripts/build-app.sh
```

The MCP executable is bundled at:

```text
/Applications/MacScope.app/Contents/Resources/MacScopeMCPServer
```

Use the actual location of `MacScope.app` if it is not installed in `/Applications`. In MacScope, open **Settings > Permissions > AI agent access** to copy a ready-to-use generic JSON configuration.

The same section includes **Connected MCP clients**, a live list of every client that has completed a handshake with a MacScope server process. Each row shows the client-declared name and version, server PID, protocol version, active read/write policy, and recent activity. The list refreshes every two seconds; a crashed or force-quit client disappears after its eight-second heartbeat expires.

You can also build and test the server directly:

```bash
swift build --product MacScopeMCPServer
.build/debug/MacScopeMCPServer --help
./Scripts/test-mcp-server.py
```

The standalone debug executable provides public collectors. Launch the executable inside the signed MacScope bundle to use the installed privileged helper for deep telemetry.

## Startup policies

The server is read-only and redacted when started without arguments. Access is enabled only through startup flags, so an agent cannot grant itself more access with a tool call.

| Flag | Effect |
| --- | --- |
| none | Read-only telemetry and feature state; sensitive values redacted |
| `--allow-sensitive-read` | Allows a tool call to request unredacted identifiers, addresses, usernames, commands, and paths |
| `--allow-feature-writes` | Enables the preflight/apply/undo workflow for allowlisted recommended and advanced features |
| `--allow-experimental-feature-writes` | Enables experimental feature writes and implies `--allow-feature-writes` |

Only add the permissions that the agent needs. A write-enabled server still cannot write an arbitrary `defaults` key: it can act only on an exact feature ID in MacScope's compiled catalog.

## Client configuration

### Generic JSON

Read-only and redacted:

```json
{
  "mcpServers": {
    "macscope": {
      "command": "/Applications/MacScope.app/Contents/Resources/MacScopeMCPServer",
      "args": []
    }
  }
}
```

To permit ordinary catalog feature changes, use:

```json
{
  "mcpServers": {
    "macscope": {
      "command": "/Applications/MacScope.app/Contents/Resources/MacScopeMCPServer",
      "args": ["--allow-feature-writes"]
    }
  }
}
```

### Codex and ChatGPT desktop

Codex, the IDE extension, and ChatGPT desktop share local MCP configuration. Add the default read-only server from a terminal:

```bash
codex mcp add macscope -- /Applications/MacScope.app/Contents/Resources/MacScopeMCPServer
```

For a write-enabled instance, append the server flag after the executable:

```bash
codex mcp add macscope -- /Applications/MacScope.app/Contents/Resources/MacScopeMCPServer --allow-feature-writes
```

Or add it to `~/.codex/config.toml`:

```toml
[mcp_servers.macscope]
command = "/Applications/MacScope.app/Contents/Resources/MacScopeMCPServer"
args = []
default_tools_approval_mode = "writes"
```

In ChatGPT desktop, open **Settings > MCP servers > Add server**, select **STDIO**, enter the command and optional arguments, save, then restart. The current OpenAI setup instructions are in the [official MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

### Claude Code

```bash
claude mcp add macscope -- /Applications/MacScope.app/Contents/Resources/MacScopeMCPServer
```

For project-shared configuration, use the same command with Claude Code's project scope or add the generic JSON entry to `.mcp.json`. See the [official Claude Code MCP documentation](https://docs.anthropic.com/en/docs/claude-code/mcp) for its current scope and management options.

## Tools

| Tool | Writes | Purpose |
| --- | --- | --- |
| `macscope_get_server_info` | No | Shows active startup policy and supported snapshot sections |
| `macscope_get_system_snapshot` | No | Returns selected current telemetry sections |
| `macscope_get_metric_history` | No | Returns recent in-process snapshots, newest last |
| `macscope_list_macos_features` | No | Searches and filters the full feature catalog and live states |
| `macscope_get_macos_feature` | No | Returns one exact feature and its current state |
| `macscope_prepare_macos_feature_change` | No | Preflights an allowlisted change and returns an expiring confirmation token |
| `macscope_apply_macos_feature_change` | Yes | Rechecks and applies exactly the preflighted change |
| `macscope_undo_macos_feature_change` | Yes | Restores the exact prior preference value if it has not changed again |

### Telemetry queries

`macscope_get_system_snapshot` and `macscope_get_metric_history` accept:

- `sections`: any combination of `summary`, `cpu`, `memory`, `battery`, `network`, `storage`, `processes`, `startup`, `hardware`, `thermals`, `accelerators`, `metrics`, or `all`.
- `process_limit`: maximum process rows, from 0 through 5,000. The default is 250.
- `process_query`: optional case-insensitive process name, executable path, or PID filter.
- `include_sensitive`: requests unredacted data. It is rejected unless the server was started with `--allow-sensitive-read`.
- `limit`: history sample count from 1 through 300, on the history tool only.

Every snapshot reports whether it was redacted, when it was sampled, total and returned collection counts, and each collector's availability/detail data. Unsupported or restricted measurements stay labeled as such; the server never substitutes invented values.

### Feature queries

`macscope_list_macos_features` can filter by free-text `query`, `category`, safety `tier`, effective `state`, `availability`, and result `limit`. Use the returned feature ID for all other feature tools. Manual System Settings guides and protected/restricted features are readable but not writable through MCP.

## Safe feature-change workflow

Feature writes deliberately require separate calls:

1. Call `macscope_get_macos_feature` and inspect the current state, mechanism, provenance, and restart effect.
2. Call `macscope_prepare_macos_feature_change` with the exact `id` and desired `enabled` value.
3. Present the returned target, current state, requested state, domain, key, and restart effect to the user.
4. Call `macscope_apply_macos_feature_change` with the one-time `approval_token` and the exact returned confirmation, such as `APPLY finder.show-hidden-files ENABLE`.
5. Keep the returned `undo_token` and `undoConfirmation` if reversal may be needed.
6. Call `macscope_undo_macos_feature_change` before expiry to restore the exact previous stored value.

Approvals expire after two minutes and undo tokens after ten minutes. Both are memory-only and disappear when the server exits. Apply rechecks the value observed during preflight. Undo also refuses to overwrite a preference that changed after the MCP operation.

## Resources

| URI | Content |
| --- | --- |
| `macscope://server/info` | Active server capability policy |
| `macscope://telemetry/summary` | Compact current system summary |
| `macscope://telemetry/snapshot` | Complete redacted snapshot, with bounded processes |
| `macscope://hardware/inventory` | Redacted hardware and OS inventory |
| `macscope://macos/features` | Complete feature catalog and live state |

Resources are read-only JSON. Use tools when you need query parameters, unredacted access, or a feature operation.

## Security and privacy

- The transport is local stdio. No listener or cloud telemetry is created.
- The connected-client registry stores only handshake identity, server PID, permission policy, and timestamps in `~/Library/Application Support/MacScope/mcp-sessions`. It never records prompts, tool arguments, or returned telemetry. Session files use owner-only permissions and are removed on disconnect or stale-heartbeat cleanup.
- MCP client names and versions are self-declared handshake metadata. They are useful for visibility but are not a cryptographic identity claim.
- Sensitive reads and all writes are disabled by default.
- Redaction covers addresses, usernames, serial numbers, UUIDs, commands, arguments, executable/source paths, mount points, and other identifying fields.
- The privileged helper accepts only validly signed MacScope executables at their exact paths inside the same application bundle. Developer ID builds must also share the helper's Team ID.
- No MCP input is passed to a shell. Feature writes use typed values and compiled domain/key allowlists.
- The feature workflow uses one-time expiring tokens, exact confirmations, stale-state checks, and exact-value undo.
- SIP, TCC, operating-system restrictions, unsupported hardware counters, and unavailable permissions are reported instead of bypassed.

The MCP host can add its own approval policy. For Codex, `default_tools_approval_mode = "writes"` is a useful extra boundary because MacScope marks mutation tools as non-read-only.

## Troubleshooting

**The client cannot start the server**

Confirm the configured path, that the app has not moved, and that the binary is executable:

```bash
test -x /Applications/MacScope.app/Contents/Resources/MacScopeMCPServer
/Applications/MacScope.app/Contents/Resources/MacScopeMCPServer --version
```

**Deep telemetry is restricted**

Open **MacScope > Settings > Permissions**, install/approve the privileged helper, then run **Check Helper**. If the helper was installed by a MacScope build from before MCP support, remove and reinstall it once so the running helper recognizes the signed MCP sibling. Restart the MCP client so it launches the server from the current signed app bundle.

**A sensitive request is rejected**

This is expected unless `--allow-sensitive-read` was configured when the server process started. Restart the MCP client after changing the server arguments.

**A feature write is rejected**

Check `macscope_get_server_info`, the feature's availability and tier, and whether the approval expired or the preference changed after preflight. Experimental entries require their separate startup flag. Manual and protected entries are intentionally read-only.

**The server emits no JSON on stdout**

The server waits for an MCP client handshake; it is not an interactive command-line shell. Use `./Scripts/test-mcp-server.py` for a protocol smoke test.
