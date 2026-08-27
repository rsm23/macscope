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
            sections: [.cpu, .processes, .hardware],
            processLimit: 1
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

    private func string(_ key: String, in document: MacScopeMCPJSONValue) throws -> String {
        guard case .object(let values) = document,
              case .string(let value)? = values[key] else {
            throw TestError.missingField(key)
        }
        return value
    }
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
            inventory: inventory
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
