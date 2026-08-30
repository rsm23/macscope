# MacScope Remote Relay

Cloudflare Worker, D1, and hibernating Durable Object relay for MacScope Remote Control. Live metrics and commands pass through the Durable Object and are not stored. D1 holds environments, pairing grants, revocable device sessions, push preferences, and 30-day command audit metadata.

## Local setup

1. Install dependencies with `pnpm install`.
2. Run `pnpm db:migrate:local`.
3. Run `pnpm dev` and set MacScope's relay URL to `http://localhost:8787`.
4. Run `pnpm test` and `pnpm check` before deployment.

## Cloudflare deployment

1. Run `pnpm wrangler login`.
2. Create the database: `pnpm wrangler d1 create macscope-remote`.
3. Replace the placeholder `database_id` in `wrangler.toml` with the returned ID.
4. Set `PUBLIC_BASE_URL` to the final `https://...workers.dev` origin.
5. Apply migrations with `pnpm db:migrate:remote`, then deploy with `pnpm deploy`.
6. Optionally set `EXPO_ACCESS_TOKEN` with `pnpm wrangler secret put EXPO_ACCESS_TOKEN` after enabling Expo push access-token security.

The relay intentionally has no public account signup. Every member arrives through a single-use, ten-minute invitation created by the Mac or an owner.

The current production endpoint is `https://macscope-remote.macscope-relay.workers.dev`; verify it with `curl https://macscope-remote.macscope-relay.workers.dev/health` after deployment.
