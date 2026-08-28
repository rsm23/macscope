import Foundation
import MacScopeCore

public enum MacScopeMCPSnapshotSection: String, Codable, CaseIterable, Sendable {
    case summary
    case cpu
    case memory
    case battery
    case network
    case storage
    case processes
    case startup
    case hardware
    case thermals
    case accelerators
    case metrics
    case all
}

public struct MacScopeMCPSnapshotQuery: Sendable {
    public var sections: [MacScopeMCPSnapshotSection]
    public var includeSensitive: Bool
    public var processLimit: Int
    public var processQuery: String?

    public init(
        sections: [MacScopeMCPSnapshotSection] = [.summary],
        includeSensitive: Bool = false,
        processLimit: Int = 250,
        processQuery: String? = nil
    ) {
        self.sections = sections.isEmpty ? [.summary] : sections
        self.includeSensitive = includeSensitive
        self.processLimit = min(max(processLimit, 0), 5_000)
        self.processQuery = processQuery
    }
}

public struct MacScopeMCPFeatureQuery: Sendable {
    public var query: String?
    public var category: MacOSFeatureCategory?
    public var tier: MacOSFeatureTier?
    public var state: MacOSFeatureEffectiveState?
    public var availability: DataAvailability?
    public var limit: Int

    public init(
        query: String? = nil,
        category: MacOSFeatureCategory? = nil,
        tier: MacOSFeatureTier? = nil,
        state: MacOSFeatureEffectiveState? = nil,
        availability: DataAvailability? = nil,
        limit: Int = 500
    ) {
        self.query = query
        self.category = category
        self.tier = tier
        self.state = state
        self.availability = availability
        self.limit = min(max(limit, 1), 1_000)
    }
}

public struct MacScopeMCPConfiguration: Codable, Hashable, Sendable {
    public var allowSensitiveReads: Bool
    public var allowFeatureWrites: Bool
    public var allowExperimentalFeatureWrites: Bool
    public var allowUtilityWrites: Bool
    public var allowArtifactReads: Bool
    public var approvalLifetimeSeconds: TimeInterval
    public var undoLifetimeSeconds: TimeInterval

    public init(
        allowSensitiveReads: Bool = false,
        allowFeatureWrites: Bool = false,
        allowExperimentalFeatureWrites: Bool = false,
        allowUtilityWrites: Bool = false,
        allowArtifactReads: Bool = false,
        approvalLifetimeSeconds: TimeInterval = 120,
        undoLifetimeSeconds: TimeInterval = 600
    ) {
        self.allowSensitiveReads = allowSensitiveReads
        self.allowFeatureWrites = allowFeatureWrites
        self.allowExperimentalFeatureWrites = allowExperimentalFeatureWrites
        self.allowUtilityWrites = allowUtilityWrites
        self.allowArtifactReads = allowArtifactReads
        self.approvalLifetimeSeconds = min(max(approvalLifetimeSeconds, 15), 600)
        self.undoLifetimeSeconds = min(max(undoLifetimeSeconds, 60), 3_600)
    }
}

public protocol MacScopeMCPSnapshotSource: Sendable {
    func currentSnapshot() async throws -> SystemSnapshot
    func recentSnapshots(limit: Int) async throws -> [SystemSnapshot]
}

public protocol MacScopeMCPFeatureAccess: Sendable {
    func refresh() async -> [MacOSFeatureStatus]
    func setEnabled(_ enabled: Bool, descriptorID: String) async throws -> MacOSFeatureChange
    func restore(_ change: MacOSFeatureChange) async throws
}

public protocol MacScopeMCPUtilityAccess: Sendable {
    func state(
        module: MacScopeMCPUtilityModule,
        includeSensitive: Bool
    ) async throws -> MacScopeMCPJSONValue
    func run(
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) async throws -> MacScopeMCPJSONValue
}

public struct UnavailableMacScopeMCPUtilityAccess: MacScopeMCPUtilityAccess {
    public init() {}

    public func state(
        module: MacScopeMCPUtilityModule,
        includeSensitive: Bool
    ) async throws -> MacScopeMCPJSONValue {
        throw MacScopeMCPError.utilityAppUnavailable
    }

    public func run(
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) async throws -> MacScopeMCPJSONValue {
        throw MacScopeMCPError.utilityAppUnavailable
    }
}

extension MacOSFeatureManager: MacScopeMCPFeatureAccess {}

public enum MacScopeMCPError: LocalizedError, Sendable {
    case encodingFailed
    case snapshotUnavailable
    case sensitiveReadsDisabled
    case unknownFeature(String)
    case featureWritesDisabled
    case experimentalWritesDisabled
    case featureNotWritable(String)
    case alreadyInRequestedState
    case expiredOrUnknownApproval
    case staleApproval
    case staleUndo
    case invalidConfirmation(expected: String)
    case expiredOrUnknownUndo
    case utilityWritesDisabled
    case artifactReadsDisabled
    case unknownUtilityAction(String)
    case utilityAppUnavailable
    case utilityRequestFailed(String)
    case unknownArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "MacScope could not encode the requested data."
        case .snapshotUnavailable: "MacScope did not produce a telemetry snapshot before the timeout."
        case .sensitiveReadsDisabled: "Sensitive fields are disabled. Start the server with --allow-sensitive-read to request them."
        case .unknownFeature(let id): "Unknown macOS feature identifier: \(id)."
        case .featureWritesDisabled: "Feature writes are disabled. Start the server with --allow-feature-writes."
        case .experimentalWritesDisabled: "Experimental feature writes require --allow-experimental-feature-writes."
        case .featureNotWritable(let reason): reason
        case .alreadyInRequestedState: "The feature is already in the requested state."
        case .expiredOrUnknownApproval: "The feature-change approval is unknown, expired, or already used. Prepare the change again."
        case .staleApproval: "The feature state changed after preflight. Prepare the change again before applying it."
        case .staleUndo: "The feature changed after the MCP operation. Refusing to overwrite the newer value."
        case .invalidConfirmation(let expected): "Confirmation did not match. Use exactly: \(expected)"
        case .expiredOrUnknownUndo: "The undo token is unknown, expired, or already used."
        case .utilityWritesDisabled: "Utility execution is disabled. Start the server with --allow-utility-writes."
        case .artifactReadsDisabled: "Screenshot and recording bytes are disabled. Start the server with --allow-artifact-read."
        case .unknownUtilityAction(let id): "Unknown utility action identifier: \(id)."
        case .utilityAppUnavailable: "The running MacScope app did not answer the utility request. Launch the matching MacScope.app bundle and try again."
        case .utilityRequestFailed(let detail): detail
        case .unknownArtifact(let id): "Unknown or no-longer-available artifact identifier: \(id)."
        }
    }
}

public actor MacScopeMCPGateway {
    public static let schemaVersion = 1

    private struct PendingApproval: Sendable {
        let status: MacOSFeatureStatus
        let enabled: Bool
        let confirmation: String
        let expiresAt: Date
    }

    private struct PendingUndo: Sendable {
        let change: MacOSFeatureChange
        let featureTitle: String
        let expectedState: MacOSFeatureEffectiveState
        let expectedStoredValue: MacOSFeaturePreferenceValue?
        let confirmation: String
        let expiresAt: Date
    }

    private let snapshotSource: any MacScopeMCPSnapshotSource
    private let featureAccess: any MacScopeMCPFeatureAccess
    private let utilityAccess: any MacScopeMCPUtilityAccess
    public let configuration: MacScopeMCPConfiguration
    private var approvals: [String: PendingApproval] = [:]
    private var undos: [String: PendingUndo] = [:]

    public init(
        snapshotSource: any MacScopeMCPSnapshotSource,
        featureAccess: any MacScopeMCPFeatureAccess,
        utilityAccess: any MacScopeMCPUtilityAccess = UnavailableMacScopeMCPUtilityAccess(),
        configuration: MacScopeMCPConfiguration = .init()
    ) {
        self.snapshotSource = snapshotSource
        self.featureAccess = featureAccess
        self.utilityAccess = utilityAccess
        self.configuration = configuration
    }

    public func serverInformation() throws -> MacScopeMCPJSONValue {
        try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "server": .string("MacScope MCP Server"),
            "transport": .string("stdio"),
            "sensitiveReadsEnabled": .bool(configuration.allowSensitiveReads),
            "featureWritesEnabled": .bool(configuration.allowFeatureWrites),
            "experimentalFeatureWritesEnabled": .bool(configuration.allowExperimentalFeatureWrites),
            "utilityWritesEnabled": .bool(configuration.allowUtilityWrites),
            "artifactReadsEnabled": .bool(configuration.allowArtifactReads),
            "utilityModules": .array(MacScopeMCPUtilityModule.allCases.map { .string($0.rawValue) }),
            "utilityActionCount": .integer(Int64(MacScopeMCPUtilityCatalog.actions.count)),
            "snapshotSections": .array(MacScopeMCPSnapshotSection.allCases.map { .string($0.rawValue) })
        ])
    }

    public func snapshot(_ query: MacScopeMCPSnapshotQuery) async throws -> MacScopeMCPJSONValue {
        try authorizeSensitiveRead(query.includeSensitive)
        let snapshot = try await snapshotSource.currentSnapshot()
        return try snapshotDocument(snapshot, query: query)
    }

    public func history(
        query: MacScopeMCPSnapshotQuery,
        limit: Int
    ) async throws -> MacScopeMCPJSONValue {
        try authorizeSensitiveRead(query.includeSensitive)
        let boundedLimit = min(max(limit, 1), 300)
        let snapshots = try await snapshotSource.recentSnapshots(limit: boundedLimit)
        let values = try snapshots.map { try snapshotDocument($0, query: query) }
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "count": .integer(Int64(values.count)),
            "samples": .array(values)
        ])
    }

    public func listFeatures(_ query: MacScopeMCPFeatureQuery = .init()) async throws -> MacScopeMCPJSONValue {
        let statuses = await featureAccess.refresh()
        let filtered = statuses.filter { status in
            if let category = query.category, status.descriptor.category != category { return false }
            if let tier = query.tier, status.descriptor.tier != tier { return false }
            if let state = query.state, status.state != state { return false }
            if let availability = query.availability, status.availability != availability { return false }
            guard let search = query.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty else { return true }
            let haystack = [
                status.descriptor.id,
                status.descriptor.title,
                status.descriptor.summary,
                status.descriptor.category.rawValue,
                status.descriptor.provenance,
                status.detail ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(search.lowercased())
        }
        let limited = Array(filtered.prefix(query.limit))
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "total": .integer(Int64(statuses.count)),
            "matched": .integer(Int64(filtered.count)),
            "returned": .integer(Int64(limited.count)),
            "features": try .encode(limited)
        ])
    }

    public func feature(id: String) async throws -> MacScopeMCPJSONValue {
        guard let status = await featureStatus(id: id) else { throw MacScopeMCPError.unknownFeature(id) }
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "feature": try .encode(status)
        ])
    }

    public func prepareFeatureChange(id: String, enabled: Bool) async throws -> MacScopeMCPJSONValue {
        purgeExpiredTokens()
        guard configuration.allowFeatureWrites else { throw MacScopeMCPError.featureWritesDisabled }
        guard let status = await featureStatus(id: id) else { throw MacScopeMCPError.unknownFeature(id) }
        guard case .preference(let preference) = status.descriptor.mechanism else {
            throw MacScopeMCPError.featureNotWritable(status.detail ?? "This catalog entry is read-only.")
        }
        if status.descriptor.tier == .experimental && !configuration.allowExperimentalFeatureWrites {
            throw MacScopeMCPError.experimentalWritesDisabled
        }
        if (enabled && status.state == .enabled) || (!enabled && status.state == .disabled) {
            throw MacScopeMCPError.alreadyInRequestedState
        }

        let token = UUID().uuidString.lowercased()
        let action = enabled ? "ENABLE" : "DISABLE"
        let confirmation = "APPLY \(id) \(action)"
        let expiresAt = Date().addingTimeInterval(configuration.approvalLifetimeSeconds)
        approvals[token] = PendingApproval(
            status: status,
            enabled: enabled,
            confirmation: confirmation,
            expiresAt: expiresAt
        )

        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "approvalToken": .string(token),
            "expiresAt": try .encode(expiresAt),
            "confirmation": .string(confirmation),
            "feature": try .encode(status),
            "requestedState": .string(enabled ? "enabled" : "disabled"),
            "preferenceDomain": .string(preference.domain),
            "preferenceKey": .string(preference.key),
            "restartEffect": .string(preference.restart.displayName),
            "warning": .string("Applying this token changes a local macOS preference. Verify the exact feature, current state, requested state, and restart effect before continuing.")
        ])
    }

    public func applyFeatureChange(
        approvalToken: String,
        confirmation: String
    ) async throws -> MacScopeMCPJSONValue {
        purgeExpiredTokens()
        guard configuration.allowFeatureWrites else { throw MacScopeMCPError.featureWritesDisabled }
        guard let pending = approvals.removeValue(forKey: approvalToken) else {
            throw MacScopeMCPError.expiredOrUnknownApproval
        }
        guard confirmation == pending.confirmation else {
            throw MacScopeMCPError.invalidConfirmation(expected: pending.confirmation)
        }
        guard let current = await featureStatus(id: pending.status.id),
              current.state == pending.status.state,
              current.storedValue == pending.status.storedValue else {
            throw MacScopeMCPError.staleApproval
        }

        let change = try await featureAccess.setEnabled(pending.enabled, descriptorID: pending.status.id)
        guard let updated = await featureStatus(id: pending.status.id) else {
            throw MacScopeMCPError.unknownFeature(pending.status.id)
        }
        let undoToken = UUID().uuidString.lowercased()
        let undoConfirmation = "UNDO \(pending.status.id)"
        let undoExpiresAt = Date().addingTimeInterval(configuration.undoLifetimeSeconds)
        undos[undoToken] = PendingUndo(
            change: change,
            featureTitle: pending.status.descriptor.title,
            expectedState: updated.state,
            expectedStoredValue: updated.storedValue,
            confirmation: undoConfirmation,
            expiresAt: undoExpiresAt
        )

        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "applied": .bool(true),
            "feature": try .encode(updated),
            "note": change.note.map(MacScopeMCPJSONValue.string) ?? .null,
            "undoToken": .string(undoToken),
            "undoConfirmation": .string(undoConfirmation),
            "undoExpiresAt": try .encode(undoExpiresAt)
        ])
    }

    public func undoFeatureChange(
        undoToken: String,
        confirmation: String
    ) async throws -> MacScopeMCPJSONValue {
        purgeExpiredTokens()
        guard configuration.allowFeatureWrites else { throw MacScopeMCPError.featureWritesDisabled }
        guard let pending = undos.removeValue(forKey: undoToken) else {
            throw MacScopeMCPError.expiredOrUnknownUndo
        }
        guard confirmation == pending.confirmation else {
            throw MacScopeMCPError.invalidConfirmation(expected: pending.confirmation)
        }
        guard let current = await featureStatus(id: pending.change.descriptorID),
              current.state == pending.expectedState,
              current.storedValue == pending.expectedStoredValue else {
            throw MacScopeMCPError.staleUndo
        }
        try await featureAccess.restore(pending.change)
        guard let restored = await featureStatus(id: pending.change.descriptorID) else {
            throw MacScopeMCPError.unknownFeature(pending.change.descriptorID)
        }
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "restored": .bool(true),
            "featureTitle": .string(pending.featureTitle),
            "feature": try .encode(restored)
        ])
    }

    public func listUtilities(module: MacScopeMCPUtilityModule? = nil) throws -> MacScopeMCPJSONValue {
        let actions = MacScopeMCPUtilityCatalog.actions.filter { module == nil || $0.module == module }
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "utilityWritesEnabled": .bool(configuration.allowUtilityWrites),
            "artifactReadsEnabled": .bool(configuration.allowArtifactReads),
            "modules": try .encode(MacScopeMCPUtilityModule.allCases),
            "count": .integer(Int64(actions.count)),
            "actions": try .encode(actions)
        ])
    }

    public func utilityState(
        module: MacScopeMCPUtilityModule,
        includeSensitive: Bool
    ) async throws -> MacScopeMCPJSONValue {
        try authorizeSensitiveRead(includeSensitive)
        let state = try await utilityAccess.state(module: module, includeSensitive: includeSensitive)
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "module": .string(module.rawValue),
            "redacted": .bool(!includeSensitive),
            "state": includeSensitive ? state : state.redactingSensitiveFields()
        ])
    }

    public func runUtility(
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) async throws -> MacScopeMCPJSONValue {
        guard configuration.allowUtilityWrites else { throw MacScopeMCPError.utilityWritesDisabled }
        guard let action = MacScopeMCPUtilityCatalog.action(id: actionID) else {
            throw MacScopeMCPError.unknownUtilityAction(actionID)
        }
        let result = try await utilityAccess.run(actionID: actionID, arguments: arguments)
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "accepted": .bool(true),
            "action": try .encode(action),
            "result": result
        ])
    }

    public func listArtifacts(
        kind: MacScopeMCPArtifactKind?,
        includeSensitive: Bool,
        limit: Int
    ) throws -> MacScopeMCPJSONValue {
        try authorizeSensitiveRead(includeSensitive)
        let artifacts = MacScopeMCPArtifactStore.list(
            kind: kind,
            includeSensitive: includeSensitive,
            limit: limit
        )
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "redacted": .bool(!includeSensitive),
            "artifactReadsEnabled": .bool(configuration.allowArtifactReads),
            "count": .integer(Int64(artifacts.count)),
            "artifacts": try .encode(artifacts)
        ])
    }

    public func readArtifact(id: String, offset: Int64, length: Int) throws -> MacScopeMCPJSONValue {
        guard configuration.allowArtifactReads else { throw MacScopeMCPError.artifactReadsDisabled }
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "chunk": try .encode(MacScopeMCPArtifactStore.read(id: id, offset: offset, length: length))
        ])
    }

    private func authorizeSensitiveRead(_ requested: Bool) throws {
        if requested && !configuration.allowSensitiveReads {
            throw MacScopeMCPError.sensitiveReadsDisabled
        }
    }

    private func featureStatus(id: String) async -> MacOSFeatureStatus? {
        await featureAccess.refresh().first { $0.id == id }
    }

    private func purgeExpiredTokens(now: Date = .now) {
        approvals = approvals.filter { $0.value.expiresAt > now }
        undos = undos.filter { $0.value.expiresAt > now }
    }

    private func snapshotDocument(
        _ snapshot: SystemSnapshot,
        query: MacScopeMCPSnapshotQuery
    ) throws -> MacScopeMCPJSONValue {
        let filteredSnapshot = snapshotWithFilteredProcesses(snapshot, query: query)
        guard case .object(let root) = try MacScopeMCPJSONValue.encode(filteredSnapshot) else {
            throw MacScopeMCPError.encodingFailed
        }
        let requested = Set(query.sections)
        let data: MacScopeMCPJSONValue
        if requested.contains(.all) {
            data = .object(root)
        } else {
            var sections: [String: MacScopeMCPJSONValue] = [:]
            for section in requested {
                sections[section.rawValue] = sectionValue(section, snapshot: filteredSnapshot, root: root)
            }
            data = .object(sections)
        }
        let protectedData = query.includeSensitive ? data : data.redactingSensitiveFields()
        return try document([
            "schemaVersion": .integer(Int64(Self.schemaVersion)),
            "sampledAt": try .encode(snapshot.timestamp),
            "redacted": .bool(!query.includeSensitive),
            "requestedSections": .array(query.sections.map { .string($0.rawValue) }),
            "collectionCounts": .object([
                "totalProcesses": .integer(Int64(snapshot.processes.count)),
                "returnedProcesses": .integer(Int64(filteredSnapshot.processes.count)),
                "startupItems": .integer(Int64(snapshot.startupItems.count)),
                "networkConnections": .integer(Int64(snapshot.connections.count))
            ]),
            "data": protectedData
        ])
    }

    private func snapshotWithFilteredProcesses(
        _ snapshot: SystemSnapshot,
        query: MacScopeMCPSnapshotQuery
    ) -> SystemSnapshot {
        let search = query.processQuery?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = snapshot.processes.filter { process in
            guard let search, !search.isEmpty else { return true }
            return process.name.lowercased().contains(search)
                || process.executablePath?.lowercased().contains(search) == true
                || String(process.pid).contains(search)
        }
        let processes = Array(matches.prefix(query.processLimit))
        return SystemSnapshot(
            timestamp: snapshot.timestamp,
            cpuUsage: snapshot.cpuUsage,
            cpuUser: snapshot.cpuUser,
            cpuSystem: snapshot.cpuSystem,
            loadAverages: snapshot.loadAverages,
            cores: snapshot.cores,
            memory: snapshot.memory,
            battery: snapshot.battery,
            networks: snapshot.networks,
            disks: snapshot.disks,
            processes: processes,
            startupItems: snapshot.startupItems,
            startupRevision: snapshot.startupRevision,
            smartReports: snapshot.smartReports,
            connections: snapshot.connections,
            inventory: snapshot.inventory,
            deep: snapshot.deep,
            metrics: snapshot.metrics
        )
    }

    private func sectionValue(
        _ section: MacScopeMCPSnapshotSection,
        snapshot: SystemSnapshot,
        root: [String: MacScopeMCPJSONValue]
    ) -> MacScopeMCPJSONValue {
        func values(_ keys: [String]) -> MacScopeMCPJSONValue {
            .object(keys.reduce(into: [:]) { result, key in result[key] = root[key] ?? .null })
        }
        switch section {
        case .summary:
            return .object([
                "timestamp": root["timestamp"] ?? .null,
                "cpuUsage": root["cpuUsage"] ?? .null,
                "loadAverages": root["loadAverages"] ?? .array([]),
                "memory": root["memory"] ?? .object([:]),
                "battery": root["battery"] ?? .object([:]),
                "networkInterfaceCount": .integer(Int64(snapshot.networks.count)),
                "diskCount": .integer(Int64(snapshot.disks.count)),
                "processCount": .integer(Int64(snapshot.processes.count)),
                "startupItemCount": .integer(Int64(snapshot.startupItems.count)),
                "thermalSensorCount": .integer(Int64(snapshot.deep.sensors.count)),
                "fanCount": .integer(Int64(snapshot.deep.fanSpeeds.count)),
                "deepTelemetryAvailability": .string(snapshot.deep.availability.rawValue)
            ])
        case .cpu: return values(["timestamp", "cpuUsage", "cpuUser", "cpuSystem", "loadAverages", "cores"])
        case .memory: return root["memory"] ?? .object([:])
        case .battery: return root["battery"] ?? .object([:])
        case .network: return values(["networks", "connections"])
        case .storage: return values(["disks", "smartReports"])
        case .processes: return root["processes"] ?? .array([])
        case .startup: return values(["startupItems", "startupRevision"])
        case .hardware: return root["inventory"] ?? .object([:])
        case .thermals:
            return .object([
                "thermalPressure": root["deep"]?.objectValue?["thermalPressure"] ?? .null,
                "sensors": root["deep"]?.objectValue?["sensors"] ?? .object([:]),
                "fanSpeeds": root["deep"]?.objectValue?["fanSpeeds"] ?? .object([:]),
                "availability": root["deep"]?.objectValue?["availability"] ?? .null,
                "detail": root["deep"]?.objectValue?["detail"] ?? .null
            ])
        case .accelerators:
            return values(["deep"])
        case .metrics: return root["metrics"] ?? .array([])
        case .all: return .object(root)
        }
    }

    private func document(_ values: [String: MacScopeMCPJSONValue]) throws -> MacScopeMCPJSONValue {
        .object(values)
    }
}
