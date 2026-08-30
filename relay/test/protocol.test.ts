import { describe, expect, it } from "vitest";
import { ProtocolError, authorizeMobileEnvelope, parseEnvelope, type SocketIdentity } from "../src/protocol";

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
});
