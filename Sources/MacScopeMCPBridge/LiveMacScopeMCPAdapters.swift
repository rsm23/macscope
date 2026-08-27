import Foundation
import MacScopeCore

public actor LiveMacScopeMCPSnapshotSource: MacScopeMCPSnapshotSource {
    private let engine: TelemetryEngine
    private var streamTask: Task<Void, Never>?
    private var latest: SystemSnapshot?
    private var sampleCount = 0

    public init(profile: SamplingProfile = .balanced) {
        engine = TelemetryEngine(profile: profile, database: nil)
    }

    public func currentSnapshot() async throws -> SystemSnapshot {
        await ensureStarted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if let latest, sampleCount >= 2 { return latest }
            try await Task.sleep(for: .milliseconds(40))
        }
        if let latest { return latest }
        throw MacScopeMCPError.snapshotUnavailable
    }

    public func recentSnapshots(limit: Int) async throws -> [SystemSnapshot] {
        _ = try await currentSnapshot()
        let snapshots = await engine.recentSnapshots()
        return Array(snapshots.suffix(min(max(limit, 1), 300)))
    }

    private func ensureStarted() async {
        guard streamTask == nil else { return }
        let stream = await engine.stream()
        await engine.start()
        streamTask = Task { [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(snapshot)
            }
        }
    }

    private func receive(_ snapshot: SystemSnapshot) {
        latest = snapshot
        sampleCount += 1
    }
}
