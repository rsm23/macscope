import Darwin
import Foundation

public actor MemoryCollector: Collector {
    public let id = "memory"

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "memory.used", name: "Memory Used", source: "Mach", scope: "system", unit: "bytes", provenance: "host_statistics64"),
            MetricDescriptor(id: "memory.pressure", name: "Memory Pressure", source: "Mach", scope: "system", unit: "%", provenance: "derived from VM counters", availability: .degraded)
        ]
    }

    public func sample() async throws -> MemorySnapshot {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            throw CollectorError.unavailable("Unable to read VM page size")
        }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw CollectorError.unavailable("host_statistics64 failed with \(result)")
        }

        let page = UInt64(pageSize)
        let active = UInt64(statistics.active_count) * page
        let inactive = UInt64(statistics.inactive_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let cached = UInt64(statistics.speculative_count) * page
        let free = UInt64(statistics.free_count) * page
        let total = ProcessInfo.processInfo.physicalMemory

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = withUnsafeMutablePointer(to: &swap) { pointer in
            sysctlbyname("vm.swapusage", pointer, &swapSize, nil, 0)
        }

        var snapshot = MemorySnapshot()
        snapshot.total = total
        snapshot.active = active
        snapshot.inactive = inactive
        snapshot.wired = wired
        snapshot.compressed = compressed
        snapshot.cached = cached
        snapshot.free = free
        snapshot.used = min(total, active &+ inactive &+ wired &+ compressed)
        if swapResult == 0 {
            snapshot.swapUsed = UInt64(max(swap.xsu_used, 0))
            snapshot.swapTotal = UInt64(max(swap.xsu_total, 0))
        }
        snapshot.pressure = .available
        return snapshot
    }
}
