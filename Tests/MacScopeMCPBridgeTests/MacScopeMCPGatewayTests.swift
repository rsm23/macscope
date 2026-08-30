import Foundation
import MacScopeCore
import Testing
@testable import MacScopeMCPBridge

@Suite("MacScope MCP gateway")
struct MacScopeMCPGatewayTests {
    @Test("Snapshot sections are bounded and sensitive fields are redacted by default")
    func redactedSnapshot() async throws {
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: FakeFeatureAccess()
        )

        let document = try await gateway.snapshot(.init(
            sections: [.cpu, .processes, .hardware, .metrics],
            processLimit: 1,
            collectionLimit: 1
        ))
        let json = try document.jsonString()

        #expect(json.contains("Visible process"))
        #expect(json.contains("<redacted>"))
        #expect(!json.contains("/Applications/Secret.app"))
        #expect(!json.contains("SERIAL-SECRET"))
        #expect(!json.contains("Second process"))
        #expect(json.contains("\"cpuUser\" : 12"))
        #expect(json.contains("\"totalProcesses\" : 2"))
        #expect(json.contains("\"returnedProcesses\" : 1"))
        #expect(json.contains("\"metrics\" : 2"))
        #expect(json.contains("\"returnedMetrics\" : 1"))
        #expect(json.contains("metric.first"))
        #expect(!json.contains("metric.second"))
    }

    @Test("Sensitive values require an explicit server capability")
    func sensitiveReadPolicy() async throws {
        let disabled = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: FakeFeatureAccess()
        )
        do {
            _ = try await disabled.snapshot(.init(sections: [.all], includeSensitive: true))
            Issue.record("Sensitive data was returned without startup authorization")
        } catch let error as MacScopeMCPError {
            guard case .sensitiveReadsDisabled = error else {
                Issue.record("Expected sensitiveReadsDisabled, received \(error)")
                return
            }
        }

        let enabled = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: FakeFeatureAccess(),
            configuration: .init(allowSensitiveReads: true)
        )
        let json = try await enabled.snapshot(.init(sections: [.all], includeSensitive: true)).jsonString()
        #expect(json.contains("/Applications/Secret.app"))
        #expect(json.contains("SERIAL-SECRET"))
    }

    @Test("Feature writes are disabled unless the server opted in")
    func writePolicy() async {
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: FakeFeatureAccess()
        )
        do {
            _ = try await gateway.prepareFeatureChange(id: "test.feature", enabled: true)
            Issue.record("A write preflight was created while writes were disabled")
        } catch let error as MacScopeMCPError {
            guard case .featureWritesDisabled = error else {
                Issue.record("Expected featureWritesDisabled, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected MacScopeMCPError, received \(error)")
        }
    }

    @Test("Feature changes require preflight and return an exact-value undo")
    func preflightApplyAndUndo() async throws {
        let features = FakeFeatureAccess()
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: features,
            configuration: .init(allowFeatureWrites: true)
        )

        let preflight = try await gateway.prepareFeatureChange(id: "test.feature", enabled: true)
        let approvalToken = try string("approvalToken", in: preflight)
        let confirmation = try string("confirmation", in: preflight)
        #expect(confirmation == "APPLY test.feature ENABLE")

        let applied = try await gateway.applyFeatureChange(
            approvalToken: approvalToken,
            confirmation: confirmation
        )
        #expect(await features.isEnabled())

        let undoToken = try string("undoToken", in: applied)
        let undoConfirmation = try string("undoConfirmation", in: applied)
        _ = try await gateway.undoFeatureChange(
            undoToken: undoToken,
            confirmation: undoConfirmation
        )
        #expect(await features.isEnabled() == false)
    }

    @Test("A feature approval is rejected when its observed state becomes stale")
    func staleApproval() async throws {
        let features = FakeFeatureAccess()
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: features,
            configuration: .init(allowFeatureWrites: true)
        )
        let preflight = try await gateway.prepareFeatureChange(id: "test.feature", enabled: true)
        let token = try string("approvalToken", in: preflight)
        let confirmation = try string("confirmation", in: preflight)
        await features.simulateExternalChange()

        do {
            _ = try await gateway.applyFeatureChange(approvalToken: token, confirmation: confirmation)
            Issue.record("A stale feature preflight was applied")
        } catch let error as MacScopeMCPError {
            guard case .staleApproval = error else {
                Issue.record("Expected staleApproval, received \(error)")
                return
            }
        }
    }

    @Test("Undo refuses to overwrite a newer external feature change")
    func staleUndo() async throws {
        let features = FakeFeatureAccess()
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: features,
            configuration: .init(allowFeatureWrites: true)
        )
        let preflight = try await gateway.prepareFeatureChange(id: "test.feature", enabled: true)
        let applied = try await gateway.applyFeatureChange(
            approvalToken: string("approvalToken", in: preflight),
            confirmation: string("confirmation", in: preflight)
        )
        await features.simulateExternalChange()

        do {
            _ = try await gateway.undoFeatureChange(
                undoToken: string("undoToken", in: applied),
                confirmation: string("undoConfirmation", in: applied)
            )
            Issue.record("Undo overwrote a newer feature value")
        } catch let error as MacScopeMCPError {
            guard case .staleUndo = error else {
                Issue.record("Expected staleUndo, received \(error)")
                return
            }
        }
    }

    @Test("Utility catalog covers every module with unique executable IDs")
    func utilityCatalogCoverage() {
        let actions = MacScopeMCPUtilityCatalog.actions
        #expect(actions.count >= 75)
        #expect(Set(actions.map(\.id)).count == actions.count)
        for module in MacScopeMCPUtilityModule.allCases {
            #expect(actions.contains { $0.module == module })
        }
        #expect(actions.contains { $0.id == "capture.screenshot" && $0.producesArtifact })
        #expect(actions.contains { $0.id == "capture.recording-start" && !$0.producesArtifact })
        #expect(actions.contains { $0.id == "capture.recording-stop" && $0.producesArtifact })
        #expect(actions.contains { $0.id == "clipboard.move-shelf-files" && $0.destructive })
    }

    @Test("Utility execution is opt-in and forwards only catalogued actions")
    func utilityExecutionPolicy() async throws {
        let utilities = FakeUtilityAccess()
        let disabled = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(), featureAccess: FakeFeatureAccess(), utilityAccess: utilities
        )
        do {
            _ = try await disabled.runUtility(actionID: "sound.refresh", arguments: [:])
            Issue.record("Utility execution succeeded without startup authorization")
        } catch let error as MacScopeMCPError {
            guard case .utilityWritesDisabled = error else {
                Issue.record("Expected utilityWritesDisabled, received \(error)")
                return
            }
        }

        let enabled = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(),
            featureAccess: FakeFeatureAccess(),
            utilityAccess: utilities,
            configuration: .init(allowUtilityWrites: true)
        )
        _ = try await enabled.runUtility(actionID: "sound.set-system-volume", arguments: ["value": .number(0.4)])
        #expect(await utilities.lastAction() == "sound.set-system-volume")

        do {
            _ = try await enabled.runUtility(actionID: "not.in.catalog", arguments: [:])
            Issue.record("An unknown utility action was forwarded")
        } catch let error as MacScopeMCPError {
            guard case .unknownUtilityAction = error else {
                Issue.record("Expected unknownUtilityAction, received \(error)")
                return
            }
        }
    }

    @Test("Utility state and artifact bytes enforce independent read capabilities")
    func utilityReadPolicies() async throws {
        let utilities = FakeUtilityAccess()
        let gateway = MacScopeMCPGateway(
            snapshotSource: FakeSnapshotSource(), featureAccess: FakeFeatureAccess(), utilityAccess: utilities
        )
        let state = try await gateway.utilityState(module: .notes, includeSensitive: false).jsonString()
        #expect(state.contains("<redacted>"))

        do {
            _ = try await gateway.utilityState(module: .notes, includeSensitive: true)
            Issue.record("Sensitive utility state was returned without authorization")
        } catch let error as MacScopeMCPError {
            guard case .sensitiveReadsDisabled = error else {
                Issue.record("Expected sensitiveReadsDisabled, received \(error)")
                return
            }
        }
        do {
            _ = try await gateway.readArtifact(id: "missing", offset: 0, length: 10)
            Issue.record("Artifact bytes were read without authorization")
        } catch let error as MacScopeMCPError {
            guard case .artifactReadsDisabled = error else {
                Issue.record("Expected artifactReadsDisabled, received \(error)")
                return
            }
        }
    }

    private func string(_ key: String, in document: MacScopeMCPJSONValue) throws -> String {
        guard case .object(let values) = document,
              case .string(let value)? = values[key] else {
            throw TestError.missingField(key)
        }
        return value
    }
}

private actor FakeUtilityAccess: MacScopeMCPUtilityAccess {
    private var action: String?

    func state(module: MacScopeMCPUtilityModule, includeSensitive: Bool) async throws -> MacScopeMCPJSONValue {
        .object(["module": .string(module.rawValue), "path": .string("/private/secret")])
    }

    func run(actionID: String, arguments: [String: MacScopeMCPJSONValue]) async throws -> MacScopeMCPJSONValue {
        action = actionID
        return .object(["accepted": .bool(true)])
    }

    func lastAction() -> String? { action }
}

private enum TestError: Error {
    case missingField(String)
}

private actor FakeSnapshotSource: MacScopeMCPSnapshotSource {
    func currentSnapshot() async throws -> SystemSnapshot { snapshot }
    func recentSnapshots(limit: Int) async throws -> [SystemSnapshot] { [snapshot] }

    private var snapshot: SystemSnapshot {
        var inventory = HardwareInventory()
        inventory.modelName = "Test Mac"
        inventory.details = ["Serial Number": "SERIAL-SECRET"]
        return SystemSnapshot(
            cpuUsage: 42,
            cpuUser: 12,
            processes: [
                ProcessSnapshot(
                    pid: 101,
                    parentPID: 1,
                    name: "Visible process",
                    executablePath: "/Applications/Secret.app/Contents/MacOS/Secret",
                    userID: 501,
                    state: "running",
                    cpuPercent: 5,
                    residentMemory: 1_024,
                    virtualMemory: 2_048,
                    threads: 4,
                    bytesRead: 10,
                    bytesWritten: 20,
                    startedAt: .now
                ),
                ProcessSnapshot(
                    pid: 102,
                    parentPID: 1,
                    name: "Second process",
                    executablePath: nil,
                    userID: 501,
                    state: "sleeping",
                    cpuPercent: 0,
                    residentMemory: 512,
                    virtualMemory: 1_024,
                    threads: 1,
                    bytesRead: 0,
                    bytesWritten: 0,
                    startedAt: .now
                )
            ],
            inventory: inventory,
            metrics: [
                MetricSample(descriptorID: "metric.first", value: .number(1)),
                MetricSample(descriptorID: "metric.second", value: .number(2))
            ]
        )
    }
}

private actor FakeFeatureAccess: MacScopeMCPFeatureAccess {
    private var storedValue: MacOSFeaturePreferenceValue?

    func refresh() async -> [MacOSFeatureStatus] { [status] }

    func setEnabled(_ enabled: Bool, descriptorID: String) async throws -> MacOSFeatureChange {
        let previous = storedValue
        storedValue = .boolean(enabled)
        return MacOSFeatureChange(
            descriptorID: descriptorID,
            previousStoredValue: previous,
            enabled: enabled
        )
    }

    func restore(_ change: MacOSFeatureChange) async throws {
        storedValue = change.previousStoredValue
    }

    func isEnabled() -> Bool { status.state == .enabled }

    func simulateExternalChange() {
        storedValue = .string("unexpected")
    }

    private var status: MacOSFeatureStatus {
        let descriptor = MacOSFeatureDescriptor(
            id: "test.feature",
            title: "Test feature",
            summary: "A reversible test preference.",
            category: .appearance,
            icon: "switch.2",
            tier: .recommended,
            mechanism: .preference(MacOSFeaturePreference(
                domain: "com.example.MacScopeTests",
                key: "Enabled",
                enabledValue: .boolean(true),
                disabledValue: .boolean(false),
                defaultValue: .boolean(false)
            )),
            provenance: "Test fixture"
        )
        let state: MacOSFeatureEffectiveState
        switch storedValue {
        case .boolean(true): state = .enabled
        case nil, .boolean(false): state = .disabled
        default: state = .unknown
        }
        return MacOSFeatureStatus(
            descriptor: descriptor,
            state: state,
            availability: state == .unknown ? .unmapped : .available,
            storedValue: storedValue
        )
    }
}
