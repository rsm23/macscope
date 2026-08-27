import Foundation

public enum RawSnapshotRenderer {
    private struct PreviewCounts: Codable {
        let processes: Int
        let startupItems: Int
        let connections: Int
        let metrics: Int
    }

    private struct PreviewDocument: Codable {
        let notice: String
        let totals: PreviewCounts
        let snapshot: SystemSnapshot
    }

    public static func previewJSON(_ snapshot: SystemSnapshot) -> String {
        let collectionLimit = 50
        let previewSnapshot = SystemSnapshot(
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
            processes: Array(snapshot.processes.prefix(collectionLimit)),
            startupItems: Array(snapshot.startupItems.prefix(collectionLimit)),
            smartReports: snapshot.smartReports,
            connections: Array(snapshot.connections.prefix(collectionLimit)),
            inventory: snapshot.inventory,
            deep: snapshot.deep,
            metrics: snapshot.metrics
        )
        let document = PreviewDocument(
            notice: "Preview truncated to \(collectionLimit) entries per large collection. Use the dedicated tables or exports for complete collections.",
            totals: PreviewCounts(
                processes: snapshot.processes.count,
                startupItems: snapshot.startupItems.count,
                connections: snapshot.connections.count,
                metrics: snapshot.metrics.count
            ),
            snapshot: previewSnapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(document)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "Unable to encode snapshot"
    }
}
