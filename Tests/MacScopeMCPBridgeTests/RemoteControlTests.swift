import Foundation
import MacScopeCore
import Testing
@testable import MacScopeMCPBridge

@Suite("MacScope Remote protocol and policy")
struct RemoteControlTests {
    @Test("Compact metric frames reuse and redact a supplied snapshot")
    func compactMetricFrame() throws {
        var memory = MemorySnapshot()
        memory.total = 16 * 1_024 * 1_024 * 1_024
        memory.used = 8 * 1_024 * 1_024 * 1_024
        let secretProcess = ProcessSnapshot(
            pid: 42,
            parentPID: 1,
            name: "Private Process",
            executablePath: "/Users/person/Secret.app",
            userID: 501,
            state: "running",
            cpuPercent: 12,
            residentMemory: 100,
            virtualMemory: 200,
            threads: 4,
            bytesRead: 0,
            bytesWritten: 0,
            startedAt: .now
        )
        let snapshot = SystemSnapshot(
            timestamp: Date(timeIntervalSince1970: 100),
            cpuUsage: 37.5,
            memory: memory,
            processes: [secretProcess],
            metrics: [
                .init(descriptorID: "cpu", value: .number(37.5)),
                .init(descriptorID: "gpu", value: .number(0), availability: .restricted)
            ]
        )

        let frame = MacScopeRemoteMetricFrameV1(snapshot: snapshot, alertState: "alert", activeAlertCount: 1)
        let json = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)

        #expect(frame.cpuPercent == 37.5)
        #expect(frame.memoryPercent == 50)
        #expect(frame.measuredMetricCount == 1)
        #expect(frame.degradedMetricCount == 1)
        #expect(frame.alertState == "alert")
        #expect(!json.contains("Private Process"))
        #expect(!json.contains("Secret.app"))
    }

    @Test("Wire decoding rejects an unsupported schema version")
    func schemaRejection() {
        let json = """
        {"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000001","kind":"heartbeat","sentAt":"2026-08-30T12:00:00Z","payload":{}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(MacScopeRemoteWireEnvelopeV1.self, from: Data(json.utf8))
        }
    }

    @Test("Wire decoding accepts JavaScript ISO timestamps with milliseconds")
    func javascriptTimestampDecoding() throws {
        let json = """
        {"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","kind":"command_prepare","sentAt":"2026-08-30T14:58:57.123Z","payload":{"schemaVersion":1,"commandID":"00000000-0000-0000-0000-000000000002","actorID":"member-1","role":"owner","actionID":"utility.sound.refresh","arguments":{},"expiresAt":"2026-08-30T14:59:12.456Z"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope = try decoder.decode(MacScopeRemoteWireEnvelopeV1.self, from: Data(json.utf8))
        let requestData = try JSONEncoder().encode(envelope.payload)
        let request = try decoder.decode(MacScopeRemoteCommandPrepareV1.self, from: requestData)

        #expect(request.actionID == "utility.sound.refresh")
    }

    @Test("Utility risk metadata defaults unknown mutations closed")
    func utilityRiskClassification() throws {
        #expect(try #require(MacScopeMCPUtilityCatalog.action(id: "sound.refresh")).remoteRisk == .readOnly)
        #expect(try #require(MacScopeMCPUtilityCatalog.action(id: "sound.set-system-volume")).remoteRisk == .mutation)
        #expect(try #require(MacScopeMCPUtilityCatalog.action(id: "capture.screenshot")).remoteRisk == .sensitive)
        #expect(try #require(MacScopeMCPUtilityCatalog.action(id: "clipboard.clear")).remoteRisk == .destructive)
    }

    @Test("Viewer, allowlist, expiry, and replay checks fail closed")
    func commandPolicyMatrix() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let actionID = "sound.set-system-volume"

        let viewerPolicy = MacScopeRemoteCommandPolicy()
        await #expect(throws: MacScopeRemotePolicyError.self) {
            _ = try await viewerPolicy.prepare(.init(
                commandID: UUID(), actorID: "viewer", role: .viewer,
                actionID: actionID, expiresAt: now.addingTimeInterval(15)
            ), now: now)
        }

        let deniedPolicy = MacScopeRemoteCommandPolicy(allowedActions: [])
        await #expect(throws: MacScopeRemotePolicyError.self) {
            _ = try await deniedPolicy.prepare(.init(
                commandID: UUID(), actorID: "operator", role: .operator,
                actionID: actionID, expiresAt: now.addingTimeInterval(15)
            ), now: now)
        }

        let policy = MacScopeRemoteCommandPolicy()
        await #expect(throws: MacScopeRemotePolicyError.self) {
            _ = try await policy.prepare(.init(
                commandID: UUID(), actorID: "operator", role: .operator,
                actionID: actionID, expiresAt: now
            ), now: now)
        }

        let commandID = UUID()
        let prepared = try await policy.prepare(.init(
            commandID: commandID,
            actorID: "operator",
            role: .operator,
            actionID: actionID,
            arguments: ["value": .number(0.5)],
            expiresAt: now.addingTimeInterval(15)
        ), now: now)
        let apply = MacScopeRemoteCommandApplyV1(
            commandID: commandID,
            approvalToken: prepared.approvalToken,
            confirmation: prepared.confirmation,
            expiresAt: now.addingTimeInterval(15)
        )
        _ = try await policy.authorize(apply, now: now)
        await #expect(throws: MacScopeRemotePolicyError.self) {
            _ = try await policy.authorize(apply, now: now.addingTimeInterval(1))
        }
    }
}
