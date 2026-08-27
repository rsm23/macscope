import Darwin
import Foundation

public actor InventoryCollector: Collector {
    public let id = "inventory"

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [MetricDescriptor(id: "hardware.inventory", name: "Hardware Inventory", source: "sysctl", scope: "system", unit: "text", kind: .information, provenance: "sysctlbyname")]
    }

    public func sample() async throws -> HardwareInventory {
        var inventory = HardwareInventory()
        inventory.modelIdentifier = Sysctl.string("hw.model") ?? "Unknown"
        inventory.chip = Sysctl.string("machdep.cpu.brand_string") ?? Sysctl.string("hw.machine") ?? "Apple silicon"
        inventory.architecture = Sysctl.string("hw.machine") ?? "arm64"
        inventory.physicalMemory = ProcessInfo.processInfo.physicalMemory
        inventory.processorCount = ProcessInfo.processInfo.processorCount
        inventory.activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount
        inventory.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        inventory.kernelVersion = Sysctl.string("kern.osrelease") ?? "Unknown"
        inventory.uptime = ProcessInfo.processInfo.systemUptime
        inventory.modelName = modelName(for: inventory.modelIdentifier)
        inventory.gpus = await gpuDevices()
        inventory.details = [
            "Host name": ProcessInfo.processInfo.hostName,
            "Kernel": inventory.kernelVersion,
            "Architecture": inventory.architecture,
            "Logical processors": "\(inventory.processorCount)",
            "Active processors": "\(inventory.activeProcessorCount)",
            "Physical memory": ByteCountFormatter.string(fromByteCount: Int64(inventory.physicalMemory), countStyle: .memory),
            "Low Power Mode": ProcessInfo.processInfo.isLowPowerModeEnabled ? "Enabled" : "Disabled",
            "Thermal State": thermalStateName(ProcessInfo.processInfo.thermalState)
        ]
        return inventory
    }

    private func gpuDevices() async -> [GPUDevice] {
        let result = await CommandRunner.run(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPDisplaysDataType", "-json"],
            timeout: 10
        )
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["SPDisplaysDataType"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            guard let name = device["sppci_model"] as? String ?? device["_name"] as? String,
                  !name.isEmpty else { return nil }
            let coreCount = (device["sppci_cores"] as? String).flatMap(Int.init)
            let bus = device["sppci_bus"] as? String
            return GPUDevice(name: name, coreCount: coreCount, isBuiltIn: bus == "spdisplays_builtin")
        }
    }

    private func modelName(for identifier: String) -> String {
        if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if identifier.hasPrefix("Macmini") { return "Mac mini" }
        if identifier.hasPrefix("MacStudio") { return "Mac Studio" }
        if identifier.hasPrefix("iMac") { return "iMac" }
        if identifier.hasPrefix("MacPro") { return "Mac Pro" }
        return "Mac"
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

public enum Sysctl {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return decodedCString(buffer)
    }
}
