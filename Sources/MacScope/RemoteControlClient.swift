import Foundation
import MacScopeCore
import MacScopeMCPBridge
import Observation
import Security

enum RemoteConnectionStatus: Equatable {
    case disabled
    case needsConfiguration
    case enrolling
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .needsConfiguration: "Needs relay URL"
        case .enrolling: "Creating environment…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed: "Connection failed"
        }
    }

    var isConnected: Bool { self == .connected }
}

struct RemoteMemberSummary: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let role: MacScopeRemoteRole
    let deviceCount: Int
    let lastSeenAt: Date?
}

struct RemoteAuditSummary: Codable, Hashable, Identifiable {
    let id: String
    let actorName: String
    let actionID: String
    let risk: MacScopeRemoteUtilityRisk
    let outcome: String
    let createdAt: Date
}

private actor SharedRemoteSnapshotSource: MacScopeMCPSnapshotSource {
    private var latest = SystemSnapshot()

    func update(_ snapshot: SystemSnapshot) { latest = snapshot }
    func currentSnapshot() async throws -> SystemSnapshot { latest }
    func recentSnapshots(limit: Int) async throws -> [SystemSnapshot] { [latest] }
}

private final class AppRemoteUtilityAccess: MacScopeMCPUtilityAccess, @unchecked Sendable {
    weak var controller: MacScopeMCPUtilityController?

    init(controller: MacScopeMCPUtilityController) {
        self.controller = controller
    }

    func state(module: MacScopeMCPUtilityModule, includeSensitive: Bool) async throws -> MacScopeMCPJSONValue {
        try await MainActor.run {
            guard let controller else { throw MacScopeMCPError.utilityAppUnavailable }
            return controller.remoteState(module: module, includeSensitive: includeSensitive)
        }
    }

    func run(actionID: String, arguments: [String: MacScopeMCPJSONValue]) async throws -> MacScopeMCPJSONValue {
        try await MainActor.run {
            guard let controller else { throw MacScopeMCPError.utilityAppUnavailable }
            return try controller.remoteRun(actionID: actionID, arguments: arguments)
        }
    }
}

@MainActor
@Observable
final class MacScopeRemoteControlClient {
    static let enabledKey = "remote.enabled"
    static let relayURLKey = "remote.relayURL"
    static let macNameKey = "remote.macName"
    static let allowUtilityWritesKey = "remote.allowUtilityWrites"
    static let allowDestructiveUtilitiesKey = "remote.allowDestructiveUtilities"
    static let allowFeatureHubWritesKey = "remote.allowFeatureHubWrites"
    static let allowMacOSFeatureWritesKey = "remote.allowMacOSFeatureWrites"
    static let allowedUtilityActionsKey = "remote.allowedUtilityActions"
    private static let allowedUtilityCatalogVersionKey = "remote.allowedUtilityCatalogVersion"
    private static let allowedUtilityCatalogVersion = 2
    static let notifyAlertsKey = "remote.notifyAlerts"
    static let notifyPresenceKey = "remote.notifyPresence"
    static let notifyCommandsKey = "remote.notifyCommands"

    var status: RemoteConnectionStatus = .disabled
    var pairingURL: URL?
    var pairingExpiresAt: Date?
    var environmentID: String?
    var members: [RemoteMemberSummary] = []
    var audit: [RemoteAuditSummary] = []
    var lastError: String?
    var lastConnectedAt: Date?
    var isRefreshingPairing = false

    private enum PendingFeatureHub {
        case change(module: UtilityFeatureModule, enabled: Bool, token: String, confirmation: String, expiresAt: Date)
    }

    private struct PendingRemoteCommand {
        let actionID: String
        let expiresAt: Date
    }

    private let controller: MacScopeMCPUtilityController
    private let snapshotSource = SharedRemoteSnapshotSource()
    private let featureManager = MacOSFeatureManager()
    private let commandPolicy = MacScopeRemoteCommandPolicy()
    private var gateway: MacScopeMCPGateway!
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var metricsSubscribed = false
    private var lastMetricSentAt: Date?
    private var lastAlertAt: Date?
    private var pendingFeatureHub: [UUID: PendingFeatureHub] = [:]
    private var pendingCommands: [UUID: PendingRemoteCommand] = [:]
    private var handledCommands: [UUID: Date] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(controller: MacScopeMCPUtilityController) {
        self.controller = controller
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        gateway = MacScopeMCPGateway(
            snapshotSource: snapshotSource,
            featureAccess: featureManager,
            utilityAccess: AppRemoteUtilityAccess(controller: controller),
            configuration: .init(
                allowFeatureWrites: true,
                allowExperimentalFeatureWrites: false,
                allowUtilityWrites: true
            )
        )
    }

    func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            stop()
            return
        }
        guard relayBaseURL != nil else {
            status = .needsConfiguration
            return
        }
        Task { await connectUsingStoredCredentials() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? startIfEnabled() : stop()
    }

    func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        receiveTask?.cancel(); receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        metricsSubscribed = false
        status = .disabled
    }

    func reconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        receiveTask?.cancel(); receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        metricsSubscribed = false
        reconnectAttempt = 1
        Task { await connect() }
    }

    func publishSettingsChanged() {
        guard status.isConnected else { return }
        Task {
            await sendPresence()
            await sendFeatureStates()
            await sendUtilityCatalog()
        }
    }

    static func allowedUtilityActionIDs() -> Set<String> {
        var values = Set(UserDefaults.standard.stringArray(forKey: allowedUtilityActionsKey) ?? [])
        let version = UserDefaults.standard.integer(forKey: allowedUtilityCatalogVersionKey)
        if version < 2, values.count == 88 {
            values.insert("maintenance.process-terminate")
            setAllowedUtilityActionIDs(values)
        }
        return values
    }

    static func setAllowedUtilityActionIDs(_ values: Set<String>) {
        let known = Set(MacScopeMCPUtilityCatalog.actions.map(\.id))
        UserDefaults.standard.set(Array(values.intersection(known)).sorted(), forKey: allowedUtilityActionsKey)
        UserDefaults.standard.set(allowedUtilityCatalogVersion, forKey: allowedUtilityCatalogVersionKey)
    }

    func enroll() async {
        guard let relayBaseURL else { status = .needsConfiguration; return }
        status = .enrolling
        do {
            let body = EnvironmentRegistrationRequest(
                macName: resolvedMacName,
                appVersion: appVersion
            )
            let response: EnvironmentRegistrationResponse = try await request(
                relayBaseURL.appending(path: "v1/environments/register"),
                method: "POST",
                body: body,
                bearer: nil
            )
            try RemoteKeychain.set(response.environmentID, account: "environment-id")
            try RemoteKeychain.set(response.environmentSecret, account: "environment-secret")
            environmentID = response.environmentID
            pairingURL = URL(string: response.pairingURL)
            pairingExpiresAt = response.pairingExpiresAt
            await connect()
        } catch {
            fail(error)
        }
    }

    func refreshPairing(role: MacScopeRemoteRole = .owner) async {
        guard !isRefreshingPairing else { return }
        guard let relayBaseURL else {
            fail(RemoteClientError.invalidRelayURL)
            return
        }

        isRefreshingPairing = true
        defer { isRefreshingPairing = false }
        lastError = nil

        guard let environmentID,
              (try? RemoteKeychain.string(account: "environment-secret")) != nil else {
            await enroll()
            return
        }

        do {
            let secret = try RemoteKeychain.string(account: "environment-secret")
            let response: PairingResponse = try await request(
                relayBaseURL.appending(path: "v1/environments/\(environmentID)/pairings"),
                method: "POST",
                body: PairingRequest(role: role),
                bearer: secret
            )
            pairingURL = URL(string: response.pairingURL)
            pairingExpiresAt = response.expiresAt
            lastError = nil
        } catch {
            fail(error)
        }
    }

    func refreshControlPlane() async {
        guard let relayBaseURL, let environmentID else { return }
        do {
            let secret = try RemoteKeychain.string(account: "environment-secret")
            let response: EnvironmentSummaryResponse = try await request(
                relayBaseURL.appending(path: "v1/environments/\(environmentID)"),
                method: "GET",
                body: Optional<String>.none,
                bearer: secret
            )
            members = response.members
            audit = response.audit
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateNotificationPolicy() async {
        guard let relayBaseURL, let environmentID,
              let secret = try? RemoteKeychain.string(account: "environment-secret") else { return }
        do {
            let _: EmptyResponse = try await request(
                relayBaseURL.appending(path: "v1/environments/\(environmentID)/notifications"),
                method: "PUT",
                body: NotificationPolicyRequest(
                    alerts: Self.defaultEnabled(Self.notifyAlertsKey),
                    presence: Self.defaultEnabled(Self.notifyPresenceKey),
                    commands: Self.defaultEnabled(Self.notifyCommandsKey)
                ),
                bearer: secret
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revokeMember(_ memberID: String) async {
        guard let relayBaseURL, let environmentID else { return }
        do {
            let secret = try RemoteKeychain.string(account: "environment-secret")
            let _: EmptyResponse = try await request(
                relayBaseURL.appending(path: "v1/environments/\(environmentID)/members/\(memberID)"),
                method: "DELETE",
                body: Optional<String>.none,
                bearer: secret
            )
            await refreshControlPlane()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetRemoteAccess() async {
        if let relayBaseURL, let environmentID,
           let secret = try? RemoteKeychain.string(account: "environment-secret") {
            let _: EmptyResponse? = try? await request(
                relayBaseURL.appending(path: "v1/environments/\(environmentID)"),
                method: "DELETE",
                body: Optional<String>.none,
                bearer: secret
            )
        }
        stop()
        try? RemoteKeychain.remove(account: "environment-id")
        try? RemoteKeychain.remove(account: "environment-secret")
        environmentID = nil
        pairingURL = nil
        pairingExpiresAt = nil
        members = []
        audit = []
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    func receive(snapshot: SystemSnapshot) {
        Task { await snapshotSource.update(snapshot) }
        guard metricsSubscribed, status.isConnected else { return }
        if let lastMetricSentAt, snapshot.timestamp.timeIntervalSince(lastMetricSentAt) < 0.9 { return }
        lastMetricSentAt = snapshot.timestamp
        let alertIsActive = lastAlertAt.map { snapshot.timestamp.timeIntervalSince($0) < 60 } ?? false
        Task {
            await sendEncoded(
                kind: .metricFrame,
                value: MacScopeRemoteMetricFrameV1(
                    snapshot: snapshot,
                    alertState: alertIsActive ? "alert" : "normal",
                    activeAlertCount: alertIsActive ? 1 : 0
                )
            )
        }
    }

    func receive(alert: UsageAlertEvent) {
        guard status.isConnected else { return }
        lastAlertAt = alert.timestamp
        Task { await sendEncoded(kind: .alert, value: MacScopeRemoteAlertEventV1(event: alert)) }
    }

    private func connectUsingStoredCredentials() async {
        // Read sequentially so macOS never stacks two Keychain authorization
        // sheets when a newly signed build first reconnects.
        let environmentID = await keychainString(account: "environment-id")
        let secret = await keychainString(account: "environment-secret")
        self.environmentID = environmentID
        guard let environmentID, let secret else {
            await enroll()
            return
        }
        await connect(environmentID: environmentID, secret: secret)
    }

    private func keychainString(account: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            try? RemoteKeychain.string(account: account)
        }.value
    }

    private func connect() async {
        guard let environmentID,
              let secret = await keychainString(account: "environment-secret") else { return }
        await connect(environmentID: environmentID, secret: secret)
    }

    private func connect(environmentID: String, secret: String) async {
        guard socket == nil,
              let relayBaseURL else { return }
        status = reconnectAttempt == 0 ? .connecting : .reconnecting
        do {
            let ticket: WebSocketTicketResponse = try await request(
                relayBaseURL.appending(path: "v1/ws-ticket"),
                method: "POST",
                body: WebSocketTicketRequest(environmentID: environmentID, clientKind: "mac"),
                bearer: secret
            )
            guard var components = URLComponents(url: relayBaseURL.appending(path: "v1/socket"), resolvingAgainstBaseURL: false) else {
                throw RemoteClientError.invalidRelayURL
            }
            components.scheme = components.scheme == "http" ? "ws" : "wss"
            components.queryItems = [URLQueryItem(name: "ticket", value: ticket.ticket)]
            guard let socketURL = components.url else { throw RemoteClientError.invalidRelayURL }
            let task = URLSession.shared.webSocketTask(with: socketURL)
            socket = task
            task.resume()
            status = .connected
            lastConnectedAt = .now
            reconnectAttempt = 0
            lastError = nil
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            heartbeatTask = Task { [weak self] in await self?.heartbeatLoop() }
            await sendPresence()
            await sendFeatureStates()
            await sendUtilityCatalog()
            await updateNotificationPolicy()
            await refreshControlPlane()
        } catch {
            socket = nil
            fail(error)
            scheduleReconnect()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data = switch message {
                case .data(let data): data
                case .string(let text): Data(text.utf8)
                @unknown default: Data()
                }
                guard data.count <= 64 * 1_024 else { throw RemoteClientError.payloadTooLarge }
                let envelope = try decoder.decode(MacScopeRemoteWireEnvelopeV1.self, from: data)
                do {
                    try await handle(envelope)
                } catch {
                    await send(
                        kind: .error,
                        payload: .object([
                            "code": .string(String(describing: type(of: error))),
                            "message": .string(error.localizedDescription)
                        ]),
                        id: envelope.id
                    )
                }
            } catch {
                if !Task.isCancelled { fail(error); disconnectAndReconnect() }
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            await sendPresence()
        }
    }

    private func handle(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        guard envelope.schemaVersion == 1 else { throw MacScopeRemotePolicyError.unsupportedSchema }
        switch envelope.kind {
        case .subscribeMetrics:
            metricsSubscribed = true
            lastMetricSentAt = nil
            await sendPresence()
            await sendFeatureStates()
            await sendUtilityCatalog()
        case .unsubscribeMetrics:
            metricsSubscribed = false
        case .commandPrepare:
            try await handlePrepare(envelope)
        case .commandApply:
            try await handleApply(envelope)
        case .utilityStateRequest:
            try await handleUtilityStateRequest(envelope)
        case .artifactListRequest:
            try await handleArtifactListRequest(envelope)
        case .artifactReadRequest:
            try await handleArtifactReadRequest(envelope)
        case .snapshotRequest:
            try await handleSnapshotRequest(envelope)
        case .heartbeat:
            await sendPresence()
        default:
            break
        }
    }

    private func handleUtilityStateRequest(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        guard case .object(let payload) = envelope.payload,
              case .string(let rawModule)? = payload["module"],
              let module = MacScopeMCPUtilityModule(rawValue: rawModule) else {
            throw MacScopeRemotePolicyError.unknownAction
        }
        let state = controller.remoteState(module: module, includeSensitive: true)
        await sendReply(kind: .utilityState, payload: .object(["module": .string(rawModule), "state": state]), id: envelope.id)
    }

    private func handleArtifactListRequest(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        let requestedKind: MacScopeMCPArtifactKind? = {
            guard case .object(let payload) = envelope.payload,
                  case .string(let rawKind)? = payload["kind"] else { return nil }
            return MacScopeMCPArtifactKind(rawValue: rawKind)
        }()
        let artifacts = MacScopeMCPArtifactStore.list(kind: requestedKind, includeSensitive: false, limit: 100)
        await sendEncodedReply(kind: .artifactList, value: artifacts, id: envelope.id)
    }

    private func handleArtifactReadRequest(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        guard case .object(let payload) = envelope.payload,
              case .string(let artifactID)? = payload["id"] else {
            throw MacScopeRemotePolicyError.unknownAction
        }
        let offset: Int64 = if case .integer(let value)? = payload["offset"] { value } else { 0 }
        let length: Int = if case .integer(let value)? = payload["length"] { Int(value) } else { 32 * 1_024 }
        let chunk = try MacScopeMCPArtifactStore.read(id: artifactID, offset: offset, length: min(length, 32 * 1_024))
        await sendEncodedReply(kind: .artifactChunk, value: chunk, id: envelope.id)
    }

    private func handleSnapshotRequest(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        guard case .object(let payload) = envelope.payload else {
            throw MacScopeRemotePolicyError.unknownAction
        }
        let sections: [MacScopeMCPSnapshotSection] = if case .array(let values)? = payload["sections"] {
            values.compactMap { value in
                guard case .string(let raw) = value else { return nil }
                return MacScopeMCPSnapshotSection(rawValue: raw)
            }
        } else { [.summary] }
        let processLimit: Int = if case .integer(let value)? = payload["processLimit"] { Int(value) } else { 100 }
        let processQuery: String? = if case .string(let value)? = payload["processQuery"] { value } else { nil }
        let collectionLimit: Int = if case .integer(let value)? = payload["collectionLimit"] { Int(value) } else { 150 }
        let document = try await gateway.snapshot(.init(
            sections: sections,
            includeSensitive: false,
            processLimit: min(max(processLimit, 0), 150),
            processQuery: processQuery,
            collectionLimit: min(max(collectionLimit, 1), 150)
        ))
        await sendReply(kind: .snapshot, payload: document, id: envelope.id)
    }

    private func handlePrepare(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        let request = try decode(MacScopeRemoteCommandPrepareV1.self, from: envelope.payload)
        purgeCommandHistory()
        guard request.expiresAt > .now else { throw MacScopeRemotePolicyError.expired }
        guard request.role.canWrite else { throw MacScopeRemotePolicyError.roleDenied }
        guard handledCommands[request.commandID] == nil,
              pendingCommands[request.commandID] == nil else { throw MacScopeRemotePolicyError.replayed }

        if request.actionID == "macos.undo" {
            guard UserDefaults.standard.bool(forKey: Self.allowMacOSFeatureWritesKey),
                  case .string(let undoToken)? = request.arguments["undo_token"],
                  case .string(let undoConfirmation)? = request.arguments["undo_confirmation"],
                  undoConfirmation.hasPrefix("UNDO ") else {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            let expiresAt = min(request.expiresAt, Date.now.addingTimeInterval(15))
            let prepared = MacScopeRemotePreparedCommandV1(
                commandID: request.commandID,
                approvalToken: undoToken,
                actionID: request.actionID,
                title: "Undo macOS feature change",
                summary: "Restore the exact preference value captured before the remote change.",
                risk: .sensitive,
                confirmation: undoConfirmation,
                expiresAt: expiresAt,
                requiresDeviceAuthentication: true
            )
            pendingCommands[request.commandID] = .init(actionID: request.actionID, expiresAt: expiresAt)
            await sendEncoded(kind: .commandPrepared, value: prepared, id: envelope.id)
            return
        }

        if request.actionID.hasPrefix("utility.") {
            guard UserDefaults.standard.bool(forKey: Self.allowUtilityWritesKey) else {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            let actionID = String(request.actionID.dropFirst("utility.".count))
            guard let action = MacScopeMCPUtilityCatalog.action(id: actionID) else {
                throw MacScopeRemotePolicyError.unknownAction
            }
            let allowedActions = Self.allowedUtilityActionIDs()
            guard allowedActions.contains(actionID) else {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            await commandPolicy.setAllowedActions(allowedActions)
            if action.remoteRisk == .destructive,
               !UserDefaults.standard.bool(forKey: Self.allowDestructiveUtilitiesKey) {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            let normalized = MacScopeRemoteCommandPrepareV1(
                commandID: request.commandID,
                actorID: request.actorID,
                role: request.role,
                actionID: actionID,
                arguments: request.arguments,
                expiresAt: request.expiresAt
            )
            let prepared = try await commandPolicy.prepare(normalized)
            pendingCommands[request.commandID] = .init(actionID: request.actionID, expiresAt: prepared.expiresAt)
            await sendEncoded(kind: .commandPrepared, value: prepared, id: envelope.id)
            return
        }

        if request.actionID.hasPrefix("featurehub.") {
            guard UserDefaults.standard.bool(forKey: Self.allowFeatureHubWritesKey) else {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            let moduleID = String(request.actionID.dropFirst("featurehub.".count))
            guard let module = UtilityFeatureModule(rawValue: moduleID),
                  case .bool(let enabled)? = request.arguments["enabled"] else {
                throw MacScopeRemotePolicyError.unknownAction
            }
            let token = UUID().uuidString.lowercased()
            let confirmation = "SET featurehub.\(moduleID) \(enabled ? "ON" : "OFF")"
            let expiresAt = min(request.expiresAt, Date.now.addingTimeInterval(120))
            pendingFeatureHub[request.commandID] = .change(
                module: module,
                enabled: enabled,
                token: token,
                confirmation: confirmation,
                expiresAt: expiresAt
            )
            let prepared = MacScopeRemotePreparedCommandV1(
                schemaVersion: 1,
                commandID: request.commandID,
                approvalToken: token,
                actionID: request.actionID,
                title: "Configure \(module.title)",
                summary: enabled ? "Enable this MacScope module." : "Disable this MacScope module.",
                risk: .mutation,
                confirmation: confirmation,
                expiresAt: expiresAt,
                requiresDeviceAuthentication: false
            )
            pendingCommands[request.commandID] = .init(actionID: request.actionID, expiresAt: expiresAt)
            await sendEncoded(kind: .commandPrepared, value: prepared, id: envelope.id)
            return
        }

        if request.actionID.hasPrefix("macos.") {
            guard UserDefaults.standard.bool(forKey: Self.allowMacOSFeatureWritesKey) else {
                throw MacScopeRemotePolicyError.actionNotAllowed
            }
            let featureID = String(request.actionID.dropFirst("macos.".count))
            guard case .bool(let enabled)? = request.arguments["enabled"] else {
                throw MacScopeRemotePolicyError.unknownAction
            }
            let prepared = try await gateway.prepareFeatureChange(id: featureID, enabled: enabled)
            let payload = prepared.mergingObject([
                "commandID": .string(request.commandID.uuidString.lowercased()),
                "actionID": .string(request.actionID),
                "risk": .string(MacScopeRemoteUtilityRisk.sensitive.rawValue),
                "requiresDeviceAuthentication": .bool(true)
            ])
            pendingCommands[request.commandID] = .init(actionID: request.actionID, expiresAt: request.expiresAt)
            await send(kind: .commandPrepared, payload: payload, id: envelope.id)
            return
        }
        throw MacScopeRemotePolicyError.unknownAction
    }

    private func handleApply(_ envelope: MacScopeRemoteWireEnvelopeV1) async throws {
        let request = try decode(MacScopeRemoteCommandApplyV1.self, from: envelope.payload)
        purgeCommandHistory()
        guard request.expiresAt > .now else { throw MacScopeRemotePolicyError.expired }
        if handledCommands[request.commandID] != nil { throw MacScopeRemotePolicyError.replayed }
        guard let pendingCommand = pendingCommands.removeValue(forKey: request.commandID),
              pendingCommand.expiresAt > .now else { throw MacScopeRemotePolicyError.invalidApproval }
        handledCommands[request.commandID] = .now
        do {
            if let pending = pendingFeatureHub.removeValue(forKey: request.commandID) {
                guard case .change(let module, let enabled, let token, let confirmation, let expiresAt) = pending,
                      token == request.approvalToken,
                      confirmation == request.confirmation,
                      expiresAt > .now else { throw MacScopeRemotePolicyError.invalidApproval }
                let stored = UserDefaults.standard.string(forKey: UtilityFeatureStore.disabledKey) ?? ""
                let updated = UtilityFeatureStore.setEnabled(enabled, module: module, stored: stored)
                UserDefaults.standard.set(updated, forKey: UtilityFeatureStore.disabledKey)
                UtilityFeatureStore.announceChange()
                await sendCommandResult(
                    commandID: request.commandID,
                    actionID: "featurehub.\(module.rawValue)",
                    result: .object(["enabled": .bool(enabled)]),
                    id: envelope.id
                )
                await sendFeatureStates()
                return
            }

            if request.confirmation.hasPrefix("APPLY ") {
                let result = try await gateway.applyFeatureChange(
                    approvalToken: request.approvalToken,
                    confirmation: request.confirmation
                )
                await sendCommandResult(
                    commandID: request.commandID,
                    actionID: pendingCommand.actionID,
                    result: result,
                    id: envelope.id
                )
                await sendFeatureStates()
                return
            }

            if request.confirmation.hasPrefix("UNDO ") {
                let result = try await gateway.undoFeatureChange(
                    undoToken: request.approvalToken,
                    confirmation: request.confirmation
                )
                await sendCommandResult(
                    commandID: request.commandID,
                    actionID: pendingCommand.actionID,
                    result: result,
                    id: envelope.id
                )
                await sendFeatureStates()
                return
            }

            let prepared = try await commandPolicy.authorize(request)
            let result = try await controller.remoteRunAwaitingCompletion(actionID: prepared.actionID, arguments: prepared.arguments)
            await sendCommandResult(
                commandID: request.commandID,
                actionID: "utility.\(prepared.actionID)",
                result: result,
                id: envelope.id
            )
        } catch {
            await sendCommandResult(
                commandID: request.commandID,
                actionID: "unknown",
                error: error,
                id: envelope.id
            )
        }
    }

    private func sendPresence() async {
        guard let environmentID else { return }
        let presence = MacScopeRemotePresenceV1(
            environmentID: environmentID,
            macName: resolvedMacName,
            online: true,
            appVersion: appVersion,
            capabilities: ["metrics", "live_data", "processes", "feature_hub", "macos_features", "utilities", "artifacts", "alerts", "members"]
        )
        await sendEncoded(kind: .presence, value: presence)
    }

    private func sendFeatureStates() async {
        var states = UtilityFeatureModule.allCases.map { module in
            MacScopeRemoteFeatureStateV1(
                id: module.rawValue,
                kind: .featureHub,
                title: module.title,
                summary: module.detail,
                enabled: UtilityFeatureStore.isEnabled(module),
                writable: UserDefaults.standard.bool(forKey: Self.allowFeatureHubWritesKey)
            )
        }
        let macOSStatuses = await featureManager.refresh()
        states.append(contentsOf: macOSStatuses.map { status in
            let enabled: Bool? = switch status.state {
            case .enabled: true
            case .disabled: false
            case .unknown: nil
            }
            let writable: Bool
            if case .preference = status.descriptor.mechanism { writable = true }
            else { writable = false }
            return MacScopeRemoteFeatureStateV1(
                id: status.id,
                kind: .macOS,
                title: status.descriptor.title,
                summary: status.descriptor.summary,
                enabled: enabled,
                writable: writable && UserDefaults.standard.bool(forKey: Self.allowMacOSFeatureWritesKey),
                experimental: status.descriptor.tier == .experimental,
                availability: status.availability
            )
        })
        await sendEncoded(kind: .featureStates, value: states)
    }

    private func sendUtilityCatalog() async {
        let allowWrites = UserDefaults.standard.bool(forKey: Self.allowUtilityWritesKey)
        let allowDestructive = UserDefaults.standard.bool(forKey: Self.allowDestructiveUtilitiesKey)
        let allowedActions = Self.allowedUtilityActionIDs()
        let values: [MacScopeMCPJSONValue] = MacScopeMCPUtilityCatalog.actions.map { action in
            .object([
                "id": .string(action.id),
                "module": .string(action.module.rawValue),
                "title": .string(action.title),
                "summary": .string(action.summary),
                "arguments": .object(action.arguments.mapValues(MacScopeMCPJSONValue.string)),
                "risk": .string(action.remoteRisk.rawValue),
                "allowed": .bool(allowWrites && allowedActions.contains(action.id) && (action.remoteRisk != .destructive || allowDestructive)),
                "requiresDeviceAuthentication": .bool(action.remoteRisk.requiresDeviceAuthentication)
                , "producesArtifact": .bool(action.producesArtifact)
                , "requiredPermissions": .array(action.requiredPermissions.map(MacScopeMCPJSONValue.string))
            ])
        }
        await send(kind: .utilityCatalog, payload: .array(values))
    }

    private func sendCommandResult(
        commandID: UUID,
        actionID: String,
        result: MacScopeMCPJSONValue? = nil,
        error: Error? = nil,
        id: UUID
    ) async {
        let value = MacScopeRemoteCommandResultV1(
            schemaVersion: 1,
            commandID: commandID,
            actionID: actionID,
            accepted: error == nil,
            completedAt: .now,
            result: result,
            errorCode: error.map { String(describing: type(of: $0)) },
            errorMessage: error?.localizedDescription
        )
        await sendEncoded(kind: .commandResult, value: value, id: id)
    }

    private func purgeCommandHistory(now: Date = .now) {
        pendingCommands = pendingCommands.filter { $0.value.expiresAt > now }
        handledCommands = handledCommands.filter { now.timeIntervalSince($0.value) <= 600 }
    }

    private func sendEncoded<T: Encodable>(kind: MacScopeRemoteWireKind, value: T, id: UUID = UUID()) async {
        do { await send(kind: kind, payload: try .encode(value), id: id) }
        catch { lastError = error.localizedDescription }
    }

    private func sendEncodedReply<T: Encodable>(kind: MacScopeRemoteWireKind, value: T, id: UUID) async {
        do { await sendReply(kind: kind, payload: try .encode(value), id: id) }
        catch { await sendReplyError(error, id: id) }
    }

    private func sendReply(kind: MacScopeRemoteWireKind, payload: MacScopeMCPJSONValue, id: UUID) async {
        do {
            try await transmit(kind: kind, payload: payload, id: id)
        } catch {
            await sendReplyError(error, id: id)
        }
    }

    private func sendReplyError(_ error: Error, id: UUID) async {
        lastError = error.localizedDescription
        let code = error is RemoteClientError ? "remote_response_failed" : String(describing: type(of: error))
        let payload: MacScopeMCPJSONValue = .object([
            "code": .string(code),
            "message": .string(error.localizedDescription)
        ])
        do { try await transmit(kind: .error, payload: payload, id: id) }
        catch { lastError = error.localizedDescription }
    }

    private func send(
        kind: MacScopeRemoteWireKind,
        payload: MacScopeMCPJSONValue,
        id: UUID = UUID()
    ) async {
        do {
            try await transmit(kind: kind, payload: payload, id: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func transmit(
        kind: MacScopeRemoteWireKind,
        payload: MacScopeMCPJSONValue,
        id: UUID
    ) async throws {
        guard let socket else { throw RemoteClientError.notConnected }
        let envelope = MacScopeRemoteWireEnvelopeV1(
            id: id,
            kind: kind,
            environmentID: environmentID,
            payload: payload
        )
        let data = try encoder.encode(envelope)
        guard data.count <= 64 * 1_024 else { throw RemoteClientError.payloadTooLarge }
        try await socket.send(.data(data))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: MacScopeMCPJSONValue) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(value))
    }

    private func disconnectAndReconnect() {
        receiveTask?.cancel(); receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        metricsSubscribed = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(pow(2, Double(min(reconnectAttempt, 5))), 30)
        status = .reconnecting
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            await self?.connect()
        }
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        status = .failed(error.localizedDescription)
    }

    private var relayBaseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: Self.relayURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    private var resolvedMacName: String {
        let configured = UserDefaults.standard.string(forKey: Self.macNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? Host.current().localizedName ?? "My Mac" : configured
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static func defaultEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ url: URL,
        method: String,
        body: Body?,
        bearer: String?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? decoder.decode(ErrorResponse.self, from: data).message) ?? "Relay returned HTTP \(http.statusCode)."
            throw RemoteClientError.server(detail)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct EnvironmentRegistrationRequest: Codable { let macName: String; let appVersion: String }
private struct EnvironmentRegistrationResponse: Codable {
    let environmentID: String
    let environmentSecret: String
    let pairingURL: String
    let pairingExpiresAt: Date
}
private struct PairingRequest: Codable { let role: MacScopeRemoteRole }
private struct PairingResponse: Codable { let pairingURL: String; let expiresAt: Date }
private struct WebSocketTicketRequest: Codable { let environmentID: String; let clientKind: String }
private struct WebSocketTicketResponse: Codable { let ticket: String; let expiresAt: Date }
private struct NotificationPolicyRequest: Codable { let alerts: Bool; let presence: Bool; let commands: Bool }
private struct EnvironmentSummaryResponse: Codable {
    let members: [RemoteMemberSummary]
    let audit: [RemoteAuditSummary]
}
private struct ErrorResponse: Codable { let message: String }
private struct EmptyResponse: Codable { init() {} }

private enum RemoteClientError: LocalizedError {
    case invalidRelayURL
    case invalidResponse
    case notConnected
    case payloadTooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL: "Enter a valid HTTPS Cloudflare relay URL."
        case .invalidResponse: "The relay returned an invalid response."
        case .notConnected: "The Mac is no longer connected to the relay."
        case .payloadTooLarge: "The remote payload exceeded the 64 KiB safety limit."
        case .server(let message): message
        }
    }
}

private enum RemoteKeychain {
    static let service = "local.taskmanager.MacScope.remote"

    static func string(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw RemoteClientError.server("The remote credential is unavailable in Keychain.")
        }
        return value
    }

    static func set(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let status = SecItemCopyMatching(base as CFDictionary, nil)
        if status == errSecSuccess {
            guard SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                throw RemoteClientError.server("MacScope could not update its remote Keychain credential.")
            }
        } else {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw RemoteClientError.server("MacScope could not store its remote Keychain credential.")
            }
        }
    }

    static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteClientError.server("MacScope could not remove its remote Keychain credential.")
        }
    }
}

private extension MacScopeMCPJSONValue {
    func mergingObject(_ values: [String: MacScopeMCPJSONValue]) -> Self {
        guard case .object(let existing) = self else { return .object(values) }
        return .object(existing.merging(values) { _, new in new })
    }
}
