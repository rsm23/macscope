import { DurableObject } from "cloudflare:workers";
import { randomToken, tokenHash } from "./crypto";
import {
  MAX_MESSAGE_BYTES,
  ProtocolError,
  authorizeMobileEnvelope,
  canManage,
  parseEnvelope,
  type ClientKind,
  type RemoteRisk,
  type RemoteRole,
  type SocketIdentity,
  type WireEnvelope,
} from "./protocol";

interface Env {
  DB: D1Database;
  ROOMS: DurableObjectNamespace<EnvironmentRoom>;
  PUBLIC_BASE_URL: string;
  EXPO_ACCESS_TOKEN?: string;
}

interface Principal {
  environmentID: string;
  principalID: string;
  clientKind: ClientKind;
  role: RemoteRole;
  displayName: string;
}

interface PairingRow {
  id: string;
  environment_id: string;
  role: RemoteRole;
  expires_at: string;
  used_at: string | null;
}

interface SessionRow {
  id: string;
  member_id: string;
  device_id: string;
  environment_id: string;
  role: RemoteRole;
  display_name: string;
  access_expires_at: string;
  refresh_expires_at: string;
  revoked_at: string | null;
}

interface TicketRow {
  id: string;
  environment_id: string;
  principal_id: string;
  client_kind: ClientKind;
  role: RemoteRole;
  expires_at: string;
  used_at: string | null;
}

interface PendingCommand {
  commandID: string;
  memberID: string;
  actionID: string;
  risk: RemoteRisk;
  expiresAt: string;
}

const json = (value: unknown, status = 200): Response =>
  Response.json(value, { status, headers: { "cache-control": "no-store" } });

const errorResponse = (status: number, code: string, message: string): Response => json({ code, message }, status);

const isoAfter = (seconds: number): string => new Date(Date.now() + seconds * 1000).toISOString();

async function body<T>(request: Request): Promise<T> {
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > MAX_MESSAGE_BYTES) throw new ProtocolError("payload_too_large", "Request body is too large.");
  return (await request.json()) as T;
}

function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : null;
}

async function authenticate(env: Env, request: Request, expectedEnvironment?: string): Promise<Principal | null> {
  const token = bearer(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  const environment = await env.DB.prepare(
    "SELECT id, mac_name FROM environments WHERE secret_hash = ? AND deleted_at IS NULL",
  )
    .bind(hash)
    .first<{ id: string; mac_name: string }>();
  if (environment && (!expectedEnvironment || environment.id === expectedEnvironment)) {
    return {
      environmentID: environment.id,
      principalID: environment.id,
      clientKind: "mac",
      role: "owner",
      displayName: environment.mac_name,
    };
  }
  const session = await env.DB.prepare(
    `SELECT s.id, s.member_id, s.device_id, s.access_expires_at, s.refresh_expires_at, s.revoked_at,
            m.environment_id, m.role, m.display_name
       FROM sessions s
       JOIN members m ON m.id = s.member_id
       JOIN environments e ON e.id = m.environment_id
      WHERE s.access_hash = ? AND e.deleted_at IS NULL`,
  )
    .bind(hash)
    .first<SessionRow>();
  if (
    !session ||
    session.revoked_at ||
    new Date(session.access_expires_at).getTime() <= Date.now() ||
    (expectedEnvironment && session.environment_id !== expectedEnvironment)
  ) {
    return null;
  }
  const now = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare("UPDATE sessions SET last_seen_at = ? WHERE id = ?").bind(now, session.id),
    env.DB.prepare("UPDATE members SET last_seen_at = ? WHERE id = ?").bind(now, session.member_id),
    env.DB.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").bind(now, session.device_id),
  ]);
  return {
    environmentID: session.environment_id,
    principalID: session.member_id,
    clientKind: "mobile",
    role: session.role,
    displayName: session.display_name,
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      const segments = url.pathname.split("/").filter(Boolean);

      if (request.method === "GET" && url.pathname === "/health") {
        return json({ ok: true, protocolVersion: 1 });
      }

      if (request.method === "POST" && url.pathname === "/v1/environments/register") {
        const input = await body<{ macName?: string; appVersion?: string }>(request);
        const environmentID = crypto.randomUUID();
        const environmentSecret = randomToken();
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT INTO environments(id, mac_name, app_version, secret_hash, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?)`,
        )
          .bind(
            environmentID,
            bounded(input.macName, "My Mac"),
            bounded(input.appVersion, "development"),
            await tokenHash(environmentSecret),
            now,
            now,
          )
          .run();
        const pairing = await createPairing(env, environmentID, "owner");
        return json({
          environmentID,
          environmentSecret,
          pairingURL: `${env.PUBLIC_BASE_URL}/pair#token=${pairing.token}`,
          pairingExpiresAt: pairing.expiresAt,
        }, 201);
      }

      if (request.method === "POST" && url.pathname === "/v1/pairings/redeem") {
        const input = await body<{
          pairingToken?: string;
          displayName?: string;
          deviceName?: string;
          platform?: string;
          pushToken?: string;
        }>(request);
        if (!input.pairingToken) return errorResponse(400, "missing_pairing_token", "A pairing token is required.");
        const now = new Date().toISOString();
        const pairing = await env.DB.prepare(
          `UPDATE pairings SET used_at = ?
            WHERE token_hash = ? AND used_at IS NULL AND expires_at > ?
              AND EXISTS (SELECT 1 FROM environments e WHERE e.id = pairings.environment_id AND e.deleted_at IS NULL)
            RETURNING id, environment_id, role, expires_at, used_at`,
        )
          .bind(now, await tokenHash(input.pairingToken), now)
          .first<PairingRow>();
        if (!pairing) {
          return errorResponse(410, "expired_pairing", "This pairing link is expired or already used.");
        }
        const memberID = crypto.randomUUID();
        const deviceID = crypto.randomUUID();
        const sessionID = crypto.randomUUID();
        const accessToken = randomToken();
        const refreshToken = randomToken();
        const accessExpiresAt = isoAfter(15 * 60);
        const refreshExpiresAt = isoAfter(90 * 24 * 60 * 60);
        const platform = input.platform === "ios" || input.platform === "android" ? input.platform : "unknown";
        await env.DB.batch([
          env.DB.prepare(
            "INSERT INTO members(id, environment_id, display_name, role, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)",
          ).bind(memberID, pairing.environment_id, bounded(input.displayName, "Mobile member"), pairing.role, now, now),
          env.DB.prepare(
            `INSERT INTO devices(id, member_id, device_name, platform, push_token, created_at, last_seen_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
          ).bind(deviceID, memberID, bounded(input.deviceName, "Mobile device"), platform, input.pushToken ?? null, now, now),
          env.DB.prepare(
            `INSERT INTO sessions(id, member_id, device_id, access_hash, access_expires_at, refresh_hash, refresh_expires_at, created_at, last_seen_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          ).bind(
            sessionID,
            memberID,
            deviceID,
            await tokenHash(accessToken),
            accessExpiresAt,
            await tokenHash(refreshToken),
            refreshExpiresAt,
            now,
            now,
          ),
        ]);
        return json({
          environmentID: pairing.environment_id,
          memberID,
          deviceID,
          role: pairing.role,
          accessToken,
          accessExpiresAt,
          refreshToken,
          refreshExpiresAt,
        }, 201);
      }

      if (request.method === "POST" && url.pathname === "/v1/sessions/refresh") {
        const token = bearer(request);
        if (!token) return errorResponse(401, "unauthorized", "A refresh token is required.");
        const hash = await tokenHash(token);
        const session = await env.DB.prepare(
          `SELECT s.id, s.member_id, s.device_id, s.access_expires_at, s.refresh_expires_at, s.revoked_at,
                  m.environment_id, m.role, m.display_name
             FROM sessions s
             JOIN members m ON m.id = s.member_id
             JOIN environments e ON e.id = m.environment_id
            WHERE s.refresh_hash = ? AND e.deleted_at IS NULL`,
        )
          .bind(hash)
          .first<SessionRow>();
        if (!session || session.revoked_at || new Date(session.refresh_expires_at).getTime() <= Date.now()) {
          return errorResponse(401, "invalid_refresh", "The refresh session is expired or revoked.");
        }
        const accessToken = randomToken();
        const refreshToken = randomToken();
        const accessExpiresAt = isoAfter(15 * 60);
        const refreshed = await env.DB.prepare(
          `UPDATE sessions
              SET access_hash = ?, access_expires_at = ?, refresh_hash = ?, last_seen_at = ?
            WHERE id = ? AND refresh_hash = ? AND revoked_at IS NULL`,
        )
          .bind(
            await tokenHash(accessToken),
            accessExpiresAt,
            await tokenHash(refreshToken),
            new Date().toISOString(),
            session.id,
            hash,
          )
          .run();
        if (refreshed.meta.changes !== 1) {
          return errorResponse(401, "refresh_reused", "This refresh token was already rotated.");
        }
        return json({ accessToken, accessExpiresAt, refreshToken, refreshExpiresAt: session.refresh_expires_at });
      }

      if (request.method === "POST" && url.pathname === "/v1/ws-ticket") {
        const input = await body<{ environmentID?: string; clientKind?: ClientKind }>(request);
        if (!input.environmentID) return errorResponse(400, "missing_environment", "environmentID is required.");
        const principal = await authenticate(env, request, input.environmentID);
        if (!principal || principal.clientKind !== input.clientKind) {
          return errorResponse(401, "unauthorized", "The session cannot open this socket kind.");
        }
        const token = randomToken();
        const expiresAt = isoAfter(60);
        await env.DB.prepare(
          `INSERT INTO websocket_tickets(id, token_hash, environment_id, principal_id, client_kind, role, expires_at, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
          .bind(
            crypto.randomUUID(),
            await tokenHash(token),
            principal.environmentID,
            principal.principalID,
            principal.clientKind,
            principal.role,
            expiresAt,
            new Date().toISOString(),
          )
          .run();
        return json({ ticket: token, expiresAt });
      }

      if (request.method === "GET" && url.pathname === "/v1/socket") {
        if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
          return errorResponse(426, "upgrade_required", "Use a WebSocket upgrade request.");
        }
        const ticketToken = url.searchParams.get("ticket");
        if (!ticketToken) return errorResponse(401, "missing_ticket", "A short-lived WebSocket ticket is required.");
        const now = new Date().toISOString();
        const ticket = await env.DB.prepare(
          `UPDATE websocket_tickets SET used_at = ?
            WHERE token_hash = ? AND used_at IS NULL AND expires_at > ?
            RETURNING id, environment_id, principal_id, client_kind, role, expires_at, used_at`,
        )
          .bind(now, await tokenHash(ticketToken), now)
          .first<TicketRow>();
        if (!ticket) {
          return errorResponse(401, "invalid_ticket", "The WebSocket ticket is expired or already used.");
        }
        const stub = env.ROOMS.get(env.ROOMS.idFromName(ticket.environment_id));
        const internal = new Request(request);
        internal.headers.set("x-macscope-environment", ticket.environment_id);
        internal.headers.set("x-macscope-principal", ticket.principal_id);
        internal.headers.set("x-macscope-client-kind", ticket.client_kind);
        internal.headers.set("x-macscope-role", ticket.role);
        return stub.fetch(internal);
      }

      if (segments[0] === "v1" && segments[1] === "environments" && segments[2]) {
        const environmentID = segments[2];
        const principal = await authenticate(env, request, environmentID);
        if (!principal) return errorResponse(401, "unauthorized", "A valid environment or member session is required.");

        if (request.method === "GET" && segments.length === 3) {
          if (!canManage(principal.role)) return errorResponse(403, "role_denied", "Only owners can inspect access.");
          const members = await env.DB.prepare(
            `SELECT m.id, m.display_name AS displayName, m.role, COUNT(d.id) AS deviceCount, m.last_seen_at AS lastSeenAt
               FROM members m LEFT JOIN devices d ON d.member_id = m.id
              WHERE m.environment_id = ? GROUP BY m.id ORDER BY m.created_at`,
          ).bind(environmentID).all();
          const audit = await env.DB.prepare(
            `SELECT id, actor_name AS actorName, action_id AS actionID, risk, outcome, created_at AS createdAt
               FROM audit_events WHERE environment_id = ? ORDER BY created_at DESC LIMIT 100`,
          ).bind(environmentID).all();
          return json({ members: members.results, audit: audit.results });
        }

        if (request.method === "POST" && segments[3] === "pairings") {
          if (!canManage(principal.role)) return errorResponse(403, "role_denied", "Only owners can invite members.");
          const input = await body<{ role?: RemoteRole }>(request);
          const role: RemoteRole = input.role === "viewer" || input.role === "operator" || input.role === "owner" ? input.role : "viewer";
          const pairing = await createPairing(env, environmentID, role);
          return json({ pairingURL: `${env.PUBLIC_BASE_URL}/pair#token=${pairing.token}`, expiresAt: pairing.expiresAt }, 201);
        }

        if (request.method === "PUT" && segments[3] === "notifications") {
          if (!canManage(principal.role)) return errorResponse(403, "role_denied", "Only owners can set notification policy.");
          const input = await body<{ alerts?: boolean; presence?: boolean; commands?: boolean }>(request);
          await env.DB.prepare(
            "UPDATE environments SET push_alerts = ?, push_presence = ?, push_commands = ?, updated_at = ? WHERE id = ?",
          ).bind(
            input.alerts === false ? 0 : 1,
            input.presence === false ? 0 : 1,
            input.commands === false ? 0 : 1,
            new Date().toISOString(),
            environmentID,
          ).run();
          return new Response(null, { status: 204 });
        }

        if (request.method === "DELETE" && segments[3] === "members" && segments[4]) {
          if (!canManage(principal.role)) return errorResponse(403, "role_denied", "Only owners can revoke members.");
          const memberID = segments[4];
          await env.DB.prepare("DELETE FROM members WHERE id = ? AND environment_id = ?").bind(memberID, environmentID).run();
          const stub = env.ROOMS.get(env.ROOMS.idFromName(environmentID));
          await stub.fetch(`https://room.internal/revoke?principal=${encodeURIComponent(memberID)}`, { method: "POST" });
          return new Response(null, { status: 204 });
        }

        if (request.method === "DELETE" && segments.length === 3) {
          if (!canManage(principal.role)) return errorResponse(403, "role_denied", "Only owners can reset remote access.");
          await env.DB.batch([
            env.DB.prepare("UPDATE environments SET deleted_at = ? WHERE id = ?").bind(new Date().toISOString(), environmentID),
            env.DB.prepare("DELETE FROM pairings WHERE environment_id = ?").bind(environmentID),
            env.DB.prepare("DELETE FROM members WHERE environment_id = ?").bind(environmentID),
          ]);
          const stub = env.ROOMS.get(env.ROOMS.idFromName(environmentID));
          await stub.fetch("https://room.internal/reset", { method: "POST" });
          return new Response(null, { status: 204 });
        }
      }

      if (request.method === "PUT" && url.pathname === "/v1/devices/push") {
        const principal = await authenticate(env, request);
        if (!principal || principal.clientKind !== "mobile") return errorResponse(401, "unauthorized", "A mobile session is required.");
        const input = await body<{
          pushToken?: string;
          notifyAlerts?: boolean;
          notifyPresence?: boolean;
          notifyCommands?: boolean;
        }>(request);
        const token = bearer(request)!;
        const session = await env.DB.prepare("SELECT device_id FROM sessions WHERE access_hash = ? AND revoked_at IS NULL")
          .bind(await tokenHash(token))
          .first<{ device_id: string }>();
        if (!session) return errorResponse(401, "unauthorized", "The device session is unavailable.");
        await env.DB.prepare(
          `UPDATE devices SET push_token = ?, notify_alerts = ?, notify_presence = ?, notify_commands = ? WHERE id = ?`,
        )
          .bind(
            input.pushToken ?? null,
            input.notifyAlerts === false ? 0 : 1,
            input.notifyPresence === false ? 0 : 1,
            input.notifyCommands === false ? 0 : 1,
            session.device_id,
          )
          .run();
        return new Response(null, { status: 204 });
      }

      return errorResponse(404, "not_found", "Route not found.");
    } catch (error) {
      if (error instanceof ProtocolError) return errorResponse(400, error.code, error.message);
      console.error(error);
      return errorResponse(500, "internal_error", "The relay could not complete the request.");
    }
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const now = new Date().toISOString();
    const auditCutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    await env.DB.batch([
      env.DB.prepare("DELETE FROM websocket_tickets WHERE expires_at < ? OR used_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM pairings WHERE expires_at < ? OR used_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM audit_events WHERE created_at < ?").bind(auditCutoff),
      env.DB.prepare("DELETE FROM sessions WHERE refresh_expires_at < ? OR revoked_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM push_tickets WHERE created_at < ?").bind(new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()),
    ]);
    await processPushReceipts(env);
  },
} satisfies ExportedHandler<Env>;

async function createPairing(env: Env, environmentID: string, role: RemoteRole) {
  const token = randomToken(24);
  const expiresAt = isoAfter(10 * 60);
  await env.DB.prepare(
    "INSERT INTO pairings(id, environment_id, token_hash, role, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(crypto.randomUUID(), environmentID, await tokenHash(token), role, expiresAt, new Date().toISOString())
    .run();
  return { token, expiresAt };
}

function bounded(value: string | undefined, fallback: string): string {
  const normalized = value?.trim().replace(/\s+/gu, " ") ?? "";
  return (normalized || fallback).slice(0, 200);
}

export class EnvironmentRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/revoke") {
      const principal = url.searchParams.get("principal");
      for (const socket of this.ctx.getWebSockets()) {
        const identity = socket.deserializeAttachment() as SocketIdentity | null;
        if (identity?.principalID === principal) socket.close(4003, "Session revoked");
      }
      return new Response(null, { status: 204 });
    }
    if (request.method === "POST" && url.pathname === "/reset") {
      for (const socket of this.ctx.getWebSockets()) socket.close(4003, "Remote access reset");
      await this.ctx.storage.deleteAll();
      return new Response(null, { status: 204 });
    }
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }
    const environmentID = request.headers.get("x-macscope-environment");
    const principalID = request.headers.get("x-macscope-principal");
    const clientKind = request.headers.get("x-macscope-client-kind") as ClientKind | null;
    const role = request.headers.get("x-macscope-role") as RemoteRole | null;
    if (!environmentID || !principalID || !clientKind || !role) return new Response("Unauthorized", { status: 401 });

    if (clientKind === "mac") {
      for (const socket of this.ctx.getWebSockets("mac")) socket.close(4001, "Replaced by a newer Mac connection");
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const identity: SocketIdentity = {
      environmentID,
      principalID,
      clientKind,
      role,
      subscribedMetrics: false,
      windowStartedAt: Date.now(),
      messageCount: 0,
    };
    server.serializeAttachment(identity);
    this.ctx.acceptWebSocket(server, [clientKind]);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      let identity = socket.deserializeAttachment() as SocketIdentity;
      identity = enforceSocketRate(identity);
      socket.serializeAttachment(identity);
      const envelope = authorizeMobileEnvelope(parseEnvelope(message), identity);

      if (identity.clientKind === "mobile") {
        if (envelope.kind === "subscribe_metrics") {
          identity.subscribedMetrics = true;
          socket.serializeAttachment(identity);
        } else if (envelope.kind === "unsubscribe_metrics") {
          identity.subscribedMetrics = false;
          socket.serializeAttachment(identity);
        }
        const macs = this.ctx.getWebSockets("mac");
        if (macs.length === 0 && envelope.kind.startsWith("command_")) {
          socket.send(JSON.stringify(errorEnvelope(envelope.id, "mac_offline", "The Mac is offline. Nothing was queued.")));
          return;
        }
        if (envelope.kind === "command_prepare") {
          const payload = envelope.payload as Record<string, unknown>;
          const commandID = String(payload.commandID ?? "");
          const actionID = String(payload.actionID ?? "");
          const expiresAt = String(payload.expiresAt ?? "");
          if (!commandID || !actionID || !Number.isFinite(Date.parse(expiresAt)) || Date.parse(expiresAt) <= Date.now()) {
            throw new ProtocolError("invalid_command", "The command ID, action, and future expiry are required.");
          }
          const pending: PendingCommand = {
            commandID,
            memberID: identity.principalID,
            actionID: actionID.slice(0, 300),
            risk: "mutation",
            expiresAt,
          };
          await this.ctx.storage.put(`command:${commandID}`, pending);
          await this.ctx.storage.put(`reply:${envelope.id}`, identity.principalID);
        } else if (envelope.kind === "command_apply") {
          const commandID = String((envelope.payload as Record<string, unknown>).commandID ?? "");
          const pending = await this.ctx.storage.get<PendingCommand>(`command:${commandID}`);
          if (!pending || pending.memberID !== identity.principalID || Date.parse(pending.expiresAt) <= Date.now()) {
            throw new ProtocolError("invalid_approval", "This prepared command is expired or belongs to another member.");
          }
          await this.ctx.storage.put(`reply:${envelope.id}`, identity.principalID);
        }
        for (const mac of macs) safeSend(mac, envelope);
        return;
      }

      if (envelope.kind === "metric_frame") {
        for (const mobile of this.ctx.getWebSockets("mobile")) {
          const mobileIdentity = mobile.deserializeAttachment() as SocketIdentity;
          if (mobileIdentity.subscribedMetrics) safeSend(mobile, envelope);
        }
        return;
      }
      if (envelope.kind === "command_prepared") {
        const payload = envelope.payload as Record<string, unknown>;
        const commandID = String(payload.commandID ?? "");
        const pending = await this.ctx.storage.get<PendingCommand>(`command:${commandID}`);
        if (pending) {
          pending.actionID = String(payload.actionID ?? pending.actionID).slice(0, 300);
          pending.risk = normalizeRisk(payload.risk);
          await this.ctx.storage.put(`command:${commandID}`, pending);
          this.sendToPrincipal(pending.memberID, envelope);
        }
        await this.ctx.storage.delete(`reply:${envelope.id}`);
        return;
      }
      if (envelope.kind === "command_result") {
        const payload = envelope.payload as Record<string, unknown>;
        const commandID = String(payload.commandID ?? "");
        const pending = await this.ctx.storage.get<PendingCommand>(`command:${commandID}`);
        if (pending) this.sendToPrincipal(pending.memberID, envelope);
        await this.recordCommandResult(envelope, pending);
        await this.ctx.storage.delete([`command:${commandID}`, `reply:${envelope.id}`]);
        return;
      }
      if (envelope.kind === "error") {
        const memberID = await this.ctx.storage.get<string>(`reply:${envelope.id}`);
        if (memberID) {
          this.sendToPrincipal(memberID, envelope);
          await this.ctx.storage.delete(`reply:${envelope.id}`);
        }
        return;
      }
      for (const mobile of this.ctx.getWebSockets("mobile")) safeSend(mobile, envelope);
      if (envelope.kind === "alert") await this.push(envelope, "alerts");
      if (envelope.kind === "presence") {
        const online = (envelope.payload as Record<string, unknown>).online === true;
        const previous = await this.ctx.storage.get<boolean>("mac-online");
        await this.ctx.storage.put("mac-online", online);
        if (previous === false && online) await this.push(envelope, "presence");
      }
    } catch (error) {
      const protocolError = error instanceof ProtocolError ? error : new ProtocolError("invalid_message", "The message was rejected.");
      socket.send(JSON.stringify(errorEnvelope(crypto.randomUUID(), protocolError.code, protocolError.message)));
    }
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    const identity = socket.deserializeAttachment() as SocketIdentity | null;
    if (identity?.clientKind === "mobile" && identity.subscribedMetrics) {
      const anySubscribed = this.ctx.getWebSockets("mobile").some((candidate) => {
        const value = candidate.deserializeAttachment() as SocketIdentity | null;
        return candidate !== socket && value?.subscribedMetrics;
      });
      if (!anySubscribed) {
        const envelope = systemEnvelope("unsubscribe_metrics", identity.environmentID);
        for (const mac of this.ctx.getWebSockets("mac")) safeSend(mac, envelope);
      }
    }
    if (identity?.clientKind === "mac") {
      const anotherMacIsConnected = this.ctx.getWebSockets("mac").some((candidate) => candidate !== socket);
      if (anotherMacIsConnected) return;
      const envelope = systemEnvelope("presence", identity.environmentID, { online: false, lastHeartbeatAt: new Date().toISOString() });
      for (const mobile of this.ctx.getWebSockets("mobile")) safeSend(mobile, envelope);
      await this.ctx.storage.put("mac-online", false);
      await this.push(envelope, "presence");
    }
  }

  webSocketError(socket: WebSocket): void {
    socket.close(1011, "Relay socket error");
  }

  private sendToPrincipal(principalID: string, envelope: WireEnvelope): void {
    for (const mobile of this.ctx.getWebSockets("mobile")) {
      const identity = mobile.deserializeAttachment() as SocketIdentity | null;
      if (identity?.principalID === principalID) safeSend(mobile, envelope);
    }
  }

  private async recordCommandResult(envelope: WireEnvelope, pending?: PendingCommand): Promise<void> {
    const payload = envelope.payload as Record<string, unknown>;
    const actionID = (pending?.actionID ?? String(payload.actionID ?? "unknown")).slice(0, 300);
    const accepted = payload.accepted === true;
    const memberID = pending?.memberID ?? null;
    const member = memberID
      ? await this.env.DB.prepare("SELECT display_name FROM members WHERE id = ?").bind(memberID).first<{ display_name: string }>()
      : null;
    const risk = pending?.risk ?? normalizeRisk(payload.risk);
    await this.env.DB.prepare(
      `INSERT INTO audit_events(id, environment_id, member_id, actor_name, action_id, risk, outcome, error_code, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        crypto.randomUUID(),
        envelope.environmentID,
        memberID,
        member?.display_name ?? "Remote member",
        actionID,
        risk,
        accepted ? "completed" : "failed",
        typeof payload.errorCode === "string" ? payload.errorCode.slice(0, 200) : null,
        new Date().toISOString(),
      )
      .run();
    await this.push(envelope, "commands");
  }

  private async push(envelope: WireEnvelope, category: "alerts" | "presence" | "commands"): Promise<void> {
    const flag = category === "alerts" ? "notify_alerts" : category === "presence" ? "notify_presence" : "notify_commands";
    const tokens = await this.env.DB.prepare(
      `SELECT d.id AS device_id, d.push_token
         FROM devices d
         JOIN members m ON m.id = d.member_id
         JOIN environments e ON e.id = m.environment_id
        WHERE m.environment_id = ? AND d.push_token IS NOT NULL AND d.${flag} = 1 AND e.push_${category} = 1`,
    )
      .bind(envelope.environmentID)
      .all<{ device_id: string; push_token: string }>();
    if (tokens.results.length === 0) return;
    const payload = envelope.payload as Record<string, unknown>;
    const title = category === "alerts" ? String(payload.title ?? "MacScope alert") : category === "presence" ? "MacScope connection" : "Remote command";
    const message = category === "alerts"
      ? String(payload.message ?? "A configured MacScope threshold was reached.")
      : category === "presence"
        ? payload.online === true ? "The Mac came online." : "The Mac went offline."
        : payload.accepted === true ? "The remote command completed." : "The remote command failed.";
    const messages = tokens.results.map(({ push_token }) => ({
      to: push_token,
      title: title.slice(0, 100),
      body: message.slice(0, 300),
      sound: "default",
      data: {
        environmentID: envelope.environmentID,
        kind: envelope.kind,
        envelopeID: envelope.id,
        commandID: typeof payload.commandID === "string" ? payload.commandID : undefined,
        actionID: typeof payload.actionID === "string" ? payload.actionID : undefined,
        accepted: typeof payload.accepted === "boolean" ? String(payload.accepted) : undefined,
        errorCode: typeof payload.errorCode === "string" ? payload.errorCode.slice(0, 120) : undefined,
      },
    }));
    for (let index = 0; index < messages.length; index += 100) {
      const headers: Record<string, string> = { "content-type": "application/json" };
      if (this.env.EXPO_ACCESS_TOKEN) headers.authorization = `Bearer ${this.env.EXPO_ACCESS_TOKEN}`;
      const slice = messages.slice(index, index + 100);
      const response = await postExpo("https://exp.host/--/api/v2/push/send", headers, slice);
      if (!response.ok) {
        console.error("Expo push rejected", response.status, await response.text());
        continue;
      }
      const result = await response.json() as { data?: Array<{ status?: string; id?: string; details?: { error?: string } }> };
      const statements: D1PreparedStatement[] = [];
      for (const [offset, ticket] of (result.data ?? []).entries()) {
        const device = tokens.results[index + offset];
        if (!device) continue;
        if (ticket.details?.error === "DeviceNotRegistered") {
          statements.push(this.env.DB.prepare("UPDATE devices SET push_token = NULL WHERE id = ?").bind(device.device_id));
        } else if (ticket.status === "ok" && ticket.id) {
          const now = new Date().toISOString();
          statements.push(this.env.DB.prepare(
            `INSERT OR REPLACE INTO push_tickets(id, device_id, push_token, attempts, next_check_at, created_at)
             VALUES (?, ?, ?, 0, ?, ?)`,
          ).bind(ticket.id, device.device_id, device.push_token, isoAfter(15 * 60), now));
        }
      }
      if (statements.length) await this.env.DB.batch(statements);
    }
  }
}

async function postExpo(url: string, headers: Record<string, string>, payload: unknown): Promise<Response> {
  let response = await fetch(url, { method: "POST", headers, body: JSON.stringify(payload) });
  if (response.status >= 500 || response.status === 429) {
    response = await fetch(url, { method: "POST", headers, body: JSON.stringify(payload) });
  }
  return response;
}

async function processPushReceipts(env: Env): Promise<void> {
  const due = await env.DB.prepare(
    "SELECT id, device_id, push_token, attempts FROM push_tickets WHERE next_check_at <= ? ORDER BY next_check_at LIMIT 300",
  ).bind(new Date().toISOString()).all<{ id: string; device_id: string; push_token: string; attempts: number }>();
  if (!due.results.length) return;
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (env.EXPO_ACCESS_TOKEN) headers.authorization = `Bearer ${env.EXPO_ACCESS_TOKEN}`;
  const response = await postExpo("https://exp.host/--/api/v2/push/getReceipts", headers, { ids: due.results.map((ticket) => ticket.id) });
  if (!response.ok) return;
  const value = await response.json() as {
    data?: Record<string, { status?: string; details?: { error?: string } }>;
  };
  const statements: D1PreparedStatement[] = [];
  for (const ticket of due.results) {
    const receipt = value.data?.[ticket.id];
    if (receipt?.details?.error === "DeviceNotRegistered") {
      statements.push(env.DB.prepare("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?").bind(ticket.device_id, ticket.push_token));
      statements.push(env.DB.prepare("DELETE FROM push_tickets WHERE id = ?").bind(ticket.id));
    } else if (receipt?.status === "ok" || ticket.attempts >= 2) {
      statements.push(env.DB.prepare("DELETE FROM push_tickets WHERE id = ?").bind(ticket.id));
    } else {
      statements.push(env.DB.prepare("UPDATE push_tickets SET attempts = attempts + 1, next_check_at = ? WHERE id = ?")
        .bind(isoAfter(15 * 60 * (ticket.attempts + 1)), ticket.id));
    }
  }
  if (statements.length) await env.DB.batch(statements);
}

function enforceSocketRate(identity: SocketIdentity): SocketIdentity {
  const now = Date.now();
  const reset = now - identity.windowStartedAt >= 10_000;
  const next = {
    ...identity,
    windowStartedAt: reset ? now : identity.windowStartedAt,
    messageCount: reset ? 1 : identity.messageCount + 1,
  };
  if (next.messageCount > 300) throw new ProtocolError("rate_limited", "Too many socket messages.");
  return next;
}

function safeSend(socket: WebSocket, envelope: WireEnvelope): void {
  if (socket.readyState !== WebSocket.OPEN) return;
  const value = JSON.stringify(envelope);
  if (new TextEncoder().encode(value).byteLength <= MAX_MESSAGE_BYTES) socket.send(value);
}

function systemEnvelope(kind: string, environmentID: string, payload: Record<string, unknown> = {}): WireEnvelope {
  return { schemaVersion: 1, id: crypto.randomUUID(), kind, sentAt: new Date().toISOString(), environmentID, payload };
}

function errorEnvelope(id: string, code: string, message: string): WireEnvelope {
  return { schemaVersion: 1, id, kind: "error", sentAt: new Date().toISOString(), payload: { code, message } };
}

function normalizeRisk(value: unknown): RemoteRisk {
  return value === "read_only" || value === "mutation" || value === "sensitive" || value === "destructive" ? value : "mutation";
}
