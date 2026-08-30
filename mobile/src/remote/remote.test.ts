import { describe, expect, it, vi } from "vitest";
import { parseArgument } from "./arguments";
import { parsePairingURL, webSocketURL } from "./urls";
import { reconnectDelay, requireDeviceAuthentication, roleCanWrite } from "./security";
import { remoteStorage } from "./storage";
import { notificationTarget } from "./notification-routing";
import { newUUID, uuidFromRandomBytes } from "./ids";
import { fieldsForAction, serializeArguments } from "./utility-form";
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

  it("always emits RFC 4122 UUIDs for the Swift wire protocol", () => {
    expect(uuidFromRandomBytes(new Uint8Array(16))).toBe("00000000-0000-4000-8000-000000000000");
    expect(newUUID()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  });

  it("turns screenshot protocol arguments into questions and typed values", () => {
    const action = {
      id: "capture.screenshot", module: "capture", title: "Capture screenshot", summary: "Capture it.",
      arguments: { mode: "full_screen, window or selection.", copy_to_clipboard: "Optional Boolean.", delay_seconds: "Optional integer from 0 through 30." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: true, requiredPermissions: [],
    };
    const fields = fieldsForAction(action);
    expect(fields.map((field) => [field.name, field.kind])).toEqual([
      ["mode", "choice"], ["delay_seconds", "number"], ["copy_to_clipboard", "boolean"],
    ]);
    expect(serializeArguments(fields, { mode: "window", copy_to_clipboard: true, delay_seconds: "3" })).toEqual({
      mode: "window", copy_to_clipboard: true, delay_seconds: 3,
    });
    expect(serializeArguments(fields, { mode: "full_screen", copy_to_clipboard: false, delay_seconds: "0" })).toEqual({
      mode: "full_screen", copy_to_clipboard: false, delay_seconds: 0,
    });
    expect(serializeArguments(fields, { mode: "selection", copy_to_clipboard: "", delay_seconds: "" })).toEqual({ mode: "selection" });
  });

  it("keeps UUIDs and device identifiers as text while typing numeric units", () => {
    const action = {
      id: "notes.update", module: "notes", title: "Update scratchpad", summary: "Update it.",
      arguments: { id: "Scratchpad UUID from notes state.", text: "New Markdown text." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: false, requiredPermissions: [],
    };
    expect(fieldsForAction(action).map((field) => [field.name, field.kind])).toEqual([["id", "text"], ["text", "multiline"]]);

    const schedule = { ...action, id: "maintenance.set-cleanup-schedule", arguments: { hours: "Positive hours, or null to disable." } };
    expect(fieldsForAction(schedule)[0]?.kind).toBe("number");
  });

  it("keeps optional live selections explicitly unset until the user chooses", () => {
    const action = {
      id: "capture.recording-start", module: "capture", title: "Start recording", summary: "Record it.",
      arguments: { source_id: "Optional source ID from capture state." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: false, requiredPermissions: [],
    };
    const fields = fieldsForAction(action, { recording: { sources: [{ id: "display-1", name: "Built-in display" }] } });
    expect(fields[0]?.options.map((option) => option.value)).toEqual(["", "display-1"]);
    expect(fields[0]?.initialValue).toBe("");
    expect(serializeArguments(fields, {})).toEqual({});
  });

  it("offers live camera devices instead of requiring an opaque identifier", () => {
    const action = {
      id: "capture.camera-start", module: "capture", title: "Start camera preview", summary: "Open it.",
      arguments: { device_id: "Optional camera device ID from capture state." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: false, requiredPermissions: ["Camera"],
    };
    const fields = fieldsForAction(action, { camera: { devices: [{ id: "camera-42", name: "Studio Display Camera" }] } });
    expect(fields[0]?.options).toEqual([{ value: "", label: "Use current or default" }, { value: "camera-42", label: "Studio Display Camera" }]);
    expect(serializeArguments(fields, { device_id: "camera-42" })).toEqual({ device_id: "camera-42" });
  });

  it("serializes numeric dropdown identifiers as numbers for Swift", () => {
    const soundAction = {
      id: "sound.toggle-app-mute", module: "sound", title: "Toggle mute", summary: "Toggle it.",
      arguments: { pid: "Running process identifier." },
      risk: "mutation" as const, allowed: true, requiresDeviceAuthentication: false, producesArtifact: false, requiredPermissions: [],
    };
    const soundFields = fieldsForAction(soundAction, { applications: [{ pid: 4242, name: "Music" }] });
    expect(soundFields[0]).toMatchObject({ kind: "choice", numeric: true });
    expect(serializeArguments(soundFields, { pid: "4242" })).toEqual({ pid: 4242 });

    const displayAction = {
      ...soundAction, id: "power.set-display-brightness", module: "power", title: "Set brightness",
      arguments: { display_id: "Display identifier from power state.", value: "Number from 0 through 1." },
    };
    const displayFields = fieldsForAction(displayAction, { hardware_displays: [{ id: 7, name: "Studio Display" }] });
    expect(serializeArguments(displayFields, { display_id: "7", value: "0.8" })).toEqual({ display_id: 7, value: 0.8 });

    const offsetAction = {
      ...soundAction, id: "windows.move-display", module: "windows", title: "Move display",
      arguments: { offset: "-1 for previous or 1 for next." },
    };
    expect(serializeArguments(fieldsForAction(offsetAction), { offset: "-1" })).toEqual({ offset: -1 });
  });

  it("sends exact typed Homebrew identifiers from live utility state", () => {
    const action = {
      id: "maintenance.set-homebrew-installed", module: "maintenance", title: "Install package", summary: "Change it.",
      arguments: { id: "Search item ID from maintenance state.", installed: "Desired installed state." },
      risk: "destructive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: false, requiredPermissions: [],
    };
    const fields = fieldsForAction(action, { homebrew_search: [{ id: "cask:firefox", name: "firefox", cask: true, installed: false }] });
    expect(fields.find((field) => field.name === "id")?.options).toEqual([{ value: "cask:firefox", label: "firefox" }]);
    expect(serializeArguments(fields, { id: "cask:firefox", installed: true })).toEqual({ id: "cask:firefox", installed: true });
  });

  it("offers and serializes explicit cancellation for nullable schedules", () => {
    const action = {
      id: "clipboard.schedule-clear", module: "clipboard", title: "Schedule clear", summary: "Schedule it.",
      arguments: { seconds: "Positive seconds, or null to cancel." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: false, requiredPermissions: [],
    };
    const fields = fieldsForAction(action);
    expect(fields[0]).toMatchObject({ kind: "number", optional: true, nullable: true, exclusiveMin: true, initialValue: "" });
    expect(serializeArguments(fields, { seconds: "null" })).toEqual({ seconds: null });
    expect(serializeArguments(fields, { seconds: "60" })).toEqual({ seconds: 60 });
    expect(() => serializeArguments(fields, { seconds: "0" })).toThrow(/greater than 0/);
  });

  it("enforces non-negative and positive catalog bounds before sending", () => {
    const action = {
      id: "capture.scrolling-screenshot", module: "capture", title: "Scrolling screenshot", summary: "Capture it.",
      arguments: { overlap_pixels: "Non-negative overlap.", steps: "Segment count from 2 through 20." },
      risk: "sensitive" as const, allowed: true, requiresDeviceAuthentication: true, producesArtifact: true, requiredPermissions: [],
    };
    const fields = fieldsForAction(action);
    expect(fields.find((field) => field.name === "overlap_pixels")).toMatchObject({ kind: "number", min: 0 });
    expect(() => serializeArguments(fields, { overlap_pixels: "-1", steps: "4" })).toThrow(/at least 0/);
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
