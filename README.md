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
- Full SwiftUI dashboard, native tables and charts, a configurable value-or-usage-bar menu-bar monitor for CPU, memory, network, battery/time and fan speed, settings, capability states, and raw JSON inspector
- System, light, or dark app-specific appearance applied consistently to every MacScope window and panel
- Reviewable settings export/import for moving feature configuration between Macs while excluding scratchpads, snippets, clipboard data and retained history
- A first-run and Settings Features hub with Essentials, Windows, Battery & quiet, and Everything bundles; individual module install/remove switches; explicit energy-impact labels; filtered Utilities/Command Bar/window surfaces; and automatic shortcut registration only for installed modules. Audio and live disk activity stay required in the Dock preview.
- Typed privileged XPC contracts with code-identity checking and preflight confirmations
- A searchable macOS Features catalog with 100+ direct reversible controls, 100+ System Settings guides, runtime support states, confirmations, and exact-value undo
- A local stdio MCP server for AI agents, with redacted telemetry, 88 allowlisted actions spanning every Utility tab, live utility data, chunked screenshot/recording access, opt-in feature and utility writes, exact-value feature undo, and a live connected-client policy panel
- A Utilities workspace with native output/input switching, pinned microphone input, all-input mute, output cycling and disconnect-volume protection, CoreAudio per-app volume from 0–200%, per-app output routing, an opt-in Apple Music launch blocker, and the same mixer in the compact preview
- Full-screen/window/selection screenshots with timers, naming/date organization, optional 1x Retina downsampling, selectable post-capture Preview/reveal/pin actions, guided automatic window scrolling capture plus manual top-to-bottom segment stitching, system sharing and tokenized 1/6/24-hour local-network links with early revocation, Preview markup, floating pinned captures, Command Bar search of recent shots, dual pixel-and-PNG-file clipboard representations, and a built-in non-destructive crop/rectangle/arrow/pen/text/sticker/redaction editor with adjustable export backgrounds, undo, and direct QR content actions on both cards and editor; exact-window or display recording with pause/resume, optional system/microphone tracks, click metadata for adjustable focus-following automatic zooms, and a local last-recording editor for trim/cut/crop/compress, 0–200% audio mixing or removal, text and padded background rendering, reusable editor presets, bounded animated-GIF export, copy/reveal and confirmed copy-and-Trash; offline Vision OCR/QR, HEX/RGB/HSL/SwiftUI color sampling, recent-capture actions, and a selectable floating camera mirror that closes when you click away
- Accessibility-gated half/third/corner window layouts with restore and cross-display moves, opt-in edge snapping with a live per-display preview, Control-Option drag-anywhere movement and resizing, an opt-in green-button maximize/restore override that does not create a Space, per-app quit-on-close rules, plus a searchable app/exact-window switcher with Return-to-open, grouped app mode including regular windowless apps, adjustable opt-in live thumbnails, minimized-window entries, per-app window-only/hide rules and thumbnail privacy exclusions, and a configurable direct front-app window-cycle shortcut; optional keyboard debounce, independent mouse-wheel direction, recorded arbitrary extra-mouse-button shortcuts with per-app exclusions and Back/Forward defaults, and focus-follows-mouse
- Persistent text snippets with folders, optional global triggers and clipboard/date/time variables including custom formats, Markdown scratchpads with quiet-period clearing, pinned clipboard favorites, opt-in text/image/file history with search and sleep/lock clearing, tracking-URL cleanup, a global plain-text paste shortcut, Finder cut/rename/copied-image-to-PNG shortcuts, and a floating session shelf: drag files or folders to the screen-top drop zone, navigate to a Finder destination, then click the shelf to move them without overwriting conflicts; the full drag-in/drag-out shelf remains available by `⌃⌥S`, a radial action, or configurable screen-edge dwell
- Reviewed application and related-file uninstall-to-Trash with opt-in deeper user/system Library discovery and a Full Disk Access guide, cache/log and large-download discovery, metadata-confirmed messaging-download retention/organization with opt-in daily recoverable-Trash or collision-safe organizer automation, searchable Homebrew install/remove/update with reviewed sequential Update All, independently switchable App Store-catalog and Homebrew update sources, optional daily checks with notifications, profiled batch image conversion and animated GIF creation, local video compression plus duration-aware trim/cut/crop editing, and timed or automated native keep-awake assertions
- A searchable Command Bar window for MacScope sections, apps and exact windows, the previously active app's own Accessibility-exposed menu commands with native shortcuts, arithmetic, unit and natural-date calculations, live typed answers about this Mac's CPU/memory/battery/storage/model/macOS/uptime, captures, audio/power actions, broad System Settings panes and web addresses; it also searches emoji, acts on text selected in the previously active app, inserts snippets or clipboard text at that app's cursor when Accessibility access is available, searches only user-chosen folders through Spotlight, runs explicitly added local scripts with visible copyable output, provides pinned apps, alternate aliases, reveal, quit, confirmed force-quit and restart actions from each app result's context menu, and prepares bug/feature mail drafts only after showing the optional non-sensitive technical details
- Public IOKit brightness controls for displays that expose a writable hardware channel, plus a per-display CoreGraphics software-dimming fallback with one-click and automatic ColorSync restoration
- A configurable tabbed compact/Quick Panel—available from the menu bar, `⌃⌘V`, and when reopening from the Dock—with reorderable tabs, an optional exact-window thumbnail/activation panel plus optional Overview/Quick visibility, an always-available audio mixer and live physical-disk read/write throughput, screenshot/keep-awake actions, lock screen, Finder visibility toggles, appearance, keyboard-light settings, removable-volume eject, and confirmed Trash emptying
- A categorized global-shortcut editor with enable switches, modifier/key pickers, immediate re-registration and duplicate detection for the Command Bar, switcher, Quick Panel, radial menu, shelf and three screenshot actions
- A hold, point and release pointer-centered radial launcher on `⌃⌥Space` with independently themed, editable eight-slot Work, Media, and System profiles for apps, files, folders, web links with optional favicon fetching, configurable emitted key combinations, the Command Bar, Quick Panel, app/window switcher, captures, audio, power, lock, clipboard, storage, and Utilities actions; it includes a nested media-control wheel for play/pause, track navigation and volume, and its hotkey can also be assigned to any extra mouse button in the shortcut recorder

MCP setup, tool/resource reference, permission modes, and client examples are in
[docs/MCP_SERVER.md](docs/MCP_SERVER.md).

Deep GPU, ANE, frequency, power, and SMC readings remain marked **Restricted** until the helper is installed and approved. Missing or model-specific metrics are reported as unavailable, restricted, degraded, or unmapped; they are never replaced with invented zeroes.

Screen capture/recording, camera preview, and cross-application window layouts remain visibly permission-gated by macOS. MacScope requests those capabilities only when their controls are used and does not bypass System Settings privacy decisions.

## Build and test

```bash
swift build
swift test
./Scripts/build-app.sh
open dist/MacScope.app
```

Open `Package.swift` or `MacScope.xcworkspace` in Xcode 26 for development. The package builds the `MacScope`, `MacScopeCore`, `MacScopeHelper`, `MacScopeMCPBridge`, and `MacScopeMCPServer` targets.

The packaging script produces an ad-hoc-signed development application by default. Set `DEVELOPER_ID_APPLICATION` to a Developer ID Application identity for release signing. Notarization credentials are intentionally not stored in the repository.

For a local Developer ID release, copy `.env.example` to the ignored `.env`, add the Apple ID notarization values, install a `Developer ID Application` certificate and its private key in Keychain, then run:

```bash
./Scripts/release-local.sh --preflight
./Scripts/release-local.sh
```

The script parses only the expected `.env` keys without executing the file, validates the credentials with Apple, stores them under the `MacScopeNotary` Keychain profile, selects the matching Team ID signing identity, signs the app, verifies its Team ID, notarizes and staples it, then creates the release ZIP and SHA-256 checksum. GitHub releases accept either the existing App Store Connect API-key secrets or the three `NOTARY_*` secrets used by the local `.env`; a Developer ID certificate and private key are still required for signing.

GitHub Actions workflows build and test every push and can produce Developer ID-signed, notarized tag releases.

## Security model

The helper exports only structured telemetry and action requests. It does not accept shell fragments or arbitrary executables. Its client verifier restricts connections to validly signed MacScope executables at exact locations inside the same app bundle, and Developer ID builds require a matching Team ID. Process actions re-read process start time immediately before execution to prevent PID-reuse mistakes. Launchd actions construct fixed `/bin/launchctl` argument arrays and never delete or rewrite third-party property lists. macOS SIP and TCC failures are returned to the app without bypass attempts.

The MCP server is local stdio-only, redacts sensitive fields by default, and starts with all writes and artifact bytes disabled. It accepts only compiled catalog feature/utility IDs and typed values. Protected utilities execute in the matching signed app so macOS applies the user's existing TCC grants. Applying a feature change requires an expiring preflight token and exact confirmation, and undo refuses to overwrite a newer external preference change.
