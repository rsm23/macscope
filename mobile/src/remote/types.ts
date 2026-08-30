export type RemoteRole = "viewer" | "operator" | "owner";
export type RemoteRisk = "read_only" | "mutation" | "sensitive" | "destructive";
export type ConnectionState = "offline" | "connecting" | "online" | "reconnecting" | "error";

export interface StoredEnvironment {
  environmentID: string;
  relayURL: string;
  displayName: string;
  memberID: string;
  deviceID: string;
  role: RemoteRole;
  accessToken: string;
  accessExpiresAt: string;
  refreshToken: string;
  refreshExpiresAt: string;
}

export interface PairingRedemption {
  environmentID: string;
  memberID: string;
  deviceID: string;
  role: RemoteRole;
  accessToken: string;
  accessExpiresAt: string;
  refreshToken: string;
  refreshExpiresAt: string;
}

export interface MetricFrame {
  schemaVersion: 1;
  timestamp: string;
  cpuPercent: number;
  memoryPercent: number;
  memoryUsedBytes: number;
  memoryTotalBytes: number;
  gpuPercent?: number;
  anePercent?: number;
  thermalPressure?: string;
  hottestSensorCelsius?: number;
  systemPowerWatts?: number;
  batteryPercent?: number;
  batteryCharging: boolean;
  networkDownloadBytesPerSecond: number;
  networkUploadBytesPerSecond: number;
  storageUsedBytes: number;
  storageTotalBytes: number;
  alertState: "normal" | "alert";
  activeAlertCount: number;
  deepTelemetryAvailability: string;
  measuredMetricCount: number;
  degradedMetricCount: number;
}

export interface Presence {
  schemaVersion: 1;
  environmentID: string;
  macName: string;
  online: boolean;
  appVersion: string;
  protocolVersion: number;
  lastHeartbeatAt: string;
  capabilities: string[];
}

export interface RemoteFeature {
  schemaVersion: 1;
  id: string;
  kind: "feature_hub" | "macos";
  title: string;
  summary: string;
  enabled: boolean | null;
  writable: boolean;
  experimental: boolean;
  availability: string;
}

export interface UtilityAction {
  id: string;
  module: string;
  title: string;
  summary: string;
  arguments: Record<string, string>;
  risk: RemoteRisk;
  allowed: boolean;
  requiresDeviceAuthentication: boolean;
}

export interface PreparedCommand {
  schemaVersion: 1;
  commandID: string;
  approvalToken: string;
  actionID: string;
  title?: string;
  summary?: string;
  risk: RemoteRisk;
  confirmation: string;
  expiresAt: string;
  requiresDeviceAuthentication: boolean;
  warning?: string;
  restartEffect?: string;
}

export interface CommandResult {
  schemaVersion: 1;
  commandID: string;
  actionID: string;
  accepted: boolean;
  completedAt: string;
  result?: unknown;
  errorCode?: string;
  errorMessage?: string;
}

export interface RemoteMember {
  id: string;
  displayName: string;
  role: RemoteRole;
  deviceCount: number;
  lastSeenAt?: string;
}

export interface AuditEvent {
  id: string;
  actorName: string;
  actionID: string;
  risk: RemoteRisk;
  outcome: string;
  createdAt: string;
}

export interface WireEnvelope<T = Record<string, unknown> | unknown[]> {
  schemaVersion: 1;
  id: string;
  kind: string;
  sentAt: string;
  environmentID?: string;
  payload: T;
}

export interface EnvironmentSummary {
  members: RemoteMember[];
  audit: AuditEvent[];
}

export interface NotificationPreferences {
  alerts: boolean;
  presence: boolean;
  commands: boolean;
}
