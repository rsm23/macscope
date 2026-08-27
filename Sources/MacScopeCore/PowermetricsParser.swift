import Foundation

public enum PowermetricsParser {
    public static func parseStream(_ data: Data) throws -> DeepTelemetrySnapshot {
        let chunks = data.split(separator: 0).filter { !$0.isEmpty }
        guard let chunk = chunks.last else { throw CollectorError.malformed("powermetrics produced no plist records") }
        let propertyList = try PropertyListSerialization.propertyList(from: Data(chunk), options: [], format: nil)
        var flattened: [String: Double] = [:]
        flatten(propertyList, path: "", into: &flattened)

        var result = DeepTelemetrySnapshot(availability: .available)
        result.gpuUsage = find(flattened, containing: ["gpu", "active", "residency"])
            ?? find(flattened, containing: ["gpu", "duty", "cycle"])
        result.gpuFrequencyMHz = normalizeFrequency(find(flattened, containing: ["gpu", "frequency"]), keyValues: flattened, component: "gpu")
        result.gpuPowerWatts = normalizePower(findEntry(flattened, containing: ["gpu", "power"]))
        result.aneUsage = find(flattened, containing: ["ane", "active", "residency"])
            ?? find(flattened, containing: ["ane", "duty", "cycle"])
        result.aneFrequencyMHz = normalizeFrequency(find(flattened, containing: ["ane", "frequency"]), keyValues: flattened, component: "ane")
        result.anePowerWatts = normalizePower(findEntry(flattened, containing: ["ane", "power"]))
        result.cpuFrequencyMHz = normalizeFrequency(find(flattened, containing: ["cpu", "frequency"]), keyValues: flattened, component: "cpu")
        result.cpuPowerWatts = normalizePower(findEntry(flattened, containing: ["cpu", "power"]))
        result.thermalPressure = flattened.keys.first(where: { $0.localizedCaseInsensitiveContains("thermal pressure") })
        if [result.gpuUsage, result.gpuFrequencyMHz, result.aneUsage, result.cpuFrequencyMHz].allSatisfy({ $0 == nil }) {
            result.availability = .degraded
            result.detail = "The powermetrics plist was valid, but this macOS version used unrecognized counter names. Raw collection remains available."
        }
        return result
    }

    public static func flattenedNumbers(_ data: Data) throws -> [String: Double] {
        let chunks = data.split(separator: 0).filter { !$0.isEmpty }
        guard let chunk = chunks.last else { return [:] }
        let propertyList = try PropertyListSerialization.propertyList(from: Data(chunk), options: [], format: nil)
        var result: [String: Double] = [:]
        flatten(propertyList, path: "", into: &result)
        return result
    }

    private static func flatten(_ value: Any, path: String, into result: inout [String: Double]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                flatten(child, path: path.isEmpty ? key : "\(path).\(key)", into: &result)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() { flatten(child, path: "\(path)[\(index)]", into: &result) }
        } else if let number = value as? NSNumber {
            result[path] = number.doubleValue
        }
    }

    private static func find(_ values: [String: Double], containing terms: [String]) -> Double? {
        findEntry(values, containing: terms)?.value
    }

    private static func findEntry(_ values: [String: Double], containing terms: [String]) -> (key: String, value: Double)? {
        values.first { key, _ in terms.allSatisfy { key.localizedCaseInsensitiveContains($0) } }
    }

    private static func normalizePower(_ entry: (key: String, value: Double)?) -> Double? {
        guard let entry, entry.value.isFinite, entry.value >= 0 else { return nil }
        let key = entry.key.lowercased()
        if key.contains("uw") || key.contains("microwatt") { return entry.value / 1_000_000 }
        if key.contains("mw") || key.contains("milliwatt") { return entry.value / 1_000 }
        if key.contains("watt") { return entry.value }

        // In powermetrics plist output, the bare Apple-silicon keys such as
        // cpu_power, gpu_power, and ane_power use milliwatts even though the
        // unit is omitted from the key. The text formatter labels the same
        // counters as mW.
        return entry.value / 1_000
    }

    private static func normalizeFrequency(_ value: Double?, keyValues: [String: Double], component: String) -> Double? {
        guard let value else { return nil }
        if let key = keyValues.first(where: { $0.value == value && $0.key.localizedCaseInsensitiveContains(component) })?.key {
            if key.localizedCaseInsensitiveContains("hz"), !key.localizedCaseInsensitiveContains("mhz") { return value / 1_000_000 }
        }
        return value
    }
}
