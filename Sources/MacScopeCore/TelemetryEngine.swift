import Foundation

public enum SamplingProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case lowImpact
    case balanced
    case maximum

    public var id: String { rawValue }

    public var publicInterval: Duration {
        switch self {
        case .lowImpact: .seconds(5)
        case .balanced: .seconds(1)
        case .maximum: .milliseconds(500)
        }
    }
}

/// Monotonic, elapsed-time scheduling for collectors that should not run on every public tick.
/// Keeping this independent from `SamplingProfile` means a 500 ms profile does not accidentally
/// poll deep telemetry four times faster, while a 5 second profile simply runs a due lane on its
/// next available public tick.
struct TelemetryCadence: Sendable {
    enum Lane: Hashable, Sendable {
        case deep
        case thermal
        case smc
        case storage
        case startup
        case smart
        case inventory
    }

    private var lastStartedAt: [Lane: ContinuousClock.Instant] = [:]

    static func interval(for lane: Lane) -> Duration {
        switch lane {
        case .deep, .thermal, .smc:
            .seconds(2)
        case .storage:
            // Physical IOBlockStorageDriver counters are lightweight and need
            // a short delta interval for genuinely live throughput and IOPS.
            // The public loop still bounds Low Impact to its five-second tick.
            .seconds(1)
        case .startup:
            .seconds(60)
        case .smart:
            .seconds(15 * 60)
        case .inventory:
            .seconds(60 * 60)
        }
    }

    mutating func shouldStart(_ lane: Lane, at now: ContinuousClock.Instant) -> Bool {
        if let previous = lastStartedAt[lane], previous.duration(to: now) < Self.interval(for: lane) {
            return false
        }
        lastStartedAt[lane] = now
        return true
    }
}

/// Values from slow collectors remain visible until that collector produces another valid sample.
/// The local thermal sources are retained separately so an unavailable helper cannot erase them.
struct RetainedTelemetryCache: Sendable {
    private(set) var inventory = HardwareInventory()
    private(set) var startup: [StartupItem] = []
    private(set) var startupRevision: UInt64 = 0
    private(set) var smart: [SMARTReport] = []
    private(set) var disks: [DiskSnapshot] = []
    private(set) var deep = DeepTelemetrySnapshot()

    private var privilegedSensors: [String: Double] = [:]
    private var privilegedFanSpeeds: [String: Double] = [:]
    private var thermalSensors: [String: Double] = [:]
    private var smcTemperatures: [String: Double] = [:]
    private var smcFanSpeeds: [String: Double] = [:]

    mutating func updateInventory(_ value: HardwareInventory?) {
        if let value { inventory = value }
    }

    mutating func updateStartup(_ value: [StartupItem]?) {
        if let value {
            startup = value
            startupRevision &+= 1
        }
    }

    mutating func updateSMART(_ value: [SMARTReport]?) {
        if let value { smart = value }
    }

    mutating func updateDisks(_ value: [DiskSnapshot]?) {
        // A running macOS system always has at least its root volume. Treat an empty discovery
        // result as transient once a valid inventory has been observed.
        guard let value, !value.isEmpty || disks.isEmpty else { return }
        disks = value
    }

    mutating func updateDeep(_ value: DeepTelemetrySnapshot?) {
        guard var value else { return }
        if !value.sensors.isEmpty { privilegedSensors = value.sensors }
        if !value.fanSpeeds.isEmpty { privilegedFanSpeeds = value.fanSpeeds }
        value.sensors = combinedSensors
        value.fanSpeeds = combinedFanSpeeds
        deep = value
        exposeLocalSensorAvailability()
    }

    mutating func updateThermals(_ value: [String: Double]?) {
        guard let value, !value.isEmpty else { return }
        thermalSensors = value
        deep.sensors = combinedSensors
        exposeLocalSensorAvailability()
    }

    mutating func updateSMC(_ value: SMCSensorReadings?) {
        guard let value else { return }
        if !value.temperatures.isEmpty { smcTemperatures = value.temperatures }
        if !value.fanSpeeds.isEmpty { smcFanSpeeds = value.fanSpeeds }
        deep.sensors = combinedSensors
        deep.fanSpeeds = combinedFanSpeeds
        exposeLocalSensorAvailability()
    }

    private var combinedSensors: [String: Double] {
        privilegedSensors
            .merging(thermalSensors) { _, local in local }
            .merging(smcTemperatures) { _, smc in smc }
    }

    private var combinedFanSpeeds: [String: Double] {
        privilegedFanSpeeds.merging(smcFanSpeeds) { _, smc in smc }
    }

    private mutating func exposeLocalSensorAvailability() {
        if (!thermalSensors.isEmpty || !smcTemperatures.isEmpty || !smcFanSpeeds.isEmpty),
           deep.availability == .restricted {
            deep.availability = .degraded
        }
    }
}

public actor TelemetryEngine {
    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let battery = BatteryCollector()
    private let network = NetworkCollector()
    private let storage = StorageCollector()
    private let processes = ProcessCollector()
    private let startup = StartupCollector()
    private let smart = SMARTCollector()
    private let inventory = InventoryCollector()
    private let deep = DeepTelemetryCollector()
    private let thermals = ThermalSensorCollector()
    private let smc = SMCSensorCollector()
    private let history: TelemetryHistory
    private let database: TelemetryDatabase?

    private var profile: SamplingProfile
    private var task: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SystemSnapshot>.Continuation] = [:]
    private var alertContinuations: [UUID: AsyncStream<UsageAlertEvent>.Continuation] = [:]
    private var alertEvaluator = UsageAlertEvaluator()
    private var alertConfiguration = UsageAlertConfiguration.default
    private var cache = RetainedTelemetryCache()
    private var cadence = TelemetryCadence()
    private var deepTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var smcTask: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var tick = 0
    private var processHistoryEnabled = false

    public init(profile: SamplingProfile = .balanced, history: TelemetryHistory = TelemetryHistory(), database: TelemetryDatabase? = try? TelemetryDatabase()) {
        self.profile = profile
        self.history = history
        self.database = database
    }

    deinit { task?.cancel() }

    public func stream() -> AsyncStream<SystemSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// A separate, oldest-preserving channel keeps rare alerts independent
    /// from the newest-only telemetry stream used to render the UI.
    public func alertStream() -> AsyncStream<UsageAlertEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            alertContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAlertContinuation(id) }
            }
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        // Paused wall-clock time must never satisfy a sustained threshold.
        alertEvaluator = UsageAlertEvaluator()
    }

    public func setProfile(_ value: SamplingProfile) {
        profile = value
        stop()
        start()
    }

    public func setProcessHistoryEnabled(_ enabled: Bool) {
        processHistoryEnabled = enabled
    }

    public func setUsageAlertConfiguration(_ configuration: UsageAlertConfiguration) {
        alertConfiguration = configuration
        // A changed threshold or timing policy starts a fresh observation
        // window instead of inheriting state collected under older settings.
        alertEvaluator = UsageAlertEvaluator()
    }

    public func refreshStartup() async {
        cache.updateStartup(try? await startup.sample())
    }

    public func recentSnapshots() async -> [SystemSnapshot] {
        await history.snapshots()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func removeAlertContinuation(_ id: UUID) {
        alertContinuations.removeValue(forKey: id)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            if let snapshot = await collect(at: started) {
                let alerts = alertEvaluator.evaluate(
                    snapshot: snapshot,
                    configuration: alertConfiguration,
                    at: snapshot.timestamp
                )
                for alert in alerts {
                    alertContinuations.values.forEach { $0.yield(alert) }
                }
                await history.append(snapshot)
                let includeProcesses = processHistoryEnabled && tick.isMultiple(of: 5)
                try? await database?.record(snapshot, includeMetrics: true, includeProcesses: includeProcesses)
                if tick.isMultiple(of: 3_600) { try? await database?.prune() }
                continuations.values.forEach { $0.yield(snapshot) }
            }
            let elapsed = started.duration(to: .now)
            let interval = profile.publicInterval
            if elapsed < interval {
                try? await Task.sleep(for: interval - elapsed)
            }
        }
    }

    private func collect(at now: ContinuousClock.Instant) async -> SystemSnapshot? {
        do {
            scheduleInventorySampleIfDue(at: now)
            scheduleStartupSampleIfDue(at: now)
            scheduleSMARTSampleIfDue(at: now)
            scheduleStorageSampleIfDue(at: now)
            scheduleDeepSampleIfDue(at: now)
            scheduleThermalSampleIfDue(at: now)
            scheduleSMCSampleIfDue(at: now)
            tick &+= 1

            async let cpuSample = cpu.sample()
            async let memorySample = memory.sample()
            async let batterySample = battery.sample()
            async let networkSample = network.sample()
            async let processSample = processes.sample()

            let (cpuValue, memoryValue, batteryValue, networkValue, processValue) = try await (
                cpuSample, memorySample, batterySample, networkSample, processSample
            )
            let timestamp = Date.now
            let metrics = makeMetrics(
                timestamp: timestamp,
                cpu: cpuValue,
                memory: memoryValue,
                network: networkValue
            )
            return SystemSnapshot(
                timestamp: timestamp,
                cpuUsage: cpuValue.total,
                cpuUser: cpuValue.user,
                cpuSystem: cpuValue.system,
                loadAverages: cpuValue.loadAverages,
                cores: cpuValue.cores,
                memory: memoryValue,
                battery: batteryValue,
                networks: networkValue,
                disks: cache.disks,
                processes: processValue,
                startupItems: cache.startup,
                startupRevision: cache.startupRevision,
                smartReports: cache.smart,
                inventory: cache.inventory,
                deep: cache.deep,
                metrics: metrics
            )
        } catch {
            return nil
        }
    }

    private func scheduleDeepSampleIfDue(at now: ContinuousClock.Instant) {
        guard deepTask == nil, cadence.shouldStart(.deep, at: now) else { return }
        let collector = deep
        deepTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishDeepSample(value)
        }
    }

    private func finishDeepSample(_ value: DeepTelemetrySnapshot?) {
        cache.updateDeep(value)
        deepTask = nil
    }

    private func scheduleThermalSampleIfDue(at now: ContinuousClock.Instant) {
        guard thermalTask == nil, cadence.shouldStart(.thermal, at: now) else { return }
        let collector = thermals
        thermalTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishThermalSample(value)
        }
    }

    private func finishThermalSample(_ value: [String: Double]?) {
        cache.updateThermals(value)
        thermalTask = nil
    }

    private func scheduleSMCSampleIfDue(at now: ContinuousClock.Instant) {
        guard smcTask == nil, cadence.shouldStart(.smc, at: now) else { return }
        let collector = smc
        smcTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishSMCSample(value)
        }
    }

    private func finishSMCSample(_ value: SMCSensorReadings?) {
        cache.updateSMC(value)
        smcTask = nil
    }

    private func scheduleStorageSampleIfDue(at now: ContinuousClock.Instant) {
        guard storageTask == nil, cadence.shouldStart(.storage, at: now) else { return }
        let collector = storage
        storageTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishStorageSample(value)
        }
    }

    private func finishStorageSample(_ value: [DiskSnapshot]?) {
        cache.updateDisks(value)
        storageTask = nil
    }

    private func scheduleStartupSampleIfDue(at now: ContinuousClock.Instant) {
        guard startupTask == nil, cadence.shouldStart(.startup, at: now) else { return }
        let collector = startup
        startupTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishStartupSample(value)
        }
    }

    private func finishStartupSample(_ value: [StartupItem]?) {
        cache.updateStartup(value)
        startupTask = nil
    }

    private func scheduleSMARTSampleIfDue(at now: ContinuousClock.Instant) {
        guard smartTask == nil, cadence.shouldStart(.smart, at: now) else { return }
        let collector = smart
        smartTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishSMARTSample(value)
        }
    }

    private func finishSMARTSample(_ value: [SMARTReport]?) {
        cache.updateSMART(value)
        smartTask = nil
    }

    private func scheduleInventorySampleIfDue(at now: ContinuousClock.Instant) {
        guard inventoryTask == nil, cadence.shouldStart(.inventory, at: now) else { return }
        let collector = inventory
        inventoryTask = Task { [weak self] in
            let value = try? await collector.sample()
            await self?.finishInventorySample(value)
        }
    }

    private func finishInventorySample(_ value: HardwareInventory?) {
        cache.updateInventory(value)
        inventoryTask = nil
    }

    private func makeMetrics(timestamp: Date, cpu: CPUSample, memory: MemorySnapshot, network: [NetworkInterfaceSnapshot]) -> [MetricSample] {
        let download = network.reduce(0) { $0 + $1.downloadRate }
        let upload = network.reduce(0) { $0 + $1.uploadRate }
        return [
            MetricSample(descriptorID: "cpu.total", timestamp: timestamp, value: .number(cpu.total)),
            MetricSample(descriptorID: "memory.used", timestamp: timestamp, value: .number(Double(memory.used))),
            MetricSample(descriptorID: "network.download", timestamp: timestamp, value: .number(download), quality: .derived),
            MetricSample(descriptorID: "network.upload", timestamp: timestamp, value: .number(upload), quality: .derived)
        ]
    }
}

public actor TelemetryHistory {
    private var storage: [SystemSnapshot] = []
    private let capacity: Int

    public init(capacity: Int = 3_600) {
        self.capacity = max(capacity, 1)
    }

    public func append(_ snapshot: SystemSnapshot) {
        storage.append(snapshot)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func snapshots() -> [SystemSnapshot] { storage }
}
