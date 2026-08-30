import Darwin
import Foundation

struct MemoryPageStatistics: Sendable {
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64
    let fileBacked: UInt64
    let speculative: UInt64
    let free: UInt64
}

enum MemoryAccounting {
    static func snapshot(
        totalBytes: UInt64,
        pageSize: UInt64,
        pages: MemoryPageStatistics
    ) -> MemorySnapshot {
        func bytes(_ pageCount: UInt64) -> UInt64 {
            let result = pageCount.multipliedReportingOverflow(by: pageSize)
            return result.overflow ? UInt64.max : result.partialValue
        }

        let active = bytes(pages.active)
        let inactive = bytes(pages.inactive)
        let wired = bytes(pages.wired)
        let compressed = bytes(pages.compressed)
        let cached = bytes(pages.fileBacked)
        let speculative = min(bytes(pages.speculative), cached)
        let free = bytes(pages.free)

        // XNU includes speculative pages in both free_count and
        // external_page_count. Count that overlap once when deriving the
        // reclaimable pool, then exclude the pool from user-facing used RAM.
        let fileCacheNotAlreadyFree = cached - speculative
        let reclaimable = min(totalBytes, free.addingClamped(fileCacheNotAlreadyFree))

        var snapshot = MemorySnapshot()
        snapshot.total = totalBytes
        snapshot.active = active
        snapshot.inactive = inactive
        snapshot.wired = wired
        snapshot.compressed = compressed
        snapshot.cached = cached
        snapshot.free = free
        snapshot.used = totalBytes - reclaimable
        return snapshot
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

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
        let total = ProcessInfo.processInfo.physicalMemory

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = withUnsafeMutablePointer(to: &swap) { pointer in
            sysctlbyname("vm.swapusage", pointer, &swapSize, nil, 0)
        }

        var snapshot = MemoryAccounting.snapshot(
            totalBytes: total,
            pageSize: page,
            pages: MemoryPageStatistics(
                active: UInt64(statistics.active_count),
                inactive: UInt64(statistics.inactive_count),
                wired: UInt64(statistics.wire_count),
                compressed: UInt64(statistics.compressor_page_count),
                fileBacked: UInt64(statistics.external_page_count),
                speculative: UInt64(statistics.speculative_count),
                free: UInt64(statistics.free_count)
            )
        )
        if swapResult == 0 {
            snapshot.swapUsed = UInt64(max(swap.xsu_used, 0))
            snapshot.swapTotal = UInt64(max(swap.xsu_total, 0))
        }
        snapshot.pressure = .available
        return snapshot
    }
}
