import Darwin
import Foundation

public struct CPUSample: Sendable {
    public let total: Double
    public let user: Double
    public let system: Double
    public let cores: [CPUCoreSnapshot]
    public let loadAverages: [Double]
}

public actor CPUCollector: Collector {
    public let id = "cpu"

    private struct Ticks: Sendable {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user &+ system &+ idle &+ nice }
    }

    private var previous: [Ticks] = []

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "cpu.total", name: "CPU Usage", source: "Mach", scope: "system", unit: "%", provenance: "host_processor_info"),
            MetricDescriptor(id: "cpu.user", name: "User CPU", source: "Mach", scope: "system", unit: "%", provenance: "host_processor_info"),
            MetricDescriptor(id: "cpu.system", name: "System CPU", source: "Mach", scope: "system", unit: "%", provenance: "host_processor_info")
        ]
    }

    public func sample() async throws -> CPUSample {
        let current = try readTicks()
        defer { previous = current }

        guard previous.count == current.count, !previous.isEmpty else {
            return CPUSample(total: 0, user: 0, system: 0, cores: [], loadAverages: readLoadAverages())
        }

        var cores: [CPUCoreSnapshot] = []
        var userDelta: UInt64 = 0
        var systemDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        var totalDelta: UInt64 = 0

        for index in current.indices {
            let now = current[index]
            let old = previous[index]
            let user = delta(now.user &+ now.nice, old.user &+ old.nice)
            let system = delta(now.system, old.system)
            let idle = delta(now.idle, old.idle)
            let total = delta(now.total, old.total)
            let denominator = max(Double(total), 1)

            userDelta &+= user
            systemDelta &+= system
            idleDelta &+= idle
            totalDelta &+= total

            cores.append(CPUCoreSnapshot(
                id: index,
                usage: clampPercent(Double(user &+ system) / denominator * 100),
                user: clampPercent(Double(user) / denominator * 100),
                system: clampPercent(Double(system) / denominator * 100),
                idle: clampPercent(Double(idle) / denominator * 100),
                cluster: clusterName(for: index, count: current.count)
            ))
        }

        let denominator = max(Double(totalDelta), 1)
        return CPUSample(
            total: clampPercent(Double(userDelta &+ systemDelta) / denominator * 100),
            user: clampPercent(Double(userDelta) / denominator * 100),
            system: clampPercent(Double(systemDelta) / denominator * 100),
            cores: cores,
            loadAverages: readLoadAverages()
        )
    }

    private func readTicks() throws -> [Ticks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else {
            throw CollectorError.unavailable("host_processor_info failed with \(result)")
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(cpuCount)).map { index in
            let offset = Int(CPU_STATE_MAX) * index
            return Ticks(
                user: UInt64(info[offset + Int(CPU_STATE_USER)]),
                system: UInt64(info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[offset + Int(CPU_STATE_NICE)])
            )
        }
    }

    private func readLoadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, 3)
        return count > 0 ? Array(values.prefix(Int(count))) : []
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }

    private func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private func clusterName(for index: Int, count: Int) -> String {
        // macOS does not expose a stable public logical-core-to-cluster mapping.
        // Keep this honest until the deep Apple-silicon collector provides one.
        count > 1 ? "Core \(index + 1)" : "CPU"
    }
}

public enum CollectorError: LocalizedError, Sendable {
    case unavailable(String)
    case malformed(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .malformed(let message), .permissionDenied(let message): message
        }
    }
}
