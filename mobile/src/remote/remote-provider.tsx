import NetInfo from "@react-native-community/netinfo";
import Constants from "expo-constants";
import * as Device from "expo-device";
import * as Haptics from "expo-haptics";
import * as Notifications from "expo-notifications";
import { router } from "expo-router";
import React, { createContext, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AppState } from "react-native";
import { RemoteApi } from "./api";
import { remoteStorage } from "./storage";
import { reconnectDelay } from "./security";
import { notificationTarget } from "./notification-routing";
import { webSocketURL } from "./urls";
import type {
  AuditEvent,
  CommandResult,
  ConnectionState,
  EnvironmentSummary,
  MetricFrame,
  NotificationPreferences,
  PreparedCommand,
  Presence,
  RemoteFeature,
  RemoteMember,
  RemoteRole,
  StoredEnvironment,
  UtilityAction,
  WireEnvelope,
} from "./types";

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldPlaySound: true,
    shouldSetBadge: false,
    shouldShowBanner: true,
    shouldShowList: true,
  }),
});

interface RemoteContextValue {
  environments: StoredEnvironment[];
  activeEnvironment?: StoredEnvironment;
  connection: ConnectionState;
  error?: string;
  presence?: Presence;
  metric?: MetricFrame;
  metricHistory: MetricFrame[];
  features: RemoteFeature[];
  utilities: UtilityAction[];
  members: RemoteMember[];
  audit: AuditEvent[];
  commandResults: CommandResult[];
  notifications: NotificationPreferences;
  pair(pairingURL: string, displayName: string): Promise<void>;
  removeEnvironment(environmentID: string): Promise<void>;
  selectEnvironment(environmentID: string): Promise<void>;
  prepareCommand(actionID: string, args?: Record<string, unknown>): Promise<PreparedCommand>;
  applyCommand(command: PreparedCommand): Promise<void>;
  createPairing(role: RemoteRole): Promise<{ pairingURL: string; expiresAt: string }>;
  revokeMember(memberID: string): Promise<void>;
  refreshSummary(): Promise<void>;
  setNotifications(value: NotificationPreferences): Promise<void>;
}

const RemoteContext = createContext<RemoteContextValue | null>(null);

export function useRemote(): RemoteContextValue {
  const value = React.use(RemoteContext);
  if (!value) throw new Error("useRemote must be used inside RemoteProvider");
  return value;
}

export function RemoteProvider({ children }: { children: React.ReactNode }) {
  const [environments, setEnvironments] = useState<StoredEnvironment[]>([]);
  const [activeID, setActiveID] = useState<string>();
  const [connection, setConnection] = useState<ConnectionState>("offline");
  const [error, setError] = useState<string>();
  const [presence, setPresence] = useState<Presence>();
  const [metricHistory, setMetricHistory] = useState<MetricFrame[]>([]);
  const [features, setFeatures] = useState<RemoteFeature[]>([]);
  const [utilities, setUtilities] = useState<UtilityAction[]>([]);
  const [members, setMembers] = useState<RemoteMember[]>([]);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [commandResults, setCommandResults] = useState<CommandResult[]>([]);
  const [notifications, setNotificationState] = useState<NotificationPreferences>({
    alerts: true,
    presence: true,
    commands: true,
  });
  const socketRef = useRef<WebSocket | null>(null);
  const apiRef = useRef<RemoteApi | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const reconnectAttempt = useRef(0);
  const shouldConnect = useRef(true);
  const connectRef = useRef<(environment: StoredEnvironment) => void>(() => {});
  const pendingResolvers = useRef(
    new Map<string, { resolve: (value: PreparedCommand) => void; reject: (reason: Error) => void; timeout: ReturnType<typeof setTimeout> }>(),
  );

  const activeEnvironment = environments.find((value) => value.environmentID === activeID);

  const saveUpdatedEnvironment = useCallback(async (environment: StoredEnvironment) => {
    await remoteStorage.saveEnvironment(environment);
    setEnvironments((values) => values.map((value) => (value.environmentID === environment.environmentID ? environment : value)));
  }, []);

  const send = useCallback((kind: string, payload: Record<string, unknown> | unknown[], id = newID()) => {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) throw new Error("The Mac is offline. Nothing was queued.");
    const envelope: WireEnvelope = {
      schemaVersion: 1,
      id,
      kind,
      sentAt: new Date().toISOString(),
      environmentID: activeID,
      payload,
    };
    const value = JSON.stringify(envelope);
    if (new TextEncoder().encode(value).byteLength > 64 * 1024) throw new Error("The command exceeds the 64 KiB limit.");
    socket.send(value);
  }, [activeID]);

  const refreshSummary = useCallback(async () => {
    if (!apiRef.current || !activeEnvironment || activeEnvironment.role !== "owner") {
      setMembers([]);
      setAudit([]);
      return;
    }
    const summary: EnvironmentSummary = await apiRef.current.summary();
    setMembers(summary.members);
    setAudit(summary.audit);
  }, [activeEnvironment]);

  const handleEnvelope = useCallback((event: MessageEvent<string>) => {
    let envelope: WireEnvelope;
    try {
      envelope = JSON.parse(event.data) as WireEnvelope;
      if (envelope.schemaVersion !== 1) throw new Error("Unsupported protocol version");
    } catch {
      setError("The relay sent an invalid protocol message.");
      return;
    }
    switch (envelope.kind) {
      case "presence":
        setPresence(envelope.payload as unknown as Presence);
        break;
      case "metric_frame": {
        const frame = envelope.payload as unknown as MetricFrame;
        setMetricHistory((values) => [...values, frame].slice(-60));
        break;
      }
      case "feature_states":
        setFeatures(envelope.payload as unknown as RemoteFeature[]);
        break;
      case "utility_catalog":
        setUtilities(envelope.payload as unknown as UtilityAction[]);
        break;
      case "command_prepared": {
        const prepared = normalizePrepared(envelope.payload as Record<string, unknown>);
        const resolver = pendingResolvers.current.get(envelope.id);
        if (resolver) {
          clearTimeout(resolver.timeout);
          pendingResolvers.current.delete(envelope.id);
          resolver.resolve(prepared);
        }
        break;
      }
      case "command_result": {
        const result = envelope.payload as unknown as CommandResult;
        setCommandResults((values) => [result, ...values.filter((value) => value.commandID !== result.commandID)].slice(0, 50));
        void Haptics.notificationAsync(result.accepted ? Haptics.NotificationFeedbackType.Success : Haptics.NotificationFeedbackType.Error);
        break;
      }
      case "error": {
        const payload = envelope.payload as Record<string, unknown>;
        const message = String(payload.message ?? "The remote request failed.");
        const resolver = pendingResolvers.current.get(envelope.id);
        if (resolver) {
          clearTimeout(resolver.timeout);
          pendingResolvers.current.delete(envelope.id);
          resolver.reject(new Error(message));
        }
        setError(message);
        break;
      }
    }
  }, []);

  const disconnect = useCallback(() => {
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
    reconnectTimer.current = null;
    const socket = socketRef.current;
    socketRef.current = null;
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, "Client disconnect");
    for (const pending of pendingResolvers.current.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("The live connection closed before the Mac responded."));
    }
    pendingResolvers.current.clear();
  }, []);

  const connect = useCallback(async (environment: StoredEnvironment) => {
    disconnect();
    if (!shouldConnect.current) return;
    setConnection(reconnectAttempt.current > 0 ? "reconnecting" : "connecting");
    setError(undefined);
    const api = new RemoteApi(environment, async (tokens) => {
      const updated = { ...environment, ...tokens };
      await saveUpdatedEnvironment(updated);
      api.replaceEnvironment(updated);
    });
    apiRef.current = api;
    try {
      const ticket = await api.webSocketTicket();
      const socket = new WebSocket(webSocketURL(environment.relayURL, ticket.ticket));
      socketRef.current = socket;
      socket.onopen = () => {
        reconnectAttempt.current = 0;
        setConnection("online");
        setError(undefined);
        send("subscribe_metrics", {});
        void refreshSummary();
      };
      socket.onmessage = handleEnvelope;
      socket.onerror = () => setError("The live connection encountered a network error.");
      socket.onclose = (event) => {
        if (socketRef.current !== socket) return;
        socketRef.current = null;
        setConnection("offline");
        setPresence((value) => (value ? { ...value, online: false } : value));
        if (shouldConnect.current && event.code !== 4003) {
          reconnectAttempt.current += 1;
          const delay = reconnectDelay(reconnectAttempt.current);
          setConnection("reconnecting");
          reconnectTimer.current = setTimeout(() => connectRef.current(environment), delay);
        } else if (event.code === 4003) {
          setError("This device session was revoked.");
        }
      };
    } catch (reason) {
      setConnection("error");
      setError(reason instanceof Error ? reason.message : "Could not connect to MacScope.");
      if (shouldConnect.current) {
        reconnectAttempt.current += 1;
        const delay = reconnectDelay(reconnectAttempt.current);
        reconnectTimer.current = setTimeout(() => connectRef.current(environment), delay);
      }
    }
  }, [disconnect, handleEnvelope, refreshSummary, saveUpdatedEnvironment, send]);

  useEffect(() => {
    connectRef.current = (environment) => void connect(environment);
  }, [connect]);

  useEffect(() => {
    let mounted = true;
    void Promise.all([remoteStorage.environments(), remoteStorage.activeEnvironmentID()]).then(([stored, storedActive]) => {
      if (!mounted) return;
      setEnvironments(stored);
      setActiveID(storedActive ?? stored[0]?.environmentID);
    });
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    const openNotification = (response: Notifications.NotificationResponse | null) => {
      if (!response) return;
      const data = response.notification.request.content.data ?? {};
      const target = notificationTarget(data);
      if (target.environmentID) {
        setActiveID(target.environmentID);
        void remoteStorage.setActiveEnvironmentID(target.environmentID);
      }
      if (target.commandID) {
        router.push({ pathname: "/command/[id]", params: {
          id: target.commandID,
          actionID: target.actionID,
          accepted: target.accepted,
          errorCode: target.errorCode,
        } });
      } else {
        router.push({ pathname: "/", params: { alertID: target.alertID } });
      }
    };
    const subscription = Notifications.addNotificationResponseReceivedListener(openNotification);
    void Notifications.getLastNotificationResponseAsync().then(openNotification);
    return () => subscription.remove();
  }, []);

  useEffect(() => {
    shouldConnect.current = true;
    if (activeEnvironment) void connect(activeEnvironment);
    else disconnect();
    return disconnect;
  }, [activeEnvironment, connect, disconnect]);

  useEffect(() => {
    if (!activeID) return;
    void remoteStorage.notificationPreferences(activeID).then(setNotificationState);
  }, [activeID]);

  useEffect(() => NetInfo.addEventListener((state) => {
    if (!state.isConnected) {
      setConnection("offline");
      disconnect();
    } else if (activeEnvironment && !socketRef.current) {
      void connect(activeEnvironment);
    }
  }), [activeEnvironment, connect, disconnect]);

  useEffect(() => {
    const subscription = AppState.addEventListener("change", (state) => {
      if (state === "active" && activeEnvironment && !socketRef.current) void connect(activeEnvironment);
    });
    return () => subscription.remove();
  }, [activeEnvironment, connect]);

  const pair = useCallback(async (pairingURL: string, displayName: string) => {
    const environment = await RemoteApi.redeemPairing({
      pairingURL,
      displayName,
      deviceName: Device.deviceName ?? Device.modelName ?? "Mobile device",
      platform: process.env.EXPO_OS === "ios" ? "ios" : process.env.EXPO_OS === "android" ? "android" : "unknown",
      pushToken: await pushToken().catch(() => undefined),
    });
    await remoteStorage.saveEnvironment(environment);
    setEnvironments((values) => [...values.filter((value) => value.environmentID !== environment.environmentID), environment]);
    setActiveID(environment.environmentID);
  }, []);

  const removeEnvironment = useCallback(async (environmentID: string) => {
    await remoteStorage.removeEnvironment(environmentID);
    const next = environments.filter((value) => value.environmentID !== environmentID);
    setEnvironments(next);
    if (environmentID === activeID) {
      setActiveID(next[0]?.environmentID);
      if (!next[0]) setConnection("offline");
    }
  }, [activeID, environments]);

  const selectEnvironment = useCallback(async (environmentID: string) => {
    await remoteStorage.setActiveEnvironmentID(environmentID);
    setActiveID(environmentID);
    setMetricHistory([]);
    setFeatures([]);
    setUtilities([]);
    setPresence(undefined);
  }, []);

  const prepareCommand = useCallback((actionID: string, args: Record<string, unknown> = {}) => {
    if (connection !== "online") return Promise.reject(new Error("The Mac is offline. Nothing was queued."));
    const commandID = newID();
    const envelopeID = newID();
    return new Promise<PreparedCommand>((resolve, reject) => {
      const timeout = setTimeout(() => {
        pendingResolvers.current.delete(envelopeID);
        reject(new Error("The Mac did not prepare the command before it expired."));
      }, 12_000);
      pendingResolvers.current.set(envelopeID, { resolve, reject, timeout });
      try {
        send("command_prepare", {
          schemaVersion: 1,
          commandID,
          actorID: activeEnvironment?.memberID ?? "unknown",
          role: activeEnvironment?.role ?? "viewer",
          actionID,
          arguments: args,
          expiresAt: new Date(Date.now() + 15_000).toISOString(),
        }, envelopeID);
      } catch (reason) {
        clearTimeout(timeout);
        pendingResolvers.current.delete(envelopeID);
        reject(reason);
      }
    });
  }, [activeEnvironment, connection, send]);

  const applyCommand = useCallback(async (command: PreparedCommand) => {
    if (new Date(command.expiresAt).getTime() <= Date.now()) throw new Error("The approval expired. Prepare the action again.");
    send("command_apply", {
      schemaVersion: 1,
      commandID: command.commandID,
      approvalToken: command.approvalToken,
      confirmation: command.confirmation,
      expiresAt: new Date(Date.now() + 15_000).toISOString(),
    });
  }, [send]);

  const createPairing = useCallback(async (role: RemoteRole) => {
    if (!apiRef.current) throw new Error("Connect to the relay first.");
    return apiRef.current.createPairing(role);
  }, []);

  const revokeMember = useCallback(async (memberID: string) => {
    if (!apiRef.current) throw new Error("Connect to the relay first.");
    await apiRef.current.revokeMember(memberID);
    await refreshSummary();
  }, [refreshSummary]);

  const setNotifications = useCallback(async (value: NotificationPreferences) => {
    setNotificationState(value);
    if (activeID) await remoteStorage.setNotificationPreferences(activeID, value);
    if (!apiRef.current) return;
    await apiRef.current.updatePush(await pushToken().catch(() => undefined), value);
  }, [activeID]);

  const value = useMemo<RemoteContextValue>(() => ({
    environments,
    activeEnvironment,
    connection,
    error,
    presence,
    metric: metricHistory.at(-1),
    metricHistory,
    features,
    utilities,
    members,
    audit,
    commandResults,
    notifications,
    pair,
    removeEnvironment,
    selectEnvironment,
    prepareCommand,
    applyCommand,
    createPairing,
    revokeMember,
    refreshSummary,
    setNotifications,
  }), [
    environments, activeEnvironment, connection, error, presence, metricHistory, features, utilities,
    members, audit, commandResults, notifications, pair, removeEnvironment, selectEnvironment,
    prepareCommand, applyCommand, createPairing, revokeMember, refreshSummary, setNotifications,
  ]);

  return <RemoteContext value={value}>{children}</RemoteContext>;
}

async function pushToken(): Promise<string | undefined> {
  if (!Device.isDevice) return undefined;
  const current = await Notifications.getPermissionsAsync();
  const permission = current.status === "granted" ? current : await Notifications.requestPermissionsAsync();
  if (permission.status !== "granted") return undefined;
  if (process.env.EXPO_OS === "android") {
    await Notifications.setNotificationChannelAsync("macscope-alerts", {
      name: "MacScope alerts",
      importance: Notifications.AndroidImportance.HIGH,
    });
  }
  const projectId = Constants.expoConfig?.extra?.eas?.projectId as string | undefined;
  if (!projectId || projectId.startsWith("replace-")) return undefined;
  return (await Notifications.getExpoPushTokenAsync({ projectId })).data;
}

function normalizePrepared(payload: Record<string, unknown>): PreparedCommand {
  return {
    schemaVersion: 1,
    commandID: String(payload.commandID),
    approvalToken: String(payload.approvalToken),
    actionID: String(payload.actionID ?? "macos.feature"),
    title: typeof payload.title === "string" ? payload.title : undefined,
    summary: typeof payload.summary === "string" ? payload.summary : typeof payload.warning === "string" ? payload.warning : undefined,
    risk: isRisk(payload.risk) ? payload.risk : "sensitive",
    confirmation: String(payload.confirmation),
    expiresAt: String(payload.expiresAt),
    requiresDeviceAuthentication: payload.requiresDeviceAuthentication === true,
    warning: typeof payload.warning === "string" ? payload.warning : undefined,
    restartEffect: typeof payload.restartEffect === "string" ? payload.restartEffect : undefined,
  };
}

function isRisk(value: unknown): value is PreparedCommand["risk"] {
  return value === "read_only" || value === "mutation" || value === "sensitive" || value === "destructive";
}

function newID(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
}
