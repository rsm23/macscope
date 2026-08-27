import Foundation
import Testing
@testable import MacScopeCore

@Test func keyValueParserHandlesDiskutilOutput() {
    let values = KeyValueTextParser.parse("""
       Device / Media Name: APPLE SSD
       SMART Status: Verified
       Protocol: Apple Fabric
       """)
    #expect(values["SMART Status"] == "Verified")
    #expect(values["Protocol"] == "Apple Fabric")
}

@Test func diskIOParserKeepsOnlyGenuineDocumentedCounters() throws {
    let counters = try #require(DiskIOCounters(statistics: [
        "Bytes (Read)": NSNumber(value: 1_024),
        "Bytes (Write)": NSNumber(value: 2_048),
        "Operations (Read)": NSNumber(value: 12),
        "Operations (Write)": NSNumber(value: 7),
        "Errors (Read)": NSNumber(value: 1),
        "Total Time (Read)": NSNumber(value: 9_000),
        "Latency Time (Read)": NSNumber(value: 3_000),
        "Unrelated Driver Field": NSNumber(value: 99)
    ]))

    #expect(counters.bytesRead == 1_024)
    #expect(counters.bytesWritten == 2_048)
    #expect(counters.readOperations == 12)
    #expect(counters.writeOperations == 7)
    #expect(counters.readErrors == 1)
    #expect(counters.writeErrors == nil)
    #expect(counters.totalReadTimeNanoseconds == 9_000)
    #expect(counters.totalReadLatencyNanoseconds == 3_000)
    #expect(DiskIOCounters(statistics: ["Unrelated Driver Field": 99]) == nil)
    #expect(DiskIOCounters(statistics: ["Bytes (Read)": -1]) == nil)
}

@Test func diskIOMetricsDeriveRatesAndIntervalLatency() throws {
    let previousCounters = try #require(DiskIOCounters(statistics: [
        "Bytes (Read)": 10_000,
        "Bytes (Write)": 20_000,
        "Operations (Read)": 100,
        "Operations (Write)": 50,
        "Errors (Read)": 1,
        "Errors (Write)": 2,
        "Retries (Read)": 2,
        "Retries (Write)": 3,
        "Total Time (Read)": 50_000_000,
        "Total Time (Write)": 60_000_000,
        "Latency Time (Read)": 30_000_000,
        "Latency Time (Write)": 40_000_000
    ]))
    let counters = try #require(DiskIOCounters(statistics: [
        "Bytes (Read)": 14_000,
        "Bytes (Write)": 26_000,
        "Operations (Read)": 110,
        "Operations (Write)": 54,
        "Errors (Read)": 1,
        "Errors (Write)": 2,
        "Retries (Read)": 4,
        "Retries (Write)": 3,
        "Total Time (Read)": 70_000_000,
        "Total Time (Write)": 68_000_000,
        "Latency Time (Read)": 40_000_000,
        "Latency Time (Write)": 46_000_000
    ]))
    let start = Date(timeIntervalSince1970: 100)
    let snapshot = DiskIOMetricDeriver.snapshot(
        counters: counters,
        previous: TimedDiskIOCounters(timestamp: start, counters: previousCounters),
        timestamp: start.addingTimeInterval(2),
        provenance: "fixture disk"
    )

    #expect(snapshot.availability == .available)
    #expect(snapshot.provenance == "fixture disk")
    #expect(snapshot.bytesRead == 14_000)
    #expect(snapshot.writeErrors == 2)
    #expect(snapshot.readBytesPerSecond == 2_000)
    #expect(snapshot.writeBytesPerSecond == 3_000)
    #expect(snapshot.readOperationsPerSecond == 5)
    #expect(snapshot.writeOperationsPerSecond == 2)
    #expect(snapshot.intervalDurationSeconds == 2)
    #expect(snapshot.bytesReadSinceLastSample == 4_000)
    #expect(snapshot.bytesWrittenSinceLastSample == 6_000)
    #expect(snapshot.readOperationsSinceLastSample == 10)
    #expect(snapshot.writeOperationsSinceLastSample == 4)
    #expect(snapshot.readErrorsSinceLastSample == 0)
    #expect(snapshot.writeErrorsSinceLastSample == 0)
    #expect(snapshot.readRetriesSinceLastSample == 2)
    #expect(snapshot.writeRetriesSinceLastSample == 0)
    #expect(snapshot.averageReadLatencyMilliseconds == 1)
    #expect(snapshot.averageWriteLatencyMilliseconds == 1.5)
    #expect(snapshot.averageReadServiceTimeMilliseconds == 2)
    #expect(snapshot.averageWriteServiceTimeMilliseconds == 2)
    #expect(snapshot.averageReadRequestBytes == 400)
    #expect(snapshot.averageWriteRequestBytes == 1_500)
    #expect(snapshot.totalBytesPerSecond == 5_000)
    #expect(snapshot.totalOperationsPerSecond == 7)
    #expect(snapshot.detail == nil)
}

@Test func physicalDiskActivityDoesNotMultiplySharedAPFSCounters() throws {
    let io = DiskIOSnapshot(
        availability: .available,
        provenance: "fixture",
        readBytesPerSecond: 8_000,
        writeBytesPerSecond: 4_000
    )
    let system = DiskSnapshot(
        name: "Macintosh HD",
        mountPoint: "/",
        fileSystem: "apfs",
        total: 1_000,
        available: 400,
        isReadOnly: false,
        deviceIdentifier: "system-volume",
        volumeBSDName: "disk3s1",
        physicalDeviceIdentifier: "disk0",
        physicalDeviceName: "APPLE SSD",
        io: io
    )
    let data = DiskSnapshot(
        name: "Macintosh HD - Data",
        mountPoint: "/System/Volumes/Data",
        fileSystem: "apfs",
        total: 1_000,
        available: 400,
        isReadOnly: false,
        deviceIdentifier: "data-volume",
        volumeBSDName: "disk3s5",
        physicalDeviceIdentifier: "disk0",
        physicalDeviceName: "APPLE SSD",
        io: io
    )
    let external = DiskSnapshot(
        name: "External",
        mountPoint: "/Volumes/External",
        fileSystem: "apfs",
        total: 2_000,
        available: 1_000,
        isReadOnly: false,
        deviceIdentifier: "external-volume",
        volumeBSDName: "disk5s1",
        physicalDeviceIdentifier: "disk5",
        physicalDeviceName: "External SSD",
        io: DiskIOSnapshot(availability: .available, provenance: "external")
    )

    let activity = PhysicalDiskActivityProjection.make(from: [data, external, system])

    #expect(activity.count == 2)
    let internalDisk = try #require(activity.first { $0.deviceIdentifier == "disk0" })
    #expect(internalDisk.name == "APPLE SSD")
    #expect(internalDisk.mountPoints == ["/", "/System/Volumes/Data"])
    #expect(internalDisk.io.totalBytesPerSecond == 12_000)
}

@Test func diskIOMetricsDoNotUnderflowWhenDriverCountersReset() throws {
    let previousCounters = try #require(DiskIOCounters(statistics: [
        "Bytes (Read)": 9_000,
        "Bytes (Write)": 8_000,
        "Operations (Read)": 90,
        "Operations (Write)": 80
    ]))
    let counters = try #require(DiskIOCounters(statistics: [
        "Bytes (Read)": 100,
        "Bytes (Write)": 200,
        "Operations (Read)": 1,
        "Operations (Write)": 2
    ]))
    let start = Date(timeIntervalSince1970: 100)
    let snapshot = DiskIOMetricDeriver.snapshot(
        counters: counters,
        previous: TimedDiskIOCounters(timestamp: start, counters: previousCounters),
        timestamp: start.addingTimeInterval(10),
        provenance: "reset fixture"
    )

    #expect(snapshot.bytesRead == 100)
    #expect(snapshot.readBytesPerSecond == nil)
    #expect(snapshot.writeBytesPerSecond == nil)
    #expect(snapshot.readOperationsPerSecond == nil)
    #expect(snapshot.detail?.contains("reset") == true)
}

@Test func diskCapacityBreakdownSeparatesFreeAndReclaimableSpace() {
    let disk = DiskSnapshot(
        name: "Fixture",
        mountPoint: "/fixture",
        fileSystem: "apfs",
        total: 1_000,
        available: 200,
        isReadOnly: false,
        deviceIdentifier: "fixture-volume-uuid",
        availableForImportantUsage: 350,
        availableForOpportunisticUsage: 250
    )

    #expect(disk.used == 800)
    #expect(disk.usageFraction == 0.8)
    #expect(disk.reclaimable == 150)
    #expect(disk.deviceIdentifier == "fixture-volume-uuid")
    #expect(disk.io == nil)
}

@Test func historyIsBounded() async {
    let history = TelemetryHistory(capacity: 2)
    await history.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 1)))
    await history.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 2)))
    await history.append(SystemSnapshot(timestamp: Date(timeIntervalSince1970: 3)))
    let snapshots = await history.snapshots()
    #expect(snapshots.map(\.timestamp) == [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 3)])
}

@Test func slowCollectorCadenceUsesElapsedTimeAcrossSamplingProfiles() {
    let origin = ContinuousClock.now

    func starts(for lane: TelemetryCadence.Lane, profile: SamplingProfile, ticks: Int) -> Int {
        var cadence = TelemetryCadence()
        return (0..<ticks).reduce(into: 0) { count, tick in
            let elapsed = profile.publicInterval * tick
            if cadence.shouldStart(lane, at: origin.advanced(by: elapsed)) {
                count += 1
            }
        }
    }

    // Over the first four seconds, both faster profiles sample the deep lane at 0, 2 and 4s.
    #expect(starts(for: .deep, profile: .maximum, ticks: 9) == 3)
    #expect(starts(for: .deep, profile: .balanced, ticks: 5) == 3)
    // Low-impact ticks arrive after the two-second deadline, so each available 5s tick is due.
    #expect(starts(for: .deep, profile: .lowImpact, ticks: 3) == 3)

    // Disk activity is live at one-second resolution. Maximum is intentionally
    // capped at 1 Hz, Balanced samples each tick, and Low Impact follows its
    // five-second public cadence.
    #expect(starts(for: .storage, profile: .maximum, ticks: 9) == 5)
    #expect(starts(for: .storage, profile: .balanced, ticks: 5) == 5)
    #expect(starts(for: .storage, profile: .lowImpact, ticks: 3) == 3)
}

@Test func slowCollectorCacheRetainsLastValidValuesAndMergesSensorSources() {
    var cache = RetainedTelemetryCache()
    let disk = DiskSnapshot(
        name: "Macintosh HD",
        mountPoint: "/",
        fileSystem: "apfs",
        total: 1_000,
        available: 400,
        isReadOnly: false
    )

    cache.updateDisks([disk])
    cache.updateDisks(nil)
    cache.updateDisks([])
    #expect(cache.disks == [disk])

    cache.updateThermals(["PMU die": 41])
    var smc = SMCSensorReadings()
    smc.temperatures = ["TC0P": 43]
    smc.fanSpeeds = ["F0Ac": 1_650]
    cache.updateSMC(smc)

    var helper = DeepTelemetrySnapshot(availability: .restricted)
    helper.gpuUsage = 35
    helper.sensors = ["Helper sensor": 39]
    cache.updateDeep(helper)

    #expect(cache.deep.gpuUsage == 35)
    #expect(cache.deep.sensors == ["Helper sensor": 39, "PMU die": 41, "TC0P": 43])
    #expect(cache.deep.fanSpeeds == ["F0Ac": 1_650])
    #expect(cache.deep.availability == .degraded)

    // A failed/empty follow-up must not blank the last usable sensor values.
    cache.updateDeep(nil)
    cache.updateThermals(nil)
    cache.updateSMC(nil)
    var helperWithoutSensors = DeepTelemetrySnapshot(availability: .available)
    helperWithoutSensors.gpuUsage = 50
    cache.updateDeep(helperWithoutSensors)

    #expect(cache.deep.gpuUsage == 50)
    #expect(cache.deep.sensors == ["Helper sensor": 39, "PMU die": 41, "TC0P": 43])
    #expect(cache.deep.fanSpeeds == ["F0Ac": 1_650])
}

@Test func processHistoryEncryptionRoundTrips() throws {
    let original = Data("sensitive process snapshot".utf8)
    let encrypted = try ProcessHistoryCipher.encrypt(original)
    #expect(encrypted != original)
    #expect(try ProcessHistoryCipher.decrypt(encrypted) == original)
}

@Test func metricCSVHasStableColumns() {
    let sample = MetricSample(descriptorID: "cpu.total", timestamp: Date(timeIntervalSince1970: 0), value: .number(42.5))
    let snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 0), metrics: [sample])
    let csv = String(data: TelemetryExporter.metricsCSV([snapshot]), encoding: .utf8)
    #expect(csv?.contains("timestamp,metric_id,value,quality,availability") == true)
    #expect(csv?.contains("cpu.total,42.5,measured,available") == true)
}

@Test func livePublicCollectorsReturnRealData() async throws {
    let cpu = CPUCollector()
    _ = try await cpu.sample()
    try await Task.sleep(for: .milliseconds(120))
    let cpuSample = try await cpu.sample()
    #expect(!cpuSample.cores.isEmpty)
    #expect(cpuSample.total >= 0 && cpuSample.total <= 100)

    let memory = try await MemoryCollector().sample()
    #expect(memory.total > 0)
    #expect(memory.used > 0)

    let processes = try await ProcessCollector().sample()
    #expect(processes.contains { $0.pid == getpid() })

    let inventory = try await InventoryCollector().sample()
    #expect(inventory.architecture == "arm64")
    #expect(inventory.processorCount > 0)
}

@Test func liveStorageCollectorMapsVolumeToPhysicalCounters() async throws {
    let collector = StorageCollector()
    let first = try await collector.sample()
    let root = try #require(first.first { $0.mountPoint == "/" })

    #expect(root.total > 0)
    #expect(root.deviceIdentifier?.isEmpty == false)
    #expect(root.volumeBSDName?.hasPrefix("disk") == true)
    let firstIO = try #require(root.io)
    #expect(firstIO.availability == .available)
    #expect(root.physicalDeviceIdentifier?.hasPrefix("disk") == true)
    #expect(root.physicalDeviceName?.isEmpty == false)
    #expect(firstIO.bytesRead != nil)
    #expect(firstIO.bytesWritten != nil)

    try await Task.sleep(for: .milliseconds(20))
    let second = try await collector.sample()
    let secondRoot = try #require(second.first { $0.mountPoint == "/" })
    #expect(secondRoot.io?.readBytesPerSecond != nil)
    #expect(secondRoot.io?.writeBytesPerSecond != nil)
    #expect(secondRoot.io?.readOperationsPerSecond != nil)
    #expect(secondRoot.io?.writeOperationsPerSecond != nil)
}

@Test func powermetricsParserFindsAcceleratorCounters() throws {
    let fixture: [String: Any] = [
        "GPU": ["active residency": 37.5, "frequency MHz": 800.0, "power mW": 4_200.0],
        "ANE": ["active residency": 12.0, "frequency MHz": 1_000.0, "power mW": 700.0],
        "CPU": ["frequency MHz": 2_900.0, "power mW": 9_500.0]
    ]
    var data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
    data.append(0)
    let value = try PowermetricsParser.parseStream(data)
    #expect(value.gpuUsage == 37.5)
    #expect(value.gpuPowerWatts == 4.2)
    #expect(value.aneUsage == 12)
    #expect(value.cpuFrequencyMHz == 2_900)
}

@Test func powermetricsParserTreatsBareAppleSiliconPowerKeysAsMilliwatts() throws {
    let fixture: [String: Any] = [
        "processor": ["cpu_power": 10_286.7],
        "graphics": ["gpu_power": 1_549.26],
        "neural": ["ane_power": 700.0]
    ]
    var data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
    data.append(0)

    let value = try PowermetricsParser.parseStream(data)

    #expect(abs((value.cpuPowerWatts ?? 0) - 10.2867) < 0.000_001)
    #expect(abs((value.gpuPowerWatts ?? 0) - 1.54926) < 0.000_001)
    #expect(abs((value.anePowerWatts ?? 0) - 0.7) < 0.000_001)
}

@Test func sqliteRollupsAcceptSamples() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try TelemetryDatabase(url: directory.appending(path: "test.sqlite"))
    let metric = MetricSample(descriptorID: "cpu.total", value: .number(55))
    try await database.record(SystemSnapshot(metrics: [metric]))
    #expect(FileManager.default.fileExists(atPath: await database.fileURL().path))
}

@Test func rawPreviewRemainsBoundedForLargeProcessLists() {
    let process = ProcessSnapshot(
        pid: 42,
        parentPID: 1,
        name: "A representative process with a readable name",
        executablePath: "/Applications/Representative.app/Contents/MacOS/Representative",
        userID: 501,
        state: "Running",
        cpuPercent: 12.5,
        residentMemory: 256_000_000,
        virtualMemory: 2_000_000_000,
        threads: 24,
        bytesRead: 5_000_000,
        bytesWritten: 2_000_000,
        startedAt: .now
    )
    let snapshot = SystemSnapshot(processes: Array(repeating: process, count: 2_000))
    let preview = RawSnapshotRenderer.previewJSON(snapshot)
    #expect(preview.utf8.count <= 128 * 1_024)
    #expect(preview.contains("Preview truncated"))
}

@Test func liveBatteryAndThermalCollectorsExposeAvailableHardware() async throws {
    let battery = try await BatteryCollector().sample()
    if battery.isPresent {
        #expect(battery.chargePercent != nil)
        #expect(battery.cycleCount != nil)
        #expect(battery.healthPercent != nil)
    }

    let temperatures = try await ThermalSensorCollector().sample()
    #expect(!temperatures.isEmpty)
    #expect(temperatures.values.allSatisfy { $0 > -20 && $0 < 160 })

    let smc = try await SMCSensorCollector().sample()
    #expect(smc.fanSpeeds.values.allSatisfy { $0 >= 0 && $0 < 30_000 })
}

@Test func smcDecoderReadsAppleSiliconFanFloatAsLittleEndian() throws {
    // 1200.0f has bit pattern 0x44960000 and AppleSMC returns the bytes in this order.
    let value = try #require(SMCDecoder.decode([0x00, 0x00, 0x96, 0x44], type: "flt "))
    #expect(value == 1_200)
}

@Test func smcDecoderKeepsIntelFanFixedPointBigEndian() throws {
    // fpe2 stores RPM multiplied by four, so 0x19C8 represents 1650 RPM.
    let value = try #require(SMCDecoder.decode([0x19, 0xC8], type: "fpe2"))
    #expect(value == 1_650)
}

@Test func smcFanCatalogProbesEveryValidCurrentSpeedIdentifier() {
    #expect(SMCKeyCatalog.fanSpeedKeys.first == "F0Ac")
    #expect(SMCKeyCatalog.fanSpeedKeys.last == "F9Ac")
    #expect(SMCKeyCatalog.fanSpeedKeys.allSatisfy { $0.utf8.count == 4 })
}

@Test func smcRequestMatchesAppleSMCCStructABI() {
    #expect(SMCABI.requestSize == 80)
}

@Test func diskBenchmarkUsesAndRemovesItsTemporaryFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = try await BenchmarkRunner.disk(at: directory, size: 4 * 1_024 * 1_024)
    #expect(result.bytesTested == 4 * 1_024 * 1_024)
    #expect(result.writeMegabytesPerSecond > 0)
    #expect(result.readMegabytesPerSecond > 0)
    #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
}

@Test func diskBenchmarkReportsMeasuredLiveProgressForBothPasses() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = BenchmarkProgressRecorder()

    _ = try await BenchmarkRunner.disk(at: directory, size: 8 * 1_024 * 1_024) { progress in
        recorder.record(progress)
    }

    let reports = recorder.values
    #expect(reports.contains { $0.phase == .diskWrite && $0.bytesPerSecond > 0 })
    #expect(reports.contains { $0.phase == .diskRead && $0.bytesPerSecond > 0 })
    #expect(reports.filter { $0.phase == .diskWrite }.last?.fractionCompleted == 1)
    #expect(reports.filter { $0.phase == .diskRead }.last?.fractionCompleted == 1)
}

@Test func diskBenchmarkUsesSameVolumeFallbackForProtectedMountPath() async throws {
    let result = try await BenchmarkRunner.disk(at: URL(fileURLWithPath: "/System", isDirectory: true), size: 4 * 1_024 * 1_024)
    #expect(result.bytesTested == 4 * 1_024 * 1_024)
    #expect(result.writeMegabytesPerSecond > 0)
    #expect(result.readMegabytesPerSecond > 0)
}

@Test func deepTelemetryDecodesOlderHelperPayloads() throws {
    let payload = Data(#"{"gpuUsage":42,"sensors":{},"availability":"available"}"#.utf8)
    let snapshot = try JSONDecoder().decode(DeepTelemetrySnapshot.self, from: payload)
    #expect(snapshot.gpuUsage == 42)
    #expect(snapshot.fanSpeeds.isEmpty)
}

@Test func legacyHelperPowerFieldsAreConvertedFromMilliwattsAtTheXPCBoundary() {
    var snapshot = DeepTelemetrySnapshot(availability: .available)
    snapshot.cpuPowerWatts = 10_286.7
    snapshot.gpuPowerWatts = 1_549.26
    snapshot.anePowerWatts = 700

    let normalized = PrivilegedTelemetryCompatibility.normalizePowerUnits(
        in: snapshot,
        fromProtocolVersion: 1
    )

    #expect(abs((normalized.cpuPowerWatts ?? 0) - 10.2867) < 0.000_001)
    #expect(abs((normalized.gpuPowerWatts ?? 0) - 1.54926) < 0.000_001)
    #expect(abs((normalized.anePowerWatts ?? 0) - 0.7) < 0.000_001)
}

@Test func currentHelperPowerFieldsAreNeverNormalizedTwice() {
    var snapshot = DeepTelemetrySnapshot(availability: .available)
    snapshot.cpuPowerWatts = 10.2867
    snapshot.gpuPowerWatts = 1.54926
    snapshot.anePowerWatts = 0.7

    let normalized = PrivilegedTelemetryCompatibility.normalizePowerUnits(
        in: snapshot,
        fromProtocolVersion: PrivilegedTelemetryProtocolVersion.current
    )

    #expect(normalized.cpuPowerWatts == snapshot.cpuPowerWatts)
    #expect(normalized.gpuPowerWatts == snapshot.gpuPowerWatts)
    #expect(normalized.anePowerWatts == snapshot.anePowerWatts)
}

@Test func helperTelemetryProtocolSupportIsNarrowAndVersioned() {
    #expect(!PrivilegedTelemetryCompatibility.supports(0))
    #expect(PrivilegedTelemetryCompatibility.supports(1))
    #expect(PrivilegedTelemetryCompatibility.supports(2))
    #expect(!PrivilegedTelemetryCompatibility.supports(3))
}

@Test func processHierarchyGroupsDescendantsWithoutHidingEverythingUnderLaunchd() {
    let processes = [
        testProcess(pid: 1, parentPID: 0, name: "launchd"),
        testProcess(pid: 100, parentPID: 1, name: "MacScope"),
        testProcess(pid: 101, parentPID: 100, name: "Renderer"),
        testProcess(pid: 102, parentPID: 101, name: "Worker"),
        testProcess(pid: 200, parentPID: 1, name: "Other")
    ]

    let roots = ProcessHierarchy.build(from: processes)
    let app = roots.first { $0.pid == 100 }

    #expect(Set(roots.map(\.pid)) == [1, 100, 200])
    #expect(app?.children?.first?.pid == 101)
    #expect(app?.children?.first?.children?.first?.pid == 102)
    #expect(app?.descendantCount == 2)
    #expect(roots.first { $0.pid == 1 }?.children == nil)
}

@Test func processHierarchyGroupMetricsIncludeNestedDescendants() {
    let roots = ProcessHierarchy.build(from: [
        testProcess(pid: 100, parentPID: 1, name: "Parent", cpuPercent: 12.5, residentMemory: 1_000),
        testProcess(pid: 101, parentPID: 100, name: "Child", cpuPercent: 7.5, residentMemory: 2_000),
        testProcess(pid: 102, parentPID: 101, name: "Grandchild", cpuPercent: 5, residentMemory: 4_000)
    ])

    let group = roots.first { $0.pid == 100 }
    let childGroup = group?.children?.first

    #expect(group?.cpuPercent == 25)
    #expect(group?.residentMemory == 7_000)
    #expect(childGroup?.cpuPercent == 12.5)
    #expect(childGroup?.residentMemory == 6_000)
}

@Test func processHierarchyGroupMemorySaturatesOnOverflow() {
    let roots = ProcessHierarchy.build(from: [
        testProcess(
            pid: 100,
            parentPID: 1,
            name: "Parent",
            residentMemory: UInt64.max - 1
        ),
        testProcess(pid: 101, parentPID: 100, name: "Child", residentMemory: 2)
    ])

    #expect(roots.first?.residentMemory == UInt64.max)
}

@Test func processHierarchyFilteringPreservesTheMatchingChildsParentChain() {
    let processes = [
        testProcess(pid: 100, parentPID: 1, name: "MacScope"),
        testProcess(pid: 101, parentPID: 100, name: "Renderer"),
        testProcess(pid: 102, parentPID: 101, name: "Worker"),
        testProcess(pid: 200, parentPID: 1, name: "Other")
    ]

    let roots = ProcessHierarchy.build(from: processes, matching: "worker")

    #expect(roots.map(\.pid) == [100])
    #expect(roots.first?.children?.first?.pid == 101)
    #expect(roots.first?.children?.first?.children?.first?.pid == 102)
}

@Test func processHierarchyKeepsMalformedCyclesVisibleOnce() {
    let roots = ProcessHierarchy.build(from: [
        testProcess(pid: 300, parentPID: 301, name: "Cycle A"),
        testProcess(pid: 301, parentPID: 300, name: "Cycle B")
    ])

    #expect(roots.reduce(0) { $0 + 1 + $1.descendantCount } == 2)
}

@Test func processHierarchyStableRanksKeepLiveRowsInPlace() {
    let initial = ProcessHierarchy.build(from: [
        testProcess(pid: 100, parentPID: 1, name: "First", cpuPercent: 80),
        testProcess(pid: 200, parentPID: 1, name: "Second", cpuPercent: 20),
        testProcess(pid: 201, parentPID: 200, name: "Child", cpuPercent: 10)
    ])
    let ranks = ProcessHierarchy.stableRanks(for: initial)

    let refreshed = ProcessHierarchy.build(from: [
        testProcess(pid: 200, parentPID: 1, name: "Second", cpuPercent: 95),
        testProcess(pid: 201, parentPID: 200, name: "Child", cpuPercent: 90),
        testProcess(pid: 100, parentPID: 1, name: "First", cpuPercent: 1),
        testProcess(pid: 300, parentPID: 1, name: "New", cpuPercent: 100)
    ])
    let reorderedInput = refreshed.sorted { $0.process.cpuPercent > $1.process.cpuPercent }
    let locked = ProcessHierarchy.applyingStableOrder(to: reorderedInput, ranks: ranks)

    #expect(locked.map(\.pid) == [100, 200, 300])
    #expect(locked.first { $0.pid == 200 }?.children?.map(\.pid) == [201])
    #expect(locked.first { $0.pid == 200 }?.process.cpuPercent == 95)
}

private func testProcess(
    pid: Int32,
    parentPID: Int32,
    name: String,
    cpuPercent: Double = 1,
    residentMemory: UInt64 = 1_024
) -> ProcessSnapshot {
    ProcessSnapshot(
        pid: pid,
        parentPID: parentPID,
        name: name,
        executablePath: "/usr/bin/\(name)",
        userID: 501,
        state: "Running",
        cpuPercent: cpuPercent,
        residentMemory: residentMemory,
        virtualMemory: 2_048,
        threads: 1,
        bytesRead: 0,
        bytesWritten: 0,
        startedAt: .now
    )
}

private final class BenchmarkProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BenchmarkProgress] = []

    func record(_ progress: BenchmarkProgress) {
        lock.withLock { storage.append(progress) }
    }

    var values: [BenchmarkProgress] {
        lock.withLock { storage }
    }
}
