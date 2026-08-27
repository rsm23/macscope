import Foundation
import MacScopeCore
import Testing

@Suite("MCP connection registry")
struct MCPConnectionRegistryTests {
    @Test("A connected client is shared, updated, and removed through the registry interface")
    func connectionLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-mcp-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try MCPConnectionRegistry(directoryURL: directory)
        let reader = try MCPConnectionRegistry(directoryURL: directory)
        let policy = MCPConnectionPolicy(
            sensitiveReads: false,
            featureWrites: true,
            experimentalFeatureWrites: false
        )

        try await writer.beginSession(
            clientName: "codex",
            clientTitle: "Codex Desktop",
            clientVersion: "1.2.3",
            serverVersion: "1.0.0",
            protocolVersion: "2025-11-25",
            policy: policy
        )

        let connected = await reader.activeSessions()
        #expect(connected.count == 1)
        #expect(connected.first?.displayName == "Codex Desktop")
        #expect(connected.first?.clientName == "codex")
        #expect(connected.first?.policy.featureWrites == true)
        #expect(connected.first?.policy.sensitiveReads == false)
        #expect(connected.first?.serverPID == getpid())

        let previousActivity = try #require(connected.first?.lastActivityAt)
        try await Task.sleep(for: .milliseconds(10))
        try await writer.recordActivity()
        let updated = await reader.activeSessions()
        #expect(updated.first?.lastActivityAt ?? .distantPast > previousActivity)

        try await writer.endSession()
        #expect(await reader.activeSessions().isEmpty)
    }

    @Test("An abandoned connection disappears after its heartbeat expires")
    func staleConnectionCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-mcp-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try MCPConnectionRegistry(directoryURL: directory, staleInterval: 0.05)
        let reader = try MCPConnectionRegistry(directoryURL: directory, staleInterval: 0.05)
        try await writer.beginSession(
            clientName: "test-client",
            clientTitle: nil,
            clientVersion: "1",
            serverVersion: "1",
            protocolVersion: "2025-11-25",
            policy: .init(sensitiveReads: false, featureWrites: false, experimentalFeatureWrites: false)
        )
        #expect(await reader.activeSessions().count == 1)

        try await Task.sleep(for: .milliseconds(80))
        #expect(await reader.activeSessions().isEmpty)
        try await writer.endSession()
    }
}
