import Foundation

public enum MetricQuality: String, Codable, Sendable, CaseIterable {
    case measured
    case derived
    case estimated
}

public enum DataAvailability: String, Codable, Sendable, CaseIterable {
    case available
    case degraded
    case restricted
    case unsupported
    case unmapped
    case stale
}

public enum MetricKind: String, Codable, Sendable {
    case gauge
    case counter
    case state
    case information
}

public enum MetricValue: Codable, Hashable, Sendable {
    case number(Double)
    case text(String)
    case boolean(Bool)

    public var number: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var displayValue: String {
        switch self {
        case .number(let value): value.formatted(.number.precision(.fractionLength(0...2)))
        case .text(let value): value
        case .boolean(let value): value ? "Yes" : "No"
        }
    }
}

public struct MetricDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let source: String
    public let scope: String
    public let unit: String
    public let kind: MetricKind
    public let provenance: String
    public let availability: DataAvailability

    public init(
        id: String,
        name: String,
        source: String,
        scope: String,
        unit: String,
        kind: MetricKind = .gauge,
        provenance: String,
        availability: DataAvailability = .available
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.scope = scope
        self.unit = unit
        self.kind = kind
        self.provenance = provenance
        self.availability = availability
    }
}

public struct MetricSample: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(descriptorID)-\(timestamp.timeIntervalSince1970)" }
    public let descriptorID: String
    public let timestamp: Date
    public let value: MetricValue
    public let quality: MetricQuality
    public let availability: DataAvailability
    public let error: String?

    public init(
        descriptorID: String,
        timestamp: Date = .now,
        value: MetricValue,
        quality: MetricQuality = .measured,
        availability: DataAvailability = .available,
        error: String? = nil
    ) {
        self.descriptorID = descriptorID
        self.timestamp = timestamp
        self.value = value
        self.quality = quality
        self.availability = availability
        self.error = error
    }
}

public struct CPUCoreSnapshot: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let usage: Double
    public let user: Double
    public let system: Double
    public let idle: Double
    public let cluster: String

    public init(id: Int, usage: Double, user: Double, system: Double, idle: Double, cluster: String) {
        self.id = id
        self.usage = usage
        self.user = user
        self.system = system
        self.idle = idle
        self.cluster = cluster
    }
}

public struct MemorySnapshot: Codable, Hashable, Sendable {
    public var total: UInt64 = 0
    public var used: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressure: DataAvailability = .available

    public init() {}
}

public struct BatterySnapshot: Codable, Hashable, Sendable {
    public var isPresent = false
    public var name = "No battery"
    public var powerSourceState = "Unknown"
    public var chargePercent: Double?
    public var currentCapacity: Int?
    public var maximumCapacity: Int?
    public var designCapacity: Int?
    public var cycleCount: Int?
    public var designCycleCount: Int?
    public var healthPercent: Double?
    public var temperatureCelsius: Double?
    public var voltageMillivolts: Int?
    public var amperageMilliamps: Int?
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?
    public var isCharging = false
    public var isFullyCharged = false
    public var isExternalPowerConnected = false
    public var adapterName: String?
    public var adapterWatts: Double?
    public var batteryPowerWatts: Double?
    public var systemPowerWatts: Double?
    public var health: String?
    public var condition: String?
    public var availability: DataAvailability = .unsupported

    public init() {}
}

public struct NetworkInterfaceSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let addresses: [String]
    public let isUp: Bool
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetsIn: UInt64
    public let packetsOut: UInt64
    public let errorsIn: UInt64
    public let errorsOut: UInt64
    public let downloadRate: Double
    public let uploadRate: Double
}

/// Physical-device counters exported by the documented IOKit
/// `IOBlockStorageDriver` statistics dictionary.
///
/// A mounted APFS volume is not a physical disk, so multiple `DiskSnapshot`
/// values can intentionally contain the same I/O snapshot. `provenance` names
/// the physical device whose counters are being shown. Optional counters are
/// never replaced with invented zeroes when a driver does not expose them.
public struct DiskIOSnapshot: Codable, Hashable, Sendable {
    public let availability: DataAvailability
    public let provenance: String
    public let detail: String?
    public let sampledAt: Date?
    public let intervalDurationSeconds: Double?
    public let bytesRead: UInt64?
    public let bytesWritten: UInt64?
    public let readOperations: UInt64?
    public let writeOperations: UInt64?
    public let readErrors: UInt64?
    public let writeErrors: UInt64?
    public let readRetries: UInt64?
    public let writeRetries: UInt64?
    public let totalReadTimeNanoseconds: UInt64?
    public let totalWriteTimeNanoseconds: UInt64?
    public let totalReadLatencyNanoseconds: UInt64?
    public let totalWriteLatencyNanoseconds: UInt64?
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    public let readOperationsPerSecond: Double?
    public let writeOperationsPerSecond: Double?
    public let averageReadLatencyMilliseconds: Double?
    public let averageWriteLatencyMilliseconds: Double?
    public let bytesReadSinceLastSample: UInt64?
    public let bytesWrittenSinceLastSample: UInt64?
    public let readOperationsSinceLastSample: UInt64?
    public let writeOperationsSinceLastSample: UInt64?
    public let readErrorsSinceLastSample: UInt64?
    public let writeErrorsSinceLastSample: UInt64?
    public let readRetriesSinceLastSample: UInt64?
    public let writeRetriesSinceLastSample: UInt64?
    public let averageReadServiceTimeMilliseconds: Double?
    public let averageWriteServiceTimeMilliseconds: Double?
    public let averageReadRequestBytes: Double?
    public let averageWriteRequestBytes: Double?

    public init(
        availability: DataAvailability,
        provenance: String,
        detail: String? = nil,
        sampledAt: Date? = nil,
        intervalDurationSeconds: Double? = nil,
        bytesRead: UInt64? = nil,
        bytesWritten: UInt64? = nil,
        readOperations: UInt64? = nil,
        writeOperations: UInt64? = nil,
        readErrors: UInt64? = nil,
        writeErrors: UInt64? = nil,
        readRetries: UInt64? = nil,
        writeRetries: UInt64? = nil,
        totalReadTimeNanoseconds: UInt64? = nil,
        totalWriteTimeNanoseconds: UInt64? = nil,
        totalReadLatencyNanoseconds: UInt64? = nil,
        totalWriteLatencyNanoseconds: UInt64? = nil,
        readBytesPerSecond: Double? = nil,
        writeBytesPerSecond: Double? = nil,
        readOperationsPerSecond: Double? = nil,
        writeOperationsPerSecond: Double? = nil,
        averageReadLatencyMilliseconds: Double? = nil,
        averageWriteLatencyMilliseconds: Double? = nil,
        bytesReadSinceLastSample: UInt64? = nil,
        bytesWrittenSinceLastSample: UInt64? = nil,
        readOperationsSinceLastSample: UInt64? = nil,
        writeOperationsSinceLastSample: UInt64? = nil,
        readErrorsSinceLastSample: UInt64? = nil,
        writeErrorsSinceLastSample: UInt64? = nil,
        readRetriesSinceLastSample: UInt64? = nil,
        writeRetriesSinceLastSample: UInt64? = nil,
        averageReadServiceTimeMilliseconds: Double? = nil,
        averageWriteServiceTimeMilliseconds: Double? = nil,
        averageReadRequestBytes: Double? = nil,
        averageWriteRequestBytes: Double? = nil
    ) {
        self.availability = availability
        self.provenance = provenance
        self.detail = detail
        self.sampledAt = sampledAt
        self.intervalDurationSeconds = intervalDurationSeconds
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.readOperations = readOperations
        self.writeOperations = writeOperations
        self.readErrors = readErrors
        self.writeErrors = writeErrors
        self.readRetries = readRetries
        self.writeRetries = writeRetries
        self.totalReadTimeNanoseconds = totalReadTimeNanoseconds
        self.totalWriteTimeNanoseconds = totalWriteTimeNanoseconds
        self.totalReadLatencyNanoseconds = totalReadLatencyNanoseconds
        self.totalWriteLatencyNanoseconds = totalWriteLatencyNanoseconds
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOperationsPerSecond = readOperationsPerSecond
        self.writeOperationsPerSecond = writeOperationsPerSecond
        self.averageReadLatencyMilliseconds = averageReadLatencyMilliseconds
        self.averageWriteLatencyMilliseconds = averageWriteLatencyMilliseconds
        self.bytesReadSinceLastSample = bytesReadSinceLastSample
        self.bytesWrittenSinceLastSample = bytesWrittenSinceLastSample
        self.readOperationsSinceLastSample = readOperationsSinceLastSample
        self.writeOperationsSinceLastSample = writeOperationsSinceLastSample
        self.readErrorsSinceLastSample = readErrorsSinceLastSample
        self.writeErrorsSinceLastSample = writeErrorsSinceLastSample
        self.readRetriesSinceLastSample = readRetriesSinceLastSample
        self.writeRetriesSinceLastSample = writeRetriesSinceLastSample
        self.averageReadServiceTimeMilliseconds = averageReadServiceTimeMilliseconds
        self.averageWriteServiceTimeMilliseconds = averageWriteServiceTimeMilliseconds
        self.averageReadRequestBytes = averageReadRequestBytes
        self.averageWriteRequestBytes = averageWriteRequestBytes
    }

    public var totalBytesPerSecond: Double? {
        Self.sum(readBytesPerSecond, writeBytesPerSecond)
    }

    public var totalOperationsPerSecond: Double? {
        Self.sum(readOperationsPerSecond, writeOperationsPerSecond)
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

public struct DiskSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { mountPoint }
    public let name: String
    public let mountPoint: String
    public let fileSystem: String
    public let total: UInt64
    public let available: UInt64
    public let isReadOnly: Bool
    /// Stable volume UUID where Disk Arbitration exposes one, otherwise its
    /// current BSD device name. This identifies the mounted volume, not the
    /// physical storage device.
    public let deviceIdentifier: String?
    public let volumeBSDName: String?
    /// BSD identifier and I/O Registry label for the physical device that
    /// services this volume. APFS sibling volumes can share these values.
    public let physicalDeviceIdentifier: String?
    public let physicalDeviceName: String?
    /// Space macOS can make available to important/opportunistic consumers.
    /// These values can include purgeable space and are kept separate from
    /// `available`, which is the currently free volume capacity.
    public let availableForImportantUsage: UInt64?
    public let availableForOpportunisticUsage: UInt64?
    public let io: DiskIOSnapshot?

    public init(
        name: String,
        mountPoint: String,
        fileSystem: String,
        total: UInt64,
        available: UInt64,
        isReadOnly: Bool,
        deviceIdentifier: String? = nil,
        volumeBSDName: String? = nil,
        physicalDeviceIdentifier: String? = nil,
        physicalDeviceName: String? = nil,
        availableForImportantUsage: UInt64? = nil,
        availableForOpportunisticUsage: UInt64? = nil,
        io: DiskIOSnapshot? = nil
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.total = total
        self.available = available
        self.isReadOnly = isReadOnly
        self.deviceIdentifier = deviceIdentifier
        self.volumeBSDName = volumeBSDName
        self.physicalDeviceIdentifier = physicalDeviceIdentifier
        self.physicalDeviceName = physicalDeviceName
        self.availableForImportantUsage = availableForImportantUsage
        self.availableForOpportunisticUsage = availableForOpportunisticUsage
        self.io = io
    }

    public var used: UInt64 {
        total - min(available, total)
    }

    public var usageFraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    /// Space that is not free now but macOS reports it can reclaim for an
    /// important consumer. Nil means the filesystem did not report that tier.
    public var reclaimable: UInt64 {
        guard let availableForImportantUsage else { return 0 }
        return availableForImportantUsage - min(available, availableForImportantUsage)
    }
}

public struct ProcessSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let executablePath: String?
    public let userID: UInt32
    public let state: String
    public let cpuPercent: Double
    public let residentMemory: UInt64
    public let virtualMemory: UInt64
    public let threads: Int32
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    public let startedAt: Date?
    public let availability: DataAvailability

    public init(
        pid: Int32,
        parentPID: Int32,
        name: String,
        executablePath: String?,
        userID: UInt32,
        state: String,
        cpuPercent: Double,
        residentMemory: UInt64,
        virtualMemory: UInt64,
        threads: Int32,
        bytesRead: UInt64,
        bytesWritten: UInt64,
        startedAt: Date?,
        availability: DataAvailability = .available
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.userID = userID
        self.state = state
        self.cpuPercent = cpuPercent
        self.residentMemory = residentMemory
        self.virtualMemory = virtualMemory
        self.threads = threads
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.startedAt = startedAt
        self.availability = availability
    }
}

public enum StartupDomain: String, Codable, Hashable, Sendable, CaseIterable {
    case user
    case local
    case system
}

public struct StartupItem: Identifiable, Codable, Hashable, Sendable {
    /// The property-list path is the stable definition identity. Labels are not
    /// unique across LaunchAgents and LaunchDaemons, even within the same
    /// effective launchd domain.
    public var id: String { "\(domain.rawValue):\(sourcePath)" }
    public let label: String
    public let domain: StartupDomain
    public let sourcePath: String
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let isEnabled: Bool?
    public let isLoaded: Bool?
    public let availability: DataAvailability

    /// LaunchAgents live in the per-user GUI domain regardless of whether the
    /// plist is owned by the user, /Library, or /System. LaunchDaemons live in
    /// the system domain.
    public var launchDomain: LaunchDomain {
        if sourcePath.split(separator: "/").contains("LaunchAgents") || domain == .user {
            return .gui
        }
        return .system
    }

    public init(
        label: String,
        domain: StartupDomain,
        sourcePath: String,
        program: String? = nil,
        arguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        isEnabled: Bool? = nil,
        isLoaded: Bool? = nil,
        availability: DataAvailability = .available
    ) {
        self.label = label
        self.domain = domain
        self.sourcePath = sourcePath
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
        self.availability = availability
    }
}

public struct SMARTAttribute: Identifiable, Codable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let value: String
    public let unit: String
    public let threshold: String?
}

public struct SMARTReport: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let deviceName: String
    public let protocolName: String
    public let health: String
    public let attributes: [SMARTAttribute]
    public let availability: DataAvailability
    public let detail: String?
}

public struct NetworkConnection: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let pid: Int32
    public let protocolName: String
    public let localAddress: String
    public let remoteAddress: String
    public let state: String
    public let availability: DataAvailability
}

public struct GPUDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let coreCount: Int?
    public let isBuiltIn: Bool

    public init(name: String, coreCount: Int? = nil, isBuiltIn: Bool = true) {
        self.name = name
        self.coreCount = coreCount
        self.isBuiltIn = isBuiltIn
    }
}

public struct HardwareInventory: Codable, Hashable, Sendable {
    public var modelName = "Unknown Mac"
    public var modelIdentifier = "Unknown"
    public var chip = "Unknown"
    public var architecture = "arm64"
    public var physicalMemory: UInt64 = 0
    public var processorCount = 0
    public var activeProcessorCount = 0
    public var osVersion = "Unknown"
    public var kernelVersion = "Unknown"
    public var uptime: TimeInterval = 0
    /// nil means detection has not completed; an empty array means no GPU was found.
    public var gpus: [GPUDevice]?
    public var details: [String: String] = [:]

    public init() {}
}

public struct DeepTelemetrySnapshot: Codable, Hashable, Sendable {
    // Optional for wire compatibility with older installed helper versions.
    public var helperConnected: Bool?
    public var gpuUsage: Double?
    public var gpuFrequencyMHz: Double?
    public var gpuPowerWatts: Double?
    public var aneUsage: Double?
    public var aneFrequencyMHz: Double?
    public var anePowerWatts: Double?
    public var cpuFrequencyMHz: Double?
    public var cpuPowerWatts: Double?
    public var thermalPressure: String?
    public var sensors: [String: Double]
    public var fanSpeeds: [String: Double]
    public var availability: DataAvailability
    public var detail: String?

    public init(availability: DataAvailability = .restricted, detail: String? = nil) {
        self.sensors = [:]
        self.fanSpeeds = [:]
        self.availability = availability
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case helperConnected, gpuUsage, gpuFrequencyMHz, gpuPowerWatts
        case aneUsage, aneFrequencyMHz, anePowerWatts
        case cpuFrequencyMHz, cpuPowerWatts, thermalPressure
        case sensors, fanSpeeds, availability, detail
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        helperConnected = try values.decodeIfPresent(Bool.self, forKey: .helperConnected)
        gpuUsage = try values.decodeIfPresent(Double.self, forKey: .gpuUsage)
        gpuFrequencyMHz = try values.decodeIfPresent(Double.self, forKey: .gpuFrequencyMHz)
        gpuPowerWatts = try values.decodeIfPresent(Double.self, forKey: .gpuPowerWatts)
        aneUsage = try values.decodeIfPresent(Double.self, forKey: .aneUsage)
        aneFrequencyMHz = try values.decodeIfPresent(Double.self, forKey: .aneFrequencyMHz)
        anePowerWatts = try values.decodeIfPresent(Double.self, forKey: .anePowerWatts)
        cpuFrequencyMHz = try values.decodeIfPresent(Double.self, forKey: .cpuFrequencyMHz)
        cpuPowerWatts = try values.decodeIfPresent(Double.self, forKey: .cpuPowerWatts)
        thermalPressure = try values.decodeIfPresent(String.self, forKey: .thermalPressure)
        sensors = try values.decodeIfPresent([String: Double].self, forKey: .sensors) ?? [:]
        fanSpeeds = try values.decodeIfPresent([String: Double].self, forKey: .fanSpeeds) ?? [:]
        availability = try values.decodeIfPresent(DataAvailability.self, forKey: .availability) ?? .degraded
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(helperConnected, forKey: .helperConnected)
        try values.encodeIfPresent(gpuUsage, forKey: .gpuUsage)
        try values.encodeIfPresent(gpuFrequencyMHz, forKey: .gpuFrequencyMHz)
        try values.encodeIfPresent(gpuPowerWatts, forKey: .gpuPowerWatts)
        try values.encodeIfPresent(aneUsage, forKey: .aneUsage)
        try values.encodeIfPresent(aneFrequencyMHz, forKey: .aneFrequencyMHz)
        try values.encodeIfPresent(anePowerWatts, forKey: .anePowerWatts)
        try values.encodeIfPresent(cpuFrequencyMHz, forKey: .cpuFrequencyMHz)
        try values.encodeIfPresent(cpuPowerWatts, forKey: .cpuPowerWatts)
        try values.encodeIfPresent(thermalPressure, forKey: .thermalPressure)
        try values.encode(sensors, forKey: .sensors)
        try values.encode(fanSpeeds, forKey: .fanSpeeds)
        try values.encode(availability, forKey: .availability)
        try values.encodeIfPresent(detail, forKey: .detail)
    }
}

public struct SystemSnapshot: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let cpuUsage: Double
    public let cpuUser: Double
    public let cpuSystem: Double
    public let loadAverages: [Double]
    public let cores: [CPUCoreSnapshot]
    public let memory: MemorySnapshot
    public let battery: BatterySnapshot
    public let networks: [NetworkInterfaceSnapshot]
    public let disks: [DiskSnapshot]
    public let processes: [ProcessSnapshot]
    public let startupItems: [StartupItem]
    /// Changes only when the startup collector publishes a new valid result.
    /// Optional for backward-compatible decoding of recorded snapshot fixtures.
    public let startupRevision: UInt64?
    public let smartReports: [SMARTReport]
    public let connections: [NetworkConnection]
    public let inventory: HardwareInventory
    public let deep: DeepTelemetrySnapshot
    public let metrics: [MetricSample]

    public init(
        timestamp: Date = .now,
        cpuUsage: Double = 0,
        cpuUser: Double = 0,
        cpuSystem: Double = 0,
        loadAverages: [Double] = [],
        cores: [CPUCoreSnapshot] = [],
        memory: MemorySnapshot = .init(),
        battery: BatterySnapshot = .init(),
        networks: [NetworkInterfaceSnapshot] = [],
        disks: [DiskSnapshot] = [],
        processes: [ProcessSnapshot] = [],
        startupItems: [StartupItem] = [],
        startupRevision: UInt64? = nil,
        smartReports: [SMARTReport] = [],
        connections: [NetworkConnection] = [],
        inventory: HardwareInventory = .init(),
        deep: DeepTelemetrySnapshot = .init(),
        metrics: [MetricSample] = []
    ) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.loadAverages = loadAverages
        self.cores = cores
        self.memory = memory
        self.battery = battery
        self.networks = networks
        self.disks = disks
        self.processes = processes
        self.startupItems = startupItems
        self.startupRevision = startupRevision
        self.smartReports = smartReports
        self.connections = connections
        self.inventory = inventory
        self.deep = deep
        self.metrics = metrics
    }
}

public struct CollectorHealth: Codable, Hashable, Sendable {
    public let collectorID: String
    public let availability: DataAvailability
    public let lastSampleAt: Date?
    public let message: String?
}

public protocol Collector: Sendable {
    associatedtype Output: Sendable
    var id: String { get }
    func capabilities() async -> [MetricDescriptor]
    func sample() async throws -> Output
}
