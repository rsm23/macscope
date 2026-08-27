import Foundation
import IOKit
import IOKit.ps

public actor BatteryCollector: Collector {
    public let id = "battery"

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "battery.charge", name: "Battery Charge", source: "IOPowerSources", scope: "battery", unit: "%", provenance: "IOPS power source description"),
            MetricDescriptor(id: "battery.cycles", name: "Battery Cycles", source: "IOPowerSources", scope: "battery", unit: "cycles", kind: .counter, provenance: "IOPS power source description")
        ]
    }

    public func sample() async throws -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sourceList.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            return BatterySnapshot()
        }

        var battery = BatterySnapshot()
        battery.isPresent = true
        battery.name = string(description, "Name") ?? "Internal Battery"
        battery.powerSourceState = string(description, "Power Source State") ?? "Unknown"
        battery.currentCapacity = integer(description, "Current Capacity")
        battery.maximumCapacity = integer(description, "Max Capacity")
        battery.designCapacity = integer(description, "DesignCapacity") ?? integer(description, "Design Capacity")
        battery.cycleCount = integer(description, "Cycle Count") ?? integer(description, "CycleCount")
        battery.voltageMillivolts = integer(description, "Voltage")
        battery.amperageMilliamps = integer(description, "Amperage")
        battery.timeToEmptyMinutes = validTime(integer(description, "Time to Empty"))
        battery.timeToFullMinutes = validTime(integer(description, "Time to Full Charge"))
        battery.isCharging = boolean(description, "Is Charging")
        battery.health = string(description, "BatteryHealth")
        battery.condition = string(description, "BatteryHealthCondition")
        battery.availability = .available

        if let current = battery.currentCapacity, let maximum = battery.maximumCapacity, maximum > 0 {
            battery.chargePercent = min(max(Double(current) / Double(maximum) * 100, 0), 100)
        }
        if let rawTemperature = number(description, "Temperature") {
            // Apple exposes this field in centi-degrees Celsius on current portable Macs.
            battery.temperatureCelsius = rawTemperature > 200 ? rawTemperature / 100 : rawTemperature
        }
        mergeRegistryProperties(into: &battery)
        return battery
    }

    private func mergeRegistryProperties(into battery: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else { return }

        battery.currentCapacity = integer(properties, "CurrentCapacity") ?? battery.currentCapacity
        battery.maximumCapacity = integer(properties, "MaxCapacity") ?? battery.maximumCapacity
        battery.designCapacity = integer(properties, "DesignCapacity") ?? battery.designCapacity
        battery.cycleCount = integer(properties, "CycleCount") ?? battery.cycleCount
        battery.designCycleCount = integer(properties, "DesignCycleCount9C")
        battery.voltageMillivolts = integer(properties, "Voltage") ?? battery.voltageMillivolts
        battery.amperageMilliamps = integer(properties, "InstantAmperage") ?? integer(properties, "Amperage") ?? battery.amperageMilliamps
        battery.isCharging = (properties["IsCharging"] as? Bool) ?? battery.isCharging
        battery.isFullyCharged = (properties["FullyCharged"] as? Bool) ?? false
        battery.isExternalPowerConnected = (properties["ExternalConnected"] as? Bool) ?? false

        if let temperature = number(properties, "Temperature") {
            battery.temperatureCelsius = temperature > 200 ? temperature / 100 : temperature
        }
        if let rawMaximum = number(properties, "AppleRawMaxCapacity"),
           let design = number(properties, "DesignCapacity"), design > 0 {
            battery.healthPercent = min(max(rawMaximum / design * 100, 0), 100)
            battery.health = healthDescription(battery.healthPercent)
        }
        if let adapter = (properties["AdapterDetails"] as? [[String: Any]])?.first
            ?? properties["AdapterDetails"] as? [String: Any] {
            battery.adapterName = string(adapter, "Name") ?? string(adapter, "Description")
            battery.adapterWatts = number(adapter, "Watts")
        }
        if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
            battery.batteryPowerWatts = milliwatts(telemetry, "BatteryPower")
            battery.systemPowerWatts = milliwatts(telemetry, "SystemPowerIn") ?? milliwatts(telemetry, "SystemLoad")
        }
    }

    private func healthDescription(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        if percent >= 80 { return "Normal" }
        if percent >= 70 { return "Reduced capacity" }
        return "Service recommended"
    }

    private func milliwatts(_ values: [String: Any], _ key: String) -> Double? {
        guard let value = number(values, key), value >= 0 else { return nil }
        return value / 1_000
    }

    private func string(_ values: [String: Any], _ key: String) -> String? {
        values[key] as? String
    }

    private func integer(_ values: [String: Any], _ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }

    private func number(_ values: [String: Any], _ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }

    private func boolean(_ values: [String: Any], _ key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue ?? false
    }

    private func validTime(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
