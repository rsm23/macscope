import Darwin
import DiskArbitration
import Foundation
import IOKit

struct DiskIOCounters: Equatable, Sendable {
    let bytesRead: UInt64?
    let bytesWritten: UInt64?
    let readOperations: UInt64?
    let writeOperations: UInt64?
    let readErrors: UInt64?
    let writeErrors: UInt64?
    let readRetries: UInt64?
    let writeRetries: UInt64?
    let totalReadTimeNanoseconds: UInt64?
    let totalWriteTimeNanoseconds: UInt64?
    let totalReadLatencyNanoseconds: UInt64?
    let totalWriteLatencyNanoseconds: UInt64?

    init?(statistics: [String: Any]) {
        bytesRead = Self.counter(statistics, "Bytes (Read)")
        bytesWritten = Self.counter(statistics, "Bytes (Write)")
        readOperations = Self.counter(statistics, "Operations (Read)")
        writeOperations = Self.counter(statistics, "Operations (Write)")
        readErrors = Self.counter(statistics, "Errors (Read)")
        writeErrors = Self.counter(statistics, "Errors (Write)")
        readRetries = Self.counter(statistics, "Retries (Read)")
        writeRetries = Self.counter(statistics, "Retries (Write)")
        totalReadTimeNanoseconds = Self.counter(statistics, "Total Time (Read)")
        totalWriteTimeNanoseconds = Self.counter(statistics, "Total Time (Write)")
        totalReadLatencyNanoseconds = Self.counter(statistics, "Latency Time (Read)")
        totalWriteLatencyNanoseconds = Self.counter(statistics, "Latency Time (Write)")

        guard bytesRead != nil || bytesWritten != nil || readOperations != nil || writeOperations != nil else {
            return nil
        }
    }

    private static func counter(_ statistics: [String: Any], _ key: String) -> UInt64? {
        guard let number = statistics[key] as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.uint64Value
    }
}

struct TimedDiskIOCounters: Equatable, Sendable {
    let timestamp: Date
    let counters: DiskIOCounters
}

enum DiskIOMetricDeriver {
    static func snapshot(
        counters: DiskIOCounters,
        previous: TimedDiskIOCounters?,
        timestamp: Date,
        provenance: String
    ) -> DiskIOSnapshot {
        let elapsed = previous.map { timestamp.timeIntervalSince($0.timestamp) }
        let isUsableInterval = elapsed.map { $0 > 0 && $0.isFinite } ?? false
        let prior = previous?.counters

        let readBytesDelta = delta(counters.bytesRead, prior?.bytesRead)
        let writeBytesDelta = delta(counters.bytesWritten, prior?.bytesWritten)
        let readOperationsDelta = delta(counters.readOperations, prior?.readOperations)
        let writeOperationsDelta = delta(counters.writeOperations, prior?.writeOperations)
        let readErrorsDelta = delta(counters.readErrors, prior?.readErrors)
        let writeErrorsDelta = delta(counters.writeErrors, prior?.writeErrors)
        let readRetriesDelta = delta(counters.readRetries, prior?.readRetries)
        let writeRetriesDelta = delta(counters.writeRetries, prior?.writeRetries)
        let readTimeDelta = delta(counters.totalReadTimeNanoseconds, prior?.totalReadTimeNanoseconds)
        let writeTimeDelta = delta(counters.totalWriteTimeNanoseconds, prior?.totalWriteTimeNanoseconds)
        let readLatencyDelta = delta(counters.totalReadLatencyNanoseconds, prior?.totalReadLatencyNanoseconds)
        let writeLatencyDelta = delta(counters.totalWriteLatencyNanoseconds, prior?.totalWriteLatencyNanoseconds)

        let resetDetected = previous != nil && [
            reset(counters.bytesRead, prior?.bytesRead),
            reset(counters.bytesWritten, prior?.bytesWritten),
            reset(counters.readOperations, prior?.readOperations),
            reset(counters.writeOperations, prior?.writeOperations),
            reset(counters.readErrors, prior?.readErrors),
            reset(counters.writeErrors, prior?.writeErrors),
            reset(counters.readRetries, prior?.readRetries),
            reset(counters.writeRetries, prior?.writeRetries),
            reset(counters.totalReadTimeNanoseconds, prior?.totalReadTimeNanoseconds),
            reset(counters.totalWriteTimeNanoseconds, prior?.totalWriteTimeNanoseconds),
            reset(counters.totalReadLatencyNanoseconds, prior?.totalReadLatencyNanoseconds),
            reset(counters.totalWriteLatencyNanoseconds, prior?.totalWriteLatencyNanoseconds)
        ].contains(true)

        let detail: String?
        if previous == nil {
            detail = "Cumulative physical-device counters are available; live rates require a second sample."
        } else if !isUsableInterval {
            detail = "The sampling interval was invalid, so live rates are unavailable for this sample."
        } else if resetDetected {
            detail = "One or more physical-driver counters reset; affected live rates are unavailable for this interval."
        } else {
            detail = nil
        }

        return DiskIOSnapshot(
            availability: .available,
            provenance: provenance,
            detail: detail,
            sampledAt: timestamp,
            intervalDurationSeconds: isUsableInterval ? elapsed : nil,
            bytesRead: counters.bytesRead,
            bytesWritten: counters.bytesWritten,
            readOperations: counters.readOperations,
            writeOperations: counters.writeOperations,
            readErrors: counters.readErrors,
            writeErrors: counters.writeErrors,
            readRetries: counters.readRetries,
            writeRetries: counters.writeRetries,
            totalReadTimeNanoseconds: counters.totalReadTimeNanoseconds,
            totalWriteTimeNanoseconds: counters.totalWriteTimeNanoseconds,
            totalReadLatencyNanoseconds: counters.totalReadLatencyNanoseconds,
            totalWriteLatencyNanoseconds: counters.totalWriteLatencyNanoseconds,
            readBytesPerSecond: rate(readBytesDelta, elapsed: elapsed, usable: isUsableInterval),
            writeBytesPerSecond: rate(writeBytesDelta, elapsed: elapsed, usable: isUsableInterval),
            readOperationsPerSecond: rate(readOperationsDelta, elapsed: elapsed, usable: isUsableInterval),
            writeOperationsPerSecond: rate(writeOperationsDelta, elapsed: elapsed, usable: isUsableInterval),
            averageReadLatencyMilliseconds: averageMilliseconds(readLatencyDelta, operations: readOperationsDelta),
            averageWriteLatencyMilliseconds: averageMilliseconds(writeLatencyDelta, operations: writeOperationsDelta),
            bytesReadSinceLastSample: isUsableInterval ? readBytesDelta : nil,
            bytesWrittenSinceLastSample: isUsableInterval ? writeBytesDelta : nil,
            readOperationsSinceLastSample: isUsableInterval ? readOperationsDelta : nil,
            writeOperationsSinceLastSample: isUsableInterval ? writeOperationsDelta : nil,
            readErrorsSinceLastSample: isUsableInterval ? readErrorsDelta : nil,
            writeErrorsSinceLastSample: isUsableInterval ? writeErrorsDelta : nil,
            readRetriesSinceLastSample: isUsableInterval ? readRetriesDelta : nil,
            writeRetriesSinceLastSample: isUsableInterval ? writeRetriesDelta : nil,
            averageReadServiceTimeMilliseconds: averageMilliseconds(readTimeDelta, operations: readOperationsDelta),
            averageWriteServiceTimeMilliseconds: averageMilliseconds(writeTimeDelta, operations: writeOperationsDelta),
            averageReadRequestBytes: averageBytes(readBytesDelta, operations: readOperationsDelta),
            averageWriteRequestBytes: averageBytes(writeBytesDelta, operations: writeOperationsDelta)
        )
    }

    private static func delta(_ current: UInt64?, _ previous: UInt64?) -> UInt64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    private static func reset(_ current: UInt64?, _ previous: UInt64?) -> Bool {
        guard let current, let previous else { return false }
        return current < previous
    }

    private static func rate(_ delta: UInt64?, elapsed: TimeInterval?, usable: Bool) -> Double? {
        guard usable, let delta, let elapsed else { return nil }
        return Double(delta) / elapsed
    }

    private static func averageMilliseconds(_ nanoseconds: UInt64?, operations: UInt64?) -> Double? {
        guard let nanoseconds, let operations, operations > 0 else { return nil }
        return Double(nanoseconds) / Double(operations) / 1_000_000
    }

    private static func averageBytes(_ bytes: UInt64?, operations: UInt64?) -> Double? {
        guard let bytes, let operations, operations > 0 else { return nil }
        return Double(bytes) / Double(operations)
    }
}

private struct VolumeIdentity: Sendable {
    let deviceIdentifier: String?
    let bsdName: String?
}

private struct PhysicalDiskIOResolution: Sendable {
    let identifier: String
    let name: String
    let counters: DiskIOCounters
}

public actor StorageCollector: Collector {
    public let id = "storage"
    private var previousIOCounters: [String: TimedDiskIOCounters] = [:]

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [
            MetricDescriptor(id: "storage.capacity", name: "Volume Capacity", source: "Foundation/BSD", scope: "mounted volume", unit: "bytes", provenance: "URLResourceValues + statfs"),
            MetricDescriptor(id: "storage.io.bytes", name: "Physical Disk I/O", source: "IOKit", scope: "physical device", unit: "bytes", kind: .counter, provenance: "IOBlockStorageDriver Statistics", availability: .degraded),
            MetricDescriptor(id: "storage.io.rate", name: "Physical Disk Throughput", source: "IOKit", scope: "physical device", unit: "bytes/s", provenance: "Delta of IOBlockStorageDriver Statistics", availability: .degraded),
            MetricDescriptor(id: "storage.io.operations", name: "Physical Disk Operations", source: "IOKit", scope: "physical device", unit: "operations", kind: .counter, provenance: "IOBlockStorageDriver Statistics", availability: .degraded),
            MetricDescriptor(id: "storage.io.latency", name: "Physical Disk Latency", source: "IOKit", scope: "physical device", unit: "ms", provenance: "Delta of IOBlockStorageDriver latency and total-time counters", availability: .degraded),
            MetricDescriptor(id: "storage.io.errors", name: "Physical Disk Errors", source: "IOKit", scope: "physical device", unit: "errors", kind: .counter, provenance: "IOBlockStorageDriver Statistics", availability: .degraded)
        ]
    }

    public func sample() async throws -> [DiskSnapshot] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeIsReadOnlyKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        let timestamp = Date.now
        var currentCounters: [String: TimedDiskIOCounters] = [:]
        var sampledIO: [String: DiskIOSnapshot] = [:]

        let snapshots = urls.compactMap { url -> DiskSnapshot? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let identity = volumeIdentity(at: url.path)
            let resolution = identity.bsdName.flatMap(resolvePhysicalIO(forBSDName:))
            let io: DiskIOSnapshot

            if let resolution {
                if let cached = sampledIO[resolution.identifier] {
                    io = cached
                } else {
                    let provenance = "IOKit IOBlockStorageDriver Statistics for \(resolution.name) (\(resolution.identifier))"
                    io = DiskIOMetricDeriver.snapshot(
                        counters: resolution.counters,
                        previous: previousIOCounters[resolution.identifier],
                        timestamp: timestamp,
                        provenance: provenance
                    )
                    sampledIO[resolution.identifier] = io
                    currentCounters[resolution.identifier] = TimedDiskIOCounters(timestamp: timestamp, counters: resolution.counters)
                }
            } else {
                io = DiskIOSnapshot(
                    availability: identity.bsdName == nil ? .unsupported : .degraded,
                    provenance: identity.bsdName.map { "Mounted volume \($0)" } ?? "Mounted volume without a BSD block device",
                    detail: identity.bsdName == nil
                        ? "This volume is not backed by a discoverable local block device."
                        : "The backing device did not expose documented IOBlockStorageDriver counters.",
                    sampledAt: timestamp
                )
            }

            let actualAvailable = capacity(values.volumeAvailableCapacity)
                ?? capacity(values.volumeAvailableCapacityForImportantUsage)
                ?? 0
            return DiskSnapshot(
                name: values.volumeName ?? url.lastPathComponent,
                mountPoint: url.path,
                fileSystem: fileSystemName(at: url.path),
                total: UInt64(max(values.volumeTotalCapacity ?? 0, 0)),
                available: actualAvailable,
                isReadOnly: values.volumeIsReadOnly ?? false,
                deviceIdentifier: identity.deviceIdentifier,
                volumeBSDName: identity.bsdName,
                physicalDeviceIdentifier: resolution?.identifier,
                physicalDeviceName: resolution?.name,
                availableForImportantUsage: capacity(values.volumeAvailableCapacityForImportantUsage),
                availableForOpportunisticUsage: capacity(values.volumeAvailableCapacityForOpportunisticUsage),
                io: io
            )
        }.sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }

        previousIOCounters = currentCounters
        return snapshots
    }

    private func capacity(_ value: Int64?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    private func capacity(_ value: Int?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    private func volumeIdentity(at path: String) -> VolumeIdentity {
        var statistics = statfs()
        guard path.withCString({ statfs($0, &statistics) }) == 0 else {
            return VolumeIdentity(deviceIdentifier: nil, bsdName: nil)
        }
        let mountSource = withUnsafePointer(to: &statistics.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        guard mountSource.hasPrefix("/dev/") else {
            return VolumeIdentity(deviceIdentifier: nil, bsdName: nil)
        }
        let bsdName = String(mountSource.dropFirst("/dev/".count))
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, mountSource),
              let description = DADiskCopyDescription(disk) as NSDictionary? else {
            return VolumeIdentity(deviceIdentifier: bsdName, bsdName: bsdName)
        }
        let uuidValue = description[kDADiskDescriptionVolumeUUIDKey]
        let stableIdentifier: String?
        if let uuidValue, CFGetTypeID(uuidValue as CFTypeRef) == CFUUIDGetTypeID() {
            let uuid = unsafeBitCast(uuidValue as CFTypeRef, to: CFUUID.self)
            stableIdentifier = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
        } else {
            stableIdentifier = nil
        }
        return VolumeIdentity(deviceIdentifier: stableIdentifier ?? bsdName, bsdName: bsdName)
    }

    private func resolvePhysicalIO(forBSDName bsdName: String) -> PhysicalDiskIOResolution? {
        let matching = bsdName.withCString { IOBSDNameMatching(kIOMainPortDefault, 0, $0) }
        guard let matching else { return nil }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(current) }

        var physicalIdentifier = bsdName
        var physicalName = bsdName
        var depth = 0
        while current != IO_OBJECT_NULL, depth < 64 {
            depth += 1
            let properties = registryProperties(for: current)

            if object(current, conformsTo: "IOMedia"),
               (properties?["Whole"] as? NSNumber)?.boolValue == true {
                if let identifier = properties?["BSD Name"] as? String {
                    physicalIdentifier = identifier
                }
                if let registryName = registryName(for: current), !registryName.isEmpty {
                    physicalName = registryName.replacingOccurrences(of: " Media", with: "")
                }
            }

            if object(current, conformsTo: "IOBlockStorageDriver"),
               let statistics = properties?["Statistics"] as? [String: Any],
               let counters = DiskIOCounters(statistics: statistics) {
                return PhysicalDiskIOResolution(identifier: physicalIdentifier, name: physicalName, counters: counters)
            }

            var parent = io_registry_entry_t()
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != IO_OBJECT_NULL else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private func registryProperties(for service: io_registry_entry_t) -> [String: Any]? {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanagedProperties?.takeRetainedValue() as? [String: Any]
    }

    private func object(_ object: io_object_t, conformsTo className: String) -> Bool {
        className.withCString { IOObjectConformsTo(object, $0) != 0 }
    }

    private func registryName(for service: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func fileSystemName(at path: String) -> String {
        var statistics = statfs()
        guard path.withCString({ statfs($0, &statistics) }) == 0 else { return "Unknown" }
        return withUnsafePointer(to: &statistics.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
    }
}

public actor SMARTCollector: Collector {
    public let id = "smart"

    public init() {}

    public func capabilities() async -> [MetricDescriptor] {
        [MetricDescriptor(
            id: "smart.health",
            name: "SMART Health",
            source: "IOKit",
            scope: "physical disk",
            unit: "state",
            kind: .state,
            provenance: "IONVMeSMARTInterface / IOATASMARTInterface",
            availability: .degraded
        )]
    }

    public func sample() async throws -> [SMARTReport] {
        // Full COM-vtable SMART access remains isolated behind this capability.
        // Surface the system-reported health now instead of fabricating raw fields.
        let result = await CommandRunner.run(executable: "/usr/sbin/diskutil", arguments: ["info", "disk0"], timeout: 5)
        guard result.exitCode == 0 else {
            return [SMARTReport(id: "disk0", deviceName: "disk0", protocolName: "Unknown", health: "Unavailable", attributes: [], availability: .restricted, detail: result.stderr)]
        }
        let fields = KeyValueTextParser.parse(result.stdout)
        let health = fields["SMART Status"] ?? "Not reported"
        return [SMARTReport(
            id: "disk0",
            deviceName: fields["Device / Media Name"] ?? "disk0",
            protocolName: fields["Protocol"] ?? "Unknown",
            health: health,
            attributes: fields.sorted(by: { $0.key < $1.key }).map {
                SMARTAttribute(key: $0.key, name: $0.key, value: $0.value, unit: "", threshold: nil)
            },
            availability: health == "Not reported" ? .degraded : .available,
            detail: health == "Not reported" ? "The device or enclosure did not expose SMART health." : nil
        )]
    }
}
