import { describe, expect, it } from "vitest";
import { ProtocolError, authorizeMobileEnvelope, normalizeEnvelopeIdentifiers, parseEnvelope, type SocketIdentity } from "../src/protocol";

const identity = (role: "viewer" | "operator" | "owner"): SocketIdentity => ({
  environmentID: "env-1",
  principalID: "member-1",
  clientKind: "mobile",
  role,
  subscribedMetrics: false,
  windowStartedAt: Date.now(),
  messageCount: 0,
});

const prepare = JSON.stringify({
  schemaVersion: 1,
  id: "command-1",
  kind: "command_prepare",
  sentAt: new Date().toISOString(),
  payload: {
    schemaVersion: 1,
    commandID: "command-1",
    actorID: "forged",
    role: "owner",
    actionID: "utility.sound.refresh",
  },
});

describe("remote protocol", () => {
  it("rejects unsupported schemas and oversized payloads", () => {
    expect(() => parseEnvelope(JSON.stringify({ schemaVersion: 2, id: "x", kind: "hello", payload: {} }))).toThrow(ProtocolError);
    expect(() => parseEnvelope("x".repeat(64 * 1024 + 1))).toThrow(ProtocolError);
  });

  it("does not trust actor or role values supplied by the mobile client", () => {
    const authorized = authorizeMobileEnvelope(parseEnvelope(prepare), identity("operator"));
    expect(authorized.environmentID).toBe("env-1");
    expect(authorized.payload).toMatchObject({ actorID: "member-1", role: "operator" });
  });

  it("denies viewer writes but permits subscriptions", () => {
    expect(() => authorizeMobileEnvelope(parseEnvelope(prepare), identity("viewer"))).toThrowError(/Viewer/);
    const subscription = parseEnvelope(JSON.stringify({ schemaVersion: 1, id: "s", kind: "subscribe_metrics", payload: {} }));
    expect(authorizeMobileEnvelope(subscription, identity("viewer")).kind).toBe("subscribe_metrics");
  });

  it("normalizes Swift UUID casing before relay correlation", () => {
    const envelope = normalizeEnvelopeIdentifiers(parseEnvelope(JSON.stringify({
      schemaVersion: 1,
      id: "08761798-4727-44E3-8345-836D2EA1970B",
      kind: "command_prepared",
      sentAt: new Date().toISOString(),
      payload: { commandID: "BA9B33D0-77C8-4FE5-B41C-F9336B0CD8CD" },
    })));
    expect(envelope.id).toBe("08761798-4727-44e3-8345-836d2ea1970b");
    expect(envelope.payload).toMatchObject({ commandID: "ba9b33d0-77c8-4fe5-b41c-f9336b0cd8cd" });
  });
});
