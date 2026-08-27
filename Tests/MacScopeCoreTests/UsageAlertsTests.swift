import Foundation
import Testing
@testable import MacScopeCore

@Suite("Usage alerts")
struct UsageAlertsTests {
    @Test("Defaults are opt-in and expose the documented thresholds")
    func defaultsAreDisabled() {
        let configuration = UsageAlertConfiguration.default
        let thresholds = Dictionary(uniqueKeysWithValues: configuration.rules.map { ($0.metric, $0.threshold) })

        #expect(configuration.enabled == false)
        #expect(configuration.sustainedDuration == .seconds(10))
        #expect(configuration.cooldown == .seconds(300))
        #expect(thresholds[.systemCPUPercent] == 90)
        #expect(thresholds[.systemRAMPercent] == 90)
        #expect(thresholds[.systemPowerWatts] == 60)
        #expect(thresholds[.processGroupCPUPercent] == 100)
        #expect(thresholds[.processGroupMemoryGiB] == 4)
    }

    @Test("A threshold must remain exceeded for the sustained duration")
    func sustainedDuration() {
        var evaluator = UsageAlertEvaluator()
        let configuration = testConfiguration(
            rule: UsageAlertRule(metric: .systemCPUPercent, threshold: 90, rearmThreshold: 80),
            sustainedDuration: .seconds(10)
        )
        let snapshot = testSnapshot(cpuUsage: 95, hasCPUReading: true)

        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(0)).isEmpty)
        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(9)).isEmpty)

        let events = evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(10))
        #expect(events.count == 1)
        #expect(events.first?.metric == .systemCPUPercent)
        #expect(events.first?.value == 95)
        #expect(events.first?.title == "High system CPU usage")
        #expect(events.first?.message.isEmpty == false)
    }

    @Test("A fired alert requires hysteresis rearm and respects cooldown")
    func cooldownAndRearm() {
        var evaluator = UsageAlertEvaluator()
        let configuration = testConfiguration(
            rule: UsageAlertRule(metric: .systemCPUPercent, threshold: 90, rearmThreshold: 80),
            sustainedDuration: .seconds(2),
            cooldown: .seconds(10)
        )
        let high = testSnapshot(cpuUsage: 95, hasCPUReading: true)
        let low = testSnapshot(cpuUsage: 75, hasCPUReading: true)

        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(0)).isEmpty)
        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(2)).count == 1)
        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(3)).isEmpty)
        #expect(evaluator.evaluate(snapshot: low, configuration: configuration, at: time(4)).isEmpty)
        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(5)).isEmpty)
        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(7)).isEmpty)
        #expect(evaluator.evaluate(snapshot: high, configuration: configuration, at: time(12)).count == 1)
    }

    @Test("Unavailable and invalid readings neither alert nor rearm a fired episode")
    func missingMetricsAreSkipped() {
        var evaluator = UsageAlertEvaluator()
        let rules = [
            UsageAlertRule(metric: .systemCPUPercent, threshold: 90),
            UsageAlertRule(metric: .systemRAMPercent, threshold: 90),
            UsageAlertRule(metric: .systemPowerWatts, threshold: 60),
            UsageAlertRule(metric: .processGroupCPUPercent, threshold: 100),
            UsageAlertRule(metric: .processGroupMemoryGiB, threshold: 4)
        ]
        let configuration = UsageAlertConfiguration(
            enabled: true,
            rules: rules,
            sustainedDuration: .zero,
            cooldown: .zero
        )
        let unidentifiedProcess = testProcess(
            pid: 100,
            parentPID: 1,
            name: "Unknown start",
            cpuPercent: 200,
            residentMemory: 8 * gibibyte,
            startedAt: nil
        )
        let snapshot = testSnapshot(
            cpuUsage: 99,
            hasCPUReading: false,
            memoryUsed: 100,
            memoryTotal: 0,
            systemPowerWatts: nil,
            processes: [unidentifiedProcess]
        )

        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(0)).isEmpty)
    }

    @Test("Grouped process alerts use the complete hierarchy aggregate")
    func processGroupAggregation() throws {
        var evaluator = UsageAlertEvaluator()
        let startedAt = time(100)
        let configuration = UsageAlertConfiguration(
            enabled: true,
            rules: [
                UsageAlertRule(metric: .processGroupCPUPercent, threshold: 100),
                UsageAlertRule(metric: .processGroupMemoryGiB, threshold: 4)
            ],
            sustainedDuration: .zero,
            cooldown: .zero
        )
        let snapshot = testSnapshot(processes: [
            testProcess(
                pid: 100,
                parentPID: 1,
                name: "Browser",
                cpuPercent: 80,
                residentMemory: 3 * gibibyte,
                startedAt: startedAt
            ),
            testProcess(
                pid: 101,
                parentPID: 100,
                name: "Renderer",
                cpuPercent: 30,
                residentMemory: 2 * gibibyte,
                startedAt: time(101)
            )
        ])

        let events = evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(0))
        let cpuEvent = try #require(events.first { $0.metric == .processGroupCPUPercent })
        let memoryEvent = try #require(events.first { $0.metric == .processGroupMemoryGiB })

        #expect(cpuEvent.value == 110)
        #expect(memoryEvent.value == 5)
        #expect(cpuEvent.subject == .processGroup(.init(
            pid: 100,
            startedAt: startedAt,
            name: "Browser",
            descendantCount: 1
        )))
    }

    @Test("PID reuse starts a new sustained-duration episode")
    func pidReuse() throws {
        var evaluator = UsageAlertEvaluator()
        let configuration = testConfiguration(
            rule: UsageAlertRule(metric: .processGroupCPUPercent, threshold: 100),
            sustainedDuration: .seconds(10),
            cooldown: .zero
        )
        let oldProcess = testProcess(
            pid: 100,
            parentPID: 1,
            name: "Worker",
            cpuPercent: 120,
            startedAt: time(100)
        )
        let replacement = testProcess(
            pid: 100,
            parentPID: 1,
            name: "Worker",
            cpuPercent: 120,
            startedAt: time(200)
        )

        #expect(evaluator.evaluate(
            snapshot: testSnapshot(processes: [oldProcess]),
            configuration: configuration,
            at: time(0)
        ).isEmpty)
        #expect(evaluator.evaluate(
            snapshot: testSnapshot(processes: [replacement]),
            configuration: configuration,
            at: time(5)
        ).isEmpty)
        #expect(evaluator.evaluate(
            snapshot: testSnapshot(processes: [replacement]),
            configuration: configuration,
            at: time(10)
        ).isEmpty)

        let event = try #require(evaluator.evaluate(
            snapshot: testSnapshot(processes: [replacement]),
            configuration: configuration,
            at: time(15)
        ).first)
        guard case .processGroup(let group) = event.subject else {
            Issue.record("Expected a process-group event")
            return
        }
        #expect(group.startedAt == time(200))
    }

    @Test("Backward timestamps reset a pending sustained-duration episode")
    func backwardTimestampResetsPendingState() {
        var evaluator = UsageAlertEvaluator()
        let configuration = testConfiguration(
            rule: UsageAlertRule(metric: .systemCPUPercent, threshold: 90),
            sustainedDuration: .seconds(10)
        )
        let snapshot = testSnapshot(cpuUsage: 95, hasCPUReading: true)

        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(10)).isEmpty)
        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(15)).isEmpty)
        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(12)).isEmpty)
        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(21)).isEmpty)
        #expect(evaluator.evaluate(snapshot: snapshot, configuration: configuration, at: time(22)).count == 1)
    }
}

private let gibibyte: UInt64 = 1_073_741_824

private func time(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func testConfiguration(
    rule: UsageAlertRule,
    sustainedDuration: Duration,
    cooldown: Duration = .seconds(300)
) -> UsageAlertConfiguration {
    UsageAlertConfiguration(
        enabled: true,
        rules: [rule],
        sustainedDuration: sustainedDuration,
        cooldown: cooldown
    )
}

private func testSnapshot(
    cpuUsage: Double = 0,
    hasCPUReading: Bool = false,
    memoryUsed: UInt64 = 0,
    memoryTotal: UInt64 = 0,
    systemPowerWatts: Double? = nil,
    processes: [ProcessSnapshot] = []
) -> SystemSnapshot {
    var memory = MemorySnapshot()
    memory.used = memoryUsed
    memory.total = memoryTotal
    var battery = BatterySnapshot()
    battery.systemPowerWatts = systemPowerWatts
    let cores = hasCPUReading
        ? [CPUCoreSnapshot(id: 0, usage: cpuUsage, user: cpuUsage, system: 0, idle: 100 - cpuUsage, cluster: "Test")]
        : []
    return SystemSnapshot(
        cpuUsage: cpuUsage,
        cores: cores,
        memory: memory,
        battery: battery,
        processes: processes
    )
}

private func testProcess(
    pid: Int32,
    parentPID: Int32,
    name: String,
    cpuPercent: Double,
    residentMemory: UInt64 = 0,
    startedAt: Date?
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
        virtualMemory: 0,
        threads: 1,
        bytesRead: 0,
        bytesWritten: 0,
        startedAt: startedAt
    )
}
