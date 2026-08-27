import Foundation

/// A broad hardware area that can be represented honestly on a MacBook schematic.
///
/// Regions deliberately describe components rather than coordinates. Apple does not publish a
/// stable physical map for runtime-discovered SMC and PMU keys, and those keys vary by model.
public enum ThermalHardwareRegion: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case processor
    case memory
    case storage
    case battery
    case powerDelivery
    case wirelessIO
    case display
    case enclosure
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .processor: "Processor"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .powerDelivery: "Power delivery"
        case .wirelessIO: "Wireless & I/O"
        case .display: "Display"
        case .enclosure: "Enclosure"
        case .unknown: "Unmapped"
        }
    }
}

/// How strongly a sensor key supports its broad hardware-region assignment.
public enum ThermalPlacementConfidence: String, Codable, Hashable, Sendable {
    /// The key contains an explicit, unambiguous component name.
    case exactName
    /// The key belongs to an established component-specific SMC/PMU key family.
    case knownFamily
    /// The key describes only a broad device, proximity, ambient, or enclosure reading.
    case contextual
    /// No defensible physical placement is available.
    case unknown
}

/// Conservative placement metadata for a runtime-discovered thermal sensor.
public struct ThermalSensorPlacement: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let region: ThermalHardwareRegion
    public let confidence: ThermalPlacementConfidence
    public let basis: String

    public var id: String { key }

    public init(
        key: String,
        region: ThermalHardwareRegion,
        confidence: ThermalPlacementConfidence,
        basis: String
    ) {
        self.key = key
        self.region = region
        self.confidence = confidence
        self.basis = basis
    }

    /// Classifies a sensor into a broad component region without claiming exact coordinates.
    ///
    /// A trailing duplicate suffix such as `#2` or `(2)` is ignored for classification but the
    /// original key is retained in the result. Matching is case-insensitive.
    public static func classify(key: String) -> ThermalSensorPlacement {
        let normalized = normalizedKey(key)
        let compact = normalized.filter(\.isLetterOrNumber)
        let words = wordSet(normalized)

        if isCalibrationKey(compact: compact, words: words) {
            return placement(
                key,
                .unknown,
                .unknown,
                "Calibration metadata does not identify a physical sensor location."
            )
        }

        if compact == "pmudie" || compact == "pmudietemperature" || compact == "pmudietemp" {
            return placement(
                key,
                .powerDelivery,
                .exactName,
                "The sensor name explicitly identifies the power-management unit die."
            )
        }

        if matchesAnyExactName(
            compact,
            names: ["pmutdie", "tdie", "cpudie", "gpudie", "socdie", "processordie"]
        ) {
            return placement(key, .processor, .exactName, "The sensor name explicitly identifies a processor die.")
        }
        if hasNumberedFamily(compact, prefixes: ["tdie", "tc", "tg"]) {
            return placement(key, .processor, .knownFamily, "The key belongs to a processor temperature family (tDie, TC, or TG).")
        }
        if containsAnyPhrase(normalized, ["cpu die", "gpu die", "soc die", "processor die"]) {
            return placement(key, .processor, .exactName, "The sensor name explicitly identifies a processor die.")
        }

        if hasNumberedFamily(compact, prefixes: ["tm"]) {
            return placement(key, .memory, .knownFamily, "The key belongs to the SMC memory temperature family (Tm).")
        }
        if words.contains("memory") || words.contains("dram") || words.contains("ram") {
            return placement(key, .memory, .exactName, "The sensor name explicitly identifies memory.")
        }

        if hasNumberedFamily(compact, prefixes: ["ts"]) {
            return placement(key, .storage, .knownFamily, "The key belongs to the storage temperature family (Ts).")
        }
        if words.contains("ssd") || words.contains("nvme") || words.contains("storage") {
            return placement(key, .storage, .exactName, "The sensor name explicitly identifies storage.")
        }

        if hasNumberedFamily(compact, prefixes: ["tb"]) {
            return placement(key, .battery, .knownFamily, "The key belongs to the SMC battery temperature family (TB).")
        }
        if words.contains("battery") || compact == "batterytemp" || compact == "batterytemperature" {
            return placement(key, .battery, .exactName, "The sensor name explicitly identifies the battery.")
        }

        if containsAnyPhrase(
            normalized,
            ["power delivery", "power supply", "dc in", "usb c power", "charging circuit"]
        ) || !words.isDisjoint(with: ["charger", "charging", "adapter", "pmic", "vrm"]) ||
            (words.contains("power") && !words.isDisjoint(with: ["usb", "dc"]))
        {
            return placement(key, .powerDelivery, .exactName, "The sensor name explicitly identifies charging or power-delivery hardware.")
        }
        if compact == "power" || compact == "powertemp" || compact == "powertemperature" {
            return placement(key, .powerDelivery, .exactName, "The sensor name explicitly identifies power-delivery hardware.")
        }

        if hasNumberedFamily(compact, prefixes: ["tw"]) {
            return placement(key, .wirelessIO, .knownFamily, "The key belongs to the SMC wireless temperature family (TW).")
        }
        if compact.hasPrefix("wifi") ||
            !words.isDisjoint(with: ["wifi", "wireless", "airport", "bluetooth", "thunderbolt", "usb"])
        {
            return placement(key, .wirelessIO, .exactName, "The sensor name explicitly identifies wireless or I/O hardware.")
        }

        if hasNumberedFamily(compact, prefixes: ["tl"]) {
            return placement(key, .display, .knownFamily, "The key belongs to the SMC display temperature family (TL).")
        }
        if !words.isDisjoint(with: ["display", "screen", "panel", "lcd"]) {
            return placement(key, .display, .exactName, "The sensor name explicitly identifies the display.")
        }

        if compact.hasPrefix("tdev") {
            return placement(
                key,
                .enclosure,
                .contextual,
                "A tDev key identifies only a generic device reading; its exact component is not published."
            )
        }
        if hasNumberedFamily(compact, prefixes: ["tp"]) {
            return placement(
                key,
                .enclosure,
                .contextual,
                "A Tp key is a proximity reading and does not identify exact component coordinates."
            )
        }
        if hasNumberedFamily(compact, prefixes: ["ta"]) ||
            !words.isDisjoint(with: ["ambient", "case", "chassis", "enclosure", "palmrest"])
        {
            return placement(
                key,
                .enclosure,
                .contextual,
                "The key describes an ambient or enclosure reading rather than a precise component."
            )
        }

        return placement(
            key,
            .unknown,
            .unknown,
            "No conservative hardware-region mapping is known for this sensor key."
        )
    }
}

private extension ThermalSensorPlacement {
    static func placement(
        _ key: String,
        _ region: ThermalHardwareRegion,
        _ confidence: ThermalPlacementConfidence,
        _ basis: String
    ) -> ThermalSensorPlacement {
        ThermalSensorPlacement(key: key, region: region, confidence: confidence, basis: basis)
    }

    static func normalizedKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+(?:#\d+|\(\d+\))\s*$"#,
                with: "",
                options: .regularExpression
            )
            .lowercased()
    }

    static func wordSet(_ normalized: String) -> Set<String> {
        Set(
            normalized
                .split(whereSeparator: { !$0.isLetterOrNumber })
                .map(String.init)
        )
    }

    static func matchesAnyExactName(_ compact: String, names: Set<String>) -> Bool {
        names.contains(compact)
    }

    static func hasNumberedFamily(_ compact: String, prefixes: Set<String>) -> Bool {
        prefixes.contains { prefix in
            guard compact.hasPrefix(prefix) else { return false }
            let suffix = compact.dropFirst(prefix.count)
            guard let first = suffix.first, first.isNumber else { return false }
            // SMC keys are short. Bounding the suffix avoids classifying arbitrary prose that
            // happens to begin with the same letters and a number.
            return suffix.count <= 4
        }
    }

    static func containsAnyPhrase(_ normalized: String, _ phrases: Set<String>) -> Bool {
        phrases.contains { normalized.contains($0) }
    }

    static func isCalibrationKey(compact: String, words: Set<String>) -> Bool {
        compact.hasPrefix("tcal") || words.contains("calibration") || words.contains("calibrate")
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
