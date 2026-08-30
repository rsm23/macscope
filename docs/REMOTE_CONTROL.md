# MacScope Remote Control v1

MacScope Remote is an opt-in three-part system:

```text
Expo app <-> Cloudflare Worker / EnvironmentRoom Durable Object <-> MacScope
                         |
                         +-> D1 control plane and Expo Push Service
```

The Mac opens the only long-lived connection. The relay never needs an inbound Mac port and never stores live telemetry. MacScope continues to use its existing `TelemetryEngine`; `AppModel` forwards the already-produced `SystemSnapshot` to the remote adapter only while an authorized mobile subscriber is present.

## Repository layout

- `Sources/MacScope/RemoteControlClient.swift`: outbound Mac WebSocket, Keychain identity, policy enforcement, and adapters to the existing Feature Hub, macOS feature gateway, and utility controller.
- `Sources/MacScopeMCPBridge/RemoteControl.swift`: versioned shared protocol, compact metric frame, role model, risk classification, prepare/apply policy, expiry, and replay protection.
- `Sources/MacScope/RemoteSettingsView.swift`: local enable switch, owner QR, invitations, allowlist controls, members, audit, and reset.
- `relay/`: Cloudflare Worker, D1 migration, hibernating SQLite Durable Object, Expo push delivery/receipts, and relay tests.
- `mobile/`: Expo Router application for iOS and Android.

## Deploy the relay

```bash
cd relay
pnpm install
pnpm wrangler login
pnpm wrangler d1 create macscope-remote
```

Copy the returned database ID into `relay/wrangler.toml`, replace `PUBLIC_BASE_URL` with the final `https://<worker>.<account>.workers.dev` origin, then run:

```bash
pnpm db:migrate:remote
pnpm deploy
```

If Expo push access-token security is enabled for the Expo project, add the matching relay secret:

```bash
pnpm wrangler secret put EXPO_ACCESS_TOKEN
```

For local relay work, run `pnpm db:migrate:local` followed by `pnpm dev`, then use `http://localhost:8787` in MacScope. Production pairing accepts HTTPS only.

## Configure MacScope

1. Open **Settings -> Remote control**.
2. Enter the deployed `workers.dev` URL and a recognizable Mac name.
3. Enable remote access. MacScope creates its stable environment identity and stores its secret in Keychain.
4. Leave every write category disabled until it is intentionally needed.
5. Create and scan the owner QR. Later invitations are single-use, expire after ten minutes, and can assign viewer, operator, or owner.

Disabling Remote stops all network activity. Reset Remote revokes the environment, closes live sockets, removes the Mac credential from Keychain, and requires every device to pair again.

## Configure and build the Expo app

```bash
cd mobile
pnpm install
npx eas-cli init
```

Replace `extra.eas.projectId` in `mobile/app.json` with the project ID produced by EAS. For local UI work, use `pnpm start`. Camera scanning, native notifications, and device authentication must also be checked in a development or internal build on physical devices:

```bash
npx eas-cli build --profile preview --platform android
npx eas-cli build --profile preview --platform ios
```

The preview profile produces an internally distributable Android APK. iOS device distribution and push credentials require an active Apple Developer Program membership.

## Security properties

- Long-lived Mac and mobile credentials are sent only in authorization headers and stored in Keychain or SecureStore.
- URLs contain only one-time pairing material in the fragment or a one-use, 60-second WebSocket ticket.
- Access tokens last 15 minutes; refresh tokens rotate and are revoked with their member/device.
- The relay overwrites client-supplied actor and role claims. MacScope independently rechecks role, local allowlist, known action, risk, permission, feature writability, expiry, and one-time approval.
- Every command expires after 15 seconds. Applied command IDs remain blocked for ten minutes. Offline commands fail immediately and are never retained.
- Sensitive and destructive actions require exact prepare/apply details and device authentication. macOS preference results carry a bounded undo token that uses the same authenticated flow.
- Process names, paths, clipboard data, artifacts, and command arguments are absent from metric frames, pushes, and the 30-day audit log.

## Verification

```bash
swift test
cd relay && pnpm test && pnpm check
cd ../mobile && pnpm test && pnpm check && pnpm lint
```

Before release, deploy a staging relay and repeat the end-to-end matrix on one physical iOS device and one physical Android device: pair all roles, observe one-second metrics, exercise Feature Hub and macOS prepare/apply/undo, test utility risk levels and biometric cancellation, receive a background alert, revoke a device, and prove that commands sent while the Mac is offline never execute after reconnect.
