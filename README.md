# MacScope

MacScope is a native Apple-silicon system monitor and task manager for macOS 14 and newer. It combines public Mach, BSD, libproc, Foundation, and IOKit telemetry with an optional user-approved helper for `powermetrics`, SMC, root process actions, and typed `launchctl` operations.

## Current capabilities

- Live aggregate and per-logical-core CPU usage and load averages
- VM memory, compression, cache, free memory, and swap counters
- Process CPU, memory, threads, executable paths, cumulative disk I/O, states, and PID-safe signals
- Per-interface rates, addresses, packets, and errors
- Live physical-disk read/write throughput, IOPS, interval bytes and operations, request size, service time, latency, errors, retries, cumulative driver counters, and mounted-volume capacity
- System-reported SMART health and all fields returned by `diskutil`
- LaunchAgent and LaunchDaemon discovery across user, local, and system domains
- Hardware/OS inventory and supported thermal-pressure state
- SQLite 10-second and one-minute rollups plus optional Keychain-backed AES-GCM process history
- Redacted inventory JSON and locale-independent metrics CSV exports
- Full SwiftUI dashboard, native tables and charts, menu-bar monitor, settings, capability states, and raw JSON inspector
- Typed privileged XPC contracts with code-identity checking and preflight confirmations
- A searchable macOS Features catalog with 100+ direct reversible controls, 100+ System Settings guides, runtime support states, confirmations, and exact-value undo
- A local stdio MCP server for AI agents, with redacted telemetry, searchable feature state, opt-in preflighted feature changes, exact-value undo, and a live connected-client panel

MCP setup, tool/resource reference, permission modes, and client examples are in
[docs/MCP_SERVER.md](docs/MCP_SERVER.md).

Deep GPU, ANE, frequency, power, and SMC readings remain marked **Restricted** until the helper is installed and approved. Missing or model-specific metrics are reported as unavailable, restricted, degraded, or unmapped; they are never replaced with invented zeroes.

## Build and test

```bash
swift build
swift test
./Scripts/build-app.sh
open dist/MacScope.app
```

Open `Package.swift` or `MacScope.xcworkspace` in Xcode 26 for development. The package builds the `MacScope`, `MacScopeCore`, `MacScopeHelper`, `MacScopeMCPBridge`, and `MacScopeMCPServer` targets.

The packaging script produces an ad-hoc-signed development application by default. Set `DEVELOPER_ID_APPLICATION` to a Developer ID Application identity for release signing. Notarization credentials are intentionally not stored in the repository.

GitHub Actions workflows build and test every push and can produce Developer ID-signed, notarized tag releases.

## Security model

The helper exports only structured telemetry and action requests. It does not accept shell fragments or arbitrary executables. Its client verifier restricts connections to validly signed MacScope executables at exact locations inside the same app bundle, and Developer ID builds require a matching Team ID. Process actions re-read process start time immediately before execution to prevent PID-reuse mistakes. Launchd actions construct fixed `/bin/launchctl` argument arrays and never delete or rewrite third-party property lists. macOS SIP and TCC failures are returned to the app without bypass attempts.

The MCP server is local stdio-only, redacts sensitive fields by default, and starts with feature writes disabled. It accepts only compiled catalog feature IDs and typed values; applying a change requires an expiring preflight token and exact confirmation, and undo refuses to overwrite a newer external preference change.
