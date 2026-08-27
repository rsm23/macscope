import Foundation

public enum TelemetryExporter {
    public static func inventoryJSON(_ inventory: HardwareInventory, redactSensitive: Bool = true) throws -> Data {
        var value = inventory
        if redactSensitive {
            value.details = value.details.filter { key, _ in
                !["Host name", "Serial Number", "Hardware UUID"].contains(key)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func metricsCSV(_ snapshots: [SystemSnapshot]) -> Data {
        var lines = ["timestamp,metric_id,value,quality,availability"]
        let formatter = ISO8601DateFormatter()
        for snapshot in snapshots {
            for sample in snapshot.metrics {
                let value: String
                switch sample.value {
                case .number(let number): value = String(number)
                case .text(let text): value = escape(text)
                case .boolean(let boolean): value = boolean ? "true" : "false"
                }
                lines.append("\(formatter.string(from: sample.timestamp)),\(escape(sample.descriptorID)),\(value),\(sample.quality.rawValue),\(sample.availability.rawValue)")
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
