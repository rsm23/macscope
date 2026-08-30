export const PROTOCOL_VERSION = 1;
export const MAX_MESSAGE_BYTES = 64 * 1024;

export type RemoteRole = "viewer" | "operator" | "owner";
export type ClientKind = "mac" | "mobile";
export type RemoteRisk = "read_only" | "mutation" | "sensitive" | "destructive";

export interface WireEnvelope {
  schemaVersion: number;
  id: string;
  kind: string;
  sentAt: string;
  environmentID?: string;
  payload: Record<string, unknown> | unknown[];
}

export interface SocketIdentity {
  environmentID: string;
  principalID: string;
  clientKind: ClientKind;
  role: RemoteRole;
  subscribedMetrics: boolean;
  windowStartedAt: number;
  messageCount: number;
}

export const canWrite = (role: RemoteRole): boolean => role === "operator" || role === "owner";
export const canManage = (role: RemoteRole): boolean => role === "owner";

export function parseEnvelope(input: string | ArrayBuffer): WireEnvelope {
  const text = typeof input === "string" ? input : new TextDecoder().decode(input);
  if (new TextEncoder().encode(text).byteLength > MAX_MESSAGE_BYTES) {
    throw new ProtocolError("payload_too_large", "Messages are limited to 64 KiB.");
  }
  const value: unknown = JSON.parse(text);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ProtocolError("invalid_envelope", "Expected a JSON object.");
  }
  const envelope = value as Partial<WireEnvelope>;
  if (envelope.schemaVersion !== PROTOCOL_VERSION || typeof envelope.kind !== "string" || typeof envelope.id !== "string") {
    throw new ProtocolError("unsupported_schema", "The remote protocol version is not supported.");
  }
  if (!envelope.payload || typeof envelope.payload !== "object") {
    throw new ProtocolError("invalid_payload", "The envelope payload is required.");
  }
  return envelope as WireEnvelope;
}

export function authorizeMobileEnvelope(envelope: WireEnvelope, identity: SocketIdentity): WireEnvelope {
  if (identity.clientKind !== "mobile") return envelope;
  const writeKinds = new Set(["command_prepare", "command_apply"]);
  if (writeKinds.has(envelope.kind) && !canWrite(identity.role)) {
    throw new ProtocolError("role_denied", "Viewer sessions cannot mutate a Mac.");
  }
  if (envelope.kind === "command_prepare") {
    const payload = envelope.payload as Record<string, unknown>;
    return {
      ...envelope,
      environmentID: identity.environmentID,
      payload: { ...payload, actorID: identity.principalID, role: identity.role },
    };
  }
  return { ...envelope, environmentID: identity.environmentID };
}

export class ProtocolError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}
