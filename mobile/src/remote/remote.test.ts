import { describe, expect, it, vi } from "vitest";
import { parseArgument } from "./arguments";
import { parsePairingURL, webSocketURL } from "./urls";
import { reconnectDelay, requireDeviceAuthentication, roleCanWrite } from "./security";
import { remoteStorage } from "./storage";
import { notificationTarget } from "./notification-routing";
import type { StoredEnvironment } from "./types";

const secureValues = vi.hoisted(() => new Map<string, string>());
vi.mock("expo-secure-store", () => ({
  AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: "device-only",
  getItemAsync: async (key: string) => secureValues.get(key) ?? null,
  setItemAsync: async (key: string, value: string) => { secureValues.set(key, value); },
  deleteItemAsync: async (key: string) => { secureValues.delete(key); },
}));

describe("mobile remote boundaries", () => {
  it("keeps one-time pairing credentials in the URL fragment", () => {
    expect(parsePairingURL("https://relay.example.workers.dev/pair#token=single-use")).toEqual({
      relayURL: "https://relay.example.workers.dev",
      token: "single-use",
    });
    expect(() => parsePairingURL("http://relay.example/pair#token=unsafe")).toThrow(/HTTPS/);
  });

  it("puts only a short-lived ticket in the WebSocket URL", () => {
    const value = new URL(webSocketURL("https://relay.example.workers.dev", "ticket-value"));
    expect(value.protocol).toBe("wss:");
    expect(value.searchParams.get("ticket")).toBe("ticket-value");
    expect(value.searchParams.has("accessToken")).toBe(false);
  });

  it("normalizes typed utility arguments", () => {
    expect(parseArgument("true", "Boolean.")).toBe(true);
    expect(parseArgument("one, two", "Array of values.")).toEqual(["one", "two"]);
    expect(parseArgument("0.5", "Number from 0 through 1.")).toBe(0.5);
    expect(parseArgument("null", "Optional value.")).toBeNull();
  });

  it("persists long-lived credentials through SecureStore", async () => {
    secureValues.clear();
    const environment: StoredEnvironment = {
      environmentID: "env-1", relayURL: "https://relay.example", displayName: "Studio Mac",
      memberID: "member-1", deviceID: "device-1", role: "owner",
      accessToken: "access-secret", accessExpiresAt: "2026-08-30T12:15:00Z",
      refreshToken: "refresh-secret", refreshExpiresAt: "2026-11-30T12:00:00Z",
    };
    await remoteStorage.saveEnvironment(environment);
    expect(await remoteStorage.environments()).toEqual([environment]);
    expect(await remoteStorage.activeEnvironmentID()).toBe("env-1");
  });

  it("uses the same bounded reconnect behavior on iOS and Android", () => {
    expect(reconnectDelay(1)).toBe(2_000);
    expect(reconnectDelay(20)).toBe(30_000);
  });

  it("enforces viewer, operator, and owner controls", () => {
    expect(roleCanWrite("viewer")).toBe(false);
    expect(roleCanWrite("operator")).toBe(true);
    expect(roleCanWrite("owner")).toBe(true);
  });

  it("handles biometric success, cancellation, and unavailable devices", async () => {
    await expect(requireDeviceAuthentication(true, {
      hasHardware: async () => true, isEnrolled: async () => true, authenticate: async () => ({ success: true }),
    })).resolves.toBeUndefined();
    await expect(requireDeviceAuthentication(true, {
      hasHardware: async () => true, isEnrolled: async () => true, authenticate: async () => ({ success: false }),
    })).rejects.toThrow(/cancelled/);
    await expect(requireDeviceAuthentication(true, {
      hasHardware: async () => false, isEnrolled: async () => false, authenticate: async () => ({ success: false }),
    })).rejects.toThrow(/Set up/);
  });

  it("deep-links notifications to the relevant Mac and command", () => {
    expect(notificationTarget({ environmentID: "env-2", commandID: "cmd-4", envelopeID: "alert-3", actionID: "utility.sound.refresh", accepted: "true" })).toEqual({
      environmentID: "env-2",
      commandID: "cmd-4",
      alertID: "alert-3",
      actionID: "utility.sound.refresh",
      accepted: "true",
      errorCode: undefined,
    });
  });
});
