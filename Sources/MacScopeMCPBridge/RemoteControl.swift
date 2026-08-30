import Foundation
import MacScopeCore

public enum MacScopeRemoteRole: String, Codable, CaseIterable, Hashable, Sendable {
    case viewer
    case `operator`
    case owner

    public var canWrite: Bool { self == .operator || self == .owner }
    public var canManageAccess: Bool { self == .owner }
}

public enum MacScopeRemoteUtilityRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnly = "read_only"
    case mutation
    case sensitive
    case destructive

    public var requiresConfirmation: Bool { self != .readOnly }
    public var requiresDeviceAuthentication: Bool { self == .sensitive || self == .destructive }
}

public extension MacScopeMCPUtilityActionDescriptor {
    /// Remote calls default closed: actions that produce local artifacts or need
    /// protected macOS permissions are sensitive, and explicit destructive
    /// actions always receive the strongest confirmation flow.
    var remoteRisk: MacScopeRemoteUtilityRisk {
        if destructive { return .destructive }
        if producesArtifact || !requiredPermissions.isEmpty { return .sensitive }
        let readOnlySuffixes = [".refresh", ".load-sources"]
        if readOnlySuffixes.contains(where: id.hasSuffix) { return .readOnly }
        return .mutation
    }
}

public struct MacScopeRemoteMetricFrameV1: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let timestamp: Date
    public let cpuPercent: Double
    public let memoryPercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let gpuPercent: Double?
    public let anePercent: Double?
    public let thermalPressure: String?
    public let hottestSensorCelsius: Double?
    public let systemPowerWatts: Double?
    public let batteryPercent: Double?
    public let batteryCharging: Bool
    public let networkDownloadBytesPerSecond: Double
    public let networkUploadBytesPerSecond: Double
    public let storageUsedBytes: UInt64
    public let storageTotalBytes: UInt64
    public let alertState: String
    public let activeAlertCount: Int
    public let deepTelemetryAvailability: DataAvailability
    public let measuredMetricCount: Int
    public let degradedMetricCount: Int

    public init(snapshot: SystemSnapshot, alertState: String = "normal", activeAlertCount: Int = 0) {
        schemaVersion = Self.schemaVersion
        timestamp = snapshot.timestamp
        cpuPercent = snapshot.cpuUsage
        memoryUsedBytes = snapshot.memory.used
        memoryTotalBytes = snapshot.memory.total
        memoryPercent = snapshot.memory.total > 0
            ? Double(snapshot.memory.used) / Double(snapshot.memory.total) * 100
            : 0
        gpuPercent = snapshot.deep.gpuUsage
        anePercent = snapshot.deep.aneUsage
        thermalPressure = snapshot.deep.thermalPressure
        hottestSensorCelsius = snapshot.deep.sensors.values.filter(\.isFinite).max()
        systemPowerWatts = snapshot.battery.systemPowerWatts
        batteryPercent = snapshot.battery.chargePercent
        batteryCharging = snapshot.battery.isCharging
        networkDownloadBytesPerSecond = snapshot.networks.reduce(0) { $0 + $1.downloadRate }
        networkUploadBytesPerSecond = snapshot.networks.reduce(0) { $0 + $1.uploadRate }
        storageUsedBytes = snapshot.disks.reduce(0) { $0 + $1.used }
        storageTotalBytes = snapshot.disks.reduce(0) { $0 + $1.total }
        self.alertState = alertState
        self.activeAlertCount = max(activeAlertCount, 0)
        deepTelemetryAvailability = snapshot.deep.availability
        measuredMetricCount = snapshot.metrics.count { $0.quality == .measured && $0.availability == .available }
        degradedMetricCount = snapshot.metrics.count { $0.availability != .available }
    }
}

public struct MacScopeRemotePresenceV1: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let environmentID: String
    public let macName: String
    public let online: Bool
    public let appVersion: String
    public let protocolVersion: Int
    public let lastHeartbeatAt: Date
    public let capabilities: [String]

    public init(
        environmentID: String,
        macName: String,
        online: Bool,
        appVersion: String,
        lastHeartbeatAt: Date = .now,
        capabilities: [String]
    ) {
        schemaVersion = Self.schemaVersion
        self.environmentID = environmentID
        self.macName = macName
        self.online = online
        self.appVersion = appVersion
        protocolVersion = 1
        self.lastHeartbeatAt = lastHeartbeatAt
        self.capabilities = capabilities
    }
}

public enum MacScopeRemoteFeatureKind: String, Codable, Hashable, Sendable {
    case featureHub = "feature_hub"
    case macOS = "macos"
}

public struct MacScopeRemoteFeatureStateV1: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let kind: MacScopeRemoteFeatureKind
    public let title: String
    public let summary: String
    public let enabled: Bool?
    public let writable: Bool
    public let experimental: Bool
    public let availability: DataAvailability

    public init(
        id: String,
        kind: MacScopeRemoteFeatureKind,
        title: String,
        summary: String,
        enabled: Bool?,
        writable: Bool,
        experimental: Bool = false,
        availability: DataAvailability = .available
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.enabled = enabled
        self.writable = writable
        self.experimental = experimental
        self.availability = availability
    }
}

public struct MacScopeRemoteCommandPrepareV1: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let commandID: UUID
    public let actorID: String
    public let role: MacScopeRemoteRole
    public let actionID: String
    public let arguments: [String: MacScopeMCPJSONValue]
    public let expiresAt: Date

    public init(
        commandID: UUID,
        actorID: String,
        role: MacScopeRemoteRole,
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue] = [:],
        expiresAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.commandID = commandID
        self.actorID = String(actorID.prefix(200))
        self.role = role
        self.actionID = actionID
        self.arguments = arguments
        self.expiresAt = expiresAt
    }
}

public struct MacScopeRemotePreparedCommandV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let commandID: UUID
    public let approvalToken: String
    public let actionID: String
    public let title: String
    public let summary: String
    public let risk: MacScopeRemoteUtilityRisk
    public let confirmation: String
    public let expiresAt: Date
    public let requiresDeviceAuthentication: Bool

    public init(
        schemaVersion: Int = 1,
        commandID: UUID,
        approvalToken: String,
        actionID: String,
        title: String,
        summary: String,
        risk: MacScopeRemoteUtilityRisk,
        confirmation: String,
        expiresAt: Date,
        requiresDeviceAuthentication: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.approvalToken = approvalToken
        self.actionID = actionID
        self.title = title
        self.summary = summary
        self.risk = risk
        self.confirmation = confirmation
        self.expiresAt = expiresAt
        self.requiresDeviceAuthentication = requiresDeviceAuthentication
    }
}

public struct MacScopeRemoteCommandApplyV1: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let commandID: UUID
    public let approvalToken: String
    public let confirmation: String
    public let expiresAt: Date

    public init(commandID: UUID, approvalToken: String, confirmation: String, expiresAt: Date) {
        schemaVersion = Self.schemaVersion
        self.commandID = commandID
        self.approvalToken = approvalToken
        self.confirmation = confirmation
        self.expiresAt = expiresAt
    }
}

public struct MacScopeRemoteCommandResultV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let commandID: UUID
    public let actionID: String
    public let accepted: Bool
    public let completedAt: Date
    public let result: MacScopeMCPJSONValue?
    public let errorCode: String?
    public let errorMessage: String?

    public init(
        schemaVersion: Int = 1,
        commandID: UUID,
        actionID: String,
        accepted: Bool,
        completedAt: Date = .now,
        result: MacScopeMCPJSONValue? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.actionID = actionID
        self.accepted = accepted
        self.completedAt = completedAt
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct MacScopeRemoteAlertEventV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let timestamp: Date
    public let category: String
    public let title: String
    public let message: String

    public init(event: UsageAlertEvent) {
        schemaVersion = 1
        id = UUID()
        timestamp = event.timestamp
        category = event.metric.rawValue
        title = event.title
        message = event.message
    }
}

public enum MacScopeRemoteWireKind: String, Codable, Sendable {
    case hello
    case presence
    case subscribeMetrics = "subscribe_metrics"
    case unsubscribeMetrics = "unsubscribe_metrics"
    case metricFrame = "metric_frame"
    case featureStates = "feature_states"
    case utilityCatalog = "utility_catalog"
    case utilityStateRequest = "utility_state_request"
    case utilityState = "utility_state"
    case artifactListRequest = "artifact_list_request"
    case artifactList = "artifact_list"
    case artifactReadRequest = "artifact_read_request"
    case artifactChunk = "artifact_chunk"
    case snapshotRequest = "snapshot_request"
    case snapshot = "snapshot"
    case commandPrepare = "command_prepare"
    case commandPrepared = "command_prepared"
    case commandApply = "command_apply"
    case commandResult = "command_result"
    case alert
    case heartbeat
    case error
}

public struct MacScopeRemoteWireEnvelopeV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let kind: MacScopeRemoteWireKind
    public let sentAt: Date
    public let environmentID: String?
    public let payload: MacScopeMCPJSONValue

    public init(
        id: UUID = UUID(),
        kind: MacScopeRemoteWireKind,
        environmentID: String? = nil,
        payload: MacScopeMCPJSONValue = .object([:])
    ) {
        schemaVersion = 1
        self.id = id
        self.kind = kind
        sentAt = .now
        self.environmentID = environmentID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, sentAt, environmentID, payload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported MacScope Remote protocol version."
            )
        }
        self.schemaVersion = schemaVersion
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(MacScopeRemoteWireKind.self, forKey: .kind)
        sentAt = try values.decode(Date.self, forKey: .sentAt)
        environmentID = try values.decodeIfPresent(String.self, forKey: .environmentID)
        payload = try values.decode(MacScopeMCPJSONValue.self, forKey: .payload)
    }
}

public enum MacScopeRemotePolicyError: LocalizedError, Sendable {
    case unsupportedSchema
    case expired
    case roleDenied
    case actionNotAllowed
    case unknownAction
    case replayed
    case invalidApproval

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The remote protocol version is not supported."
        case .expired: "The remote command expired before it reached this Mac."
        case .roleDenied: "This member role cannot change the Mac."
        case .actionNotAllowed: "This action is disabled in MacScope Remote settings."
        case .unknownAction: "The action is not in MacScope's typed allowlist."
        case .replayed: "This command was already handled."
        case .invalidApproval: "The approval is unknown, expired, or does not match the command."
        }
    }
}

public actor MacScopeRemoteCommandPolicy {
    private struct Pending: Sendable {
        let request: MacScopeRemoteCommandPrepareV1
        let action: MacScopeMCPUtilityActionDescriptor
        let token: String
        let confirmation: String
        let expiresAt: Date
    }

    private var allowedActions: Set<String>
    private var pending: [String: Pending] = [:]
    private var handled: [UUID: Date] = [:]
    private let approvalLifetime: TimeInterval
    private let replayLifetime: TimeInterval

    public init(
        allowedActions: Set<String> = Set(MacScopeMCPUtilityCatalog.actions.map(\.id)),
        approvalLifetime: TimeInterval = 120,
        replayLifetime: TimeInterval = 600
    ) {
        self.allowedActions = allowedActions
        self.approvalLifetime = min(max(approvalLifetime, 15), 600)
        self.replayLifetime = min(max(replayLifetime, 60), 3_600)
    }

    public func setAllowedActions(_ actions: Set<String>) {
        allowedActions = actions
    }

    public func prepare(
        _ request: MacScopeRemoteCommandPrepareV1,
        now: Date = .now
    ) throws -> MacScopeRemotePreparedCommandV1 {
        purge(now: now)
        guard request.schemaVersion == 1 else { throw MacScopeRemotePolicyError.unsupportedSchema }
        guard request.expiresAt > now else { throw MacScopeRemotePolicyError.expired }
        guard request.role.canWrite else { throw MacScopeRemotePolicyError.roleDenied }
        guard handled[request.commandID] == nil else { throw MacScopeRemotePolicyError.replayed }
        guard let action = MacScopeMCPUtilityCatalog.action(id: request.actionID) else {
            throw MacScopeRemotePolicyError.unknownAction
        }
        guard allowedActions.contains(action.id) else { throw MacScopeRemotePolicyError.actionNotAllowed }

        let token = UUID().uuidString.lowercased()
        let confirmation = "RUN \(action.id)"
        let expiresAt = min(request.expiresAt, now.addingTimeInterval(approvalLifetime))
        pending[token] = Pending(
            request: request,
            action: action,
            token: token,
            confirmation: confirmation,
            expiresAt: expiresAt
        )
        return MacScopeRemotePreparedCommandV1(
            schemaVersion: 1,
            commandID: request.commandID,
            approvalToken: token,
            actionID: action.id,
            title: action.title,
            summary: action.summary,
            risk: action.remoteRisk,
            confirmation: confirmation,
            expiresAt: expiresAt,
            requiresDeviceAuthentication: action.remoteRisk.requiresDeviceAuthentication
        )
    }

    public func authorize(
        _ request: MacScopeRemoteCommandApplyV1,
        now: Date = .now
    ) throws -> MacScopeRemoteCommandPrepareV1 {
        purge(now: now)
        guard request.schemaVersion == 1 else { throw MacScopeRemotePolicyError.unsupportedSchema }
        guard request.expiresAt > now else { throw MacScopeRemotePolicyError.expired }
        guard handled[request.commandID] == nil else { throw MacScopeRemotePolicyError.replayed }
        guard let approval = pending.removeValue(forKey: request.approvalToken),
              approval.request.commandID == request.commandID,
              approval.expiresAt > now,
              approval.confirmation == request.confirmation else {
            throw MacScopeRemotePolicyError.invalidApproval
        }
        handled[request.commandID] = now
        return approval.request
    }

    private func purge(now: Date) {
        pending = pending.filter { $0.value.expiresAt > now }
        handled = handled.filter { now.timeIntervalSince($0.value) <= replayLifetime }
    }
}
