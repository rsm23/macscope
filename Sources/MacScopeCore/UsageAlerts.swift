import Foundation

/// Metrics that can produce a local usage alert.
public enum UsageAlertMetric: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case systemCPUPercent
    case systemRAMPercent
    case systemPowerWatts
    case processGroupCPUPercent
    case processGroupMemoryGiB

    public var id: Self { self }

    public var title: String {
        switch self {
        case .systemCPUPercent: "System CPU"
        case .systemRAMPercent: "System memory"
        case .systemPowerWatts: "System power"
        case .processGroupCPUPercent: "App group CPU"
        case .processGroupMemoryGiB: "App group memory"
        }
    }

    public var unit: String {
        switch self {
        case .systemCPUPercent, .systemRAMPercent, .processGroupCPUPercent: "%"
        case .systemPowerWatts: "W"
        case .processGroupMemoryGiB: "GiB"
        }
    }
}

/// One independently configurable usage threshold and its lower rearm point.
public struct UsageAlertRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UsageAlertMetric { metric }
    public let metric: UsageAlertMetric
    public let threshold: Double
    public let rearmThreshold: Double
    public let isEnabled: Bool

    public init(
        metric: UsageAlertMetric,
        threshold: Double,
        rearmThreshold: Double? = nil,
        isEnabled: Bool = true
    ) {
        self.metric = metric
        self.threshold = threshold
        self.rearmThreshold = rearmThreshold ?? threshold * 0.9
        self.isEnabled = isEnabled
    }
}

/// Alert evaluation is globally opt-in. Rules remain enabled in the default
/// configuration so switching the global toggle on has useful safe defaults.
public struct UsageAlertConfiguration: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let rules: [UsageAlertRule]
    public let sustainedDuration: Duration
    public let cooldown: Duration

    public init(
        enabled: Bool,
        rules: [UsageAlertRule],
        sustainedDuration: Duration = .seconds(10),
        cooldown: Duration = .seconds(5 * 60)
    ) {
        self.enabled = enabled
        self.rules = rules
        self.sustainedDuration = max(.zero, sustainedDuration)
        self.cooldown = max(.zero, cooldown)
    }

    public init(
        enabled: Bool,
        rules: [UsageAlertRule],
        sustainedDuration: TimeInterval,
        cooldown: TimeInterval
    ) {
        self.init(
            enabled: enabled,
            rules: rules,
            sustainedDuration: .seconds(sustainedDuration),
            cooldown: .seconds(cooldown)
        )
    }

    public static let `default` = UsageAlertConfiguration(
        enabled: false,
        rules: [
            UsageAlertRule(metric: .systemCPUPercent, threshold: 90),
            UsageAlertRule(metric: .systemRAMPercent, threshold: 90),
            UsageAlertRule(metric: .systemPowerWatts, threshold: 60),
            UsageAlertRule(metric: .processGroupCPUPercent, threshold: 100),
            UsageAlertRule(metric: .processGroupMemoryGiB, threshold: 4)
        ]
    )
}

/// A fully formatted, local-only alert ready for presentation by the app.
public struct UsageAlertEvent: Identifiable, Hashable, Sendable {
    public struct ProcessGroup: Hashable, Sendable {
        public let pid: Int32
        public let startedAt: Date
        public let name: String
        public let descendantCount: Int

        public init(pid: Int32, startedAt: Date, name: String, descendantCount: Int) {
            self.pid = pid
            self.startedAt = startedAt
            self.name = name
            self.descendantCount = descendantCount
        }
    }

    public enum Subject: Hashable, Sendable {
        case system
        case processGroup(ProcessGroup)
    }

    public struct ID: Hashable, Sendable {
        public let metric: UsageAlertMetric
        public let subject: Subject
        public let timestamp: Date
    }

    public var id: ID { ID(metric: metric, subject: subject, timestamp: timestamp) }
    public let metric: UsageAlertMetric
    public let subject: Subject
    public let value: Double
    public let threshold: Double
    public let timestamp: Date
    public let title: String
    public let message: String

    public init(
        metric: UsageAlertMetric,
        subject: Subject,
        value: Double,
        threshold: Double,
        timestamp: Date,
        title: String,
        message: String
    ) {
        self.metric = metric
        self.subject = subject
        self.value = value
        self.threshold = threshold
        self.timestamp = timestamp
        self.title = title
        self.message = message
    }
}

/// Pure state machine for sustained usage alerts. Callers provide the sample
/// timestamp, making duration, cooldown, and PID-reuse behavior deterministic.
public struct UsageAlertEvaluator: Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let pid: Int32
        let startedAt: Date
    }

    private enum StateSubject: Hashable, Sendable {
        case system
        case process(ProcessIdentity)
    }

    private struct StateKey: Hashable, Sendable {
        let metric: UsageAlertMetric
        let subject: StateSubject
    }

    private struct RuleState: Sendable {
        var aboveSince: Date?
        var lastObservedAt: Date?
        var lastEmittedAt: Date?
        var isArmed = true
    }

    private struct Candidate: Sendable {
        let stateSubject: StateSubject
        let eventSubject: UsageAlertEvent.Subject
        let value: Double?
    }

    private var states: [StateKey: RuleState] = [:]
    private var activeConfiguration: UsageAlertConfiguration?

    public init() {}

    public mutating func evaluate(
        snapshot: SystemSnapshot,
        configuration: UsageAlertConfiguration,
        at timestamp: Date? = nil
    ) -> [UsageAlertEvent] {
        let now = timestamp ?? snapshot.timestamp
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }

        guard configuration.enabled else {
            states.removeAll(keepingCapacity: true)
            activeConfiguration = configuration
            return []
        }

        if activeConfiguration != configuration {
            states.removeAll(keepingCapacity: true)
            activeConfiguration = configuration
        }

        var seenMetrics = Set<UsageAlertMetric>()
        let rules = configuration.rules.filter { rule in
            rule.isEnabled
                && rule.threshold.isFinite
                && rule.threshold > 0
                && rule.rearmThreshold.isFinite
                && rule.rearmThreshold >= 0
                && rule.rearmThreshold < rule.threshold
                && seenMetrics.insert(rule.metric).inserted
        }
        let enabledMetrics = Set(rules.map(\.metric))

        let needsProcessGroups = rules.contains {
            $0.metric == .processGroupCPUPercent || $0.metric == .processGroupMemoryGiB
        }
        let roots = needsProcessGroups ? ProcessHierarchy.build(from: snapshot.processes) : []
        let activeProcesses = Set(roots.compactMap { node -> ProcessIdentity? in
            guard let startedAt = node.process.startedAt else { return nil }
            return ProcessIdentity(pid: node.pid, startedAt: startedAt)
        })

        states = states.filter { key, _ in
            guard enabledMetrics.contains(key.metric) else { return false }
            switch key.subject {
            case .system:
                return true
            case .process(let identity):
                return activeProcesses.contains(identity)
            }
        }

        var events: [UsageAlertEvent] = []
        for rule in rules {
            for candidate in candidates(for: rule.metric, snapshot: snapshot, roots: roots) {
                if let event = observe(
                    candidate,
                    rule: rule,
                    configuration: configuration,
                    at: now
                ) {
                    events.append(event)
                }
            }
        }
        return events
    }

    private func candidates(
        for metric: UsageAlertMetric,
        snapshot: SystemSnapshot,
        roots: [ProcessTreeNode]
    ) -> [Candidate] {
        switch metric {
        case .systemCPUPercent:
            let value = snapshot.cores.isEmpty ? nil : validPercentage(snapshot.cpuUsage)
            return [Candidate(stateSubject: .system, eventSubject: .system, value: value)]
        case .systemRAMPercent:
            let value: Double?
            if snapshot.memory.total > 0, snapshot.memory.used <= snapshot.memory.total {
                value = Double(snapshot.memory.used) / Double(snapshot.memory.total) * 100
            } else {
                value = nil
            }
            return [Candidate(stateSubject: .system, eventSubject: .system, value: value)]
        case .systemPowerWatts:
            return [Candidate(
                stateSubject: .system,
                eventSubject: .system,
                value: validNonnegative(snapshot.battery.systemPowerWatts)
            )]
        case .processGroupCPUPercent, .processGroupMemoryGiB:
            return roots.compactMap { node in
                guard let startedAt = node.process.startedAt else { return nil }
                let identity = ProcessIdentity(pid: node.pid, startedAt: startedAt)
                let group = UsageAlertEvent.ProcessGroup(
                    pid: node.pid,
                    startedAt: startedAt,
                    name: node.name,
                    descendantCount: node.descendantCount
                )
                let value: Double?
                switch metric {
                case .processGroupCPUPercent:
                    value = validNonnegative(node.cpuPercent)
                case .processGroupMemoryGiB:
                    value = Double(node.residentMemory) / 1_073_741_824
                default:
                    value = nil
                }
                return Candidate(
                    stateSubject: .process(identity),
                    eventSubject: .processGroup(group),
                    value: value
                )
            }
        }
    }

    private mutating func observe(
        _ candidate: Candidate,
        rule: UsageAlertRule,
        configuration: UsageAlertConfiguration,
        at now: Date
    ) -> UsageAlertEvent? {
        let key = StateKey(metric: rule.metric, subject: candidate.stateSubject)
        var state = states[key] ?? RuleState()

        if let lastObservedAt = state.lastObservedAt, now < lastObservedAt {
            state.aboveSince = nil
        }
        state.lastObservedAt = now

        guard let value = candidate.value, value.isFinite else {
            // A gap breaks a pending continuous streak, but cannot rearm a
            // previously fired episode without a genuine below-threshold sample.
            state.aboveSince = nil
            states[key] = state
            return nil
        }

        if value <= rule.rearmThreshold {
            state.isArmed = true
            state.aboveSince = nil
            states[key] = state
            return nil
        }

        guard value >= rule.threshold else {
            state.aboveSince = nil
            states[key] = state
            return nil
        }

        guard state.isArmed else {
            states[key] = state
            return nil
        }

        if state.aboveSince == nil {
            state.aboveSince = now
        }
        let sustainedFor = now.timeIntervalSince(state.aboveSince ?? now)
        let cooldownElapsed = state.lastEmittedAt.map {
            now.timeIntervalSince($0) >= configuration.cooldown.timeInterval
        } ?? true
        guard sustainedFor >= configuration.sustainedDuration.timeInterval, cooldownElapsed else {
            states[key] = state
            return nil
        }

        state.isArmed = false
        state.lastEmittedAt = now
        states[key] = state
        return makeEvent(
            metric: rule.metric,
            subject: candidate.eventSubject,
            value: value,
            threshold: rule.threshold,
            timestamp: now
        )
    }

    private func validPercentage(_ value: Double) -> Double? {
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private func validNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func makeEvent(
        metric: UsageAlertMetric,
        subject: UsageAlertEvent.Subject,
        value: Double,
        threshold: Double,
        timestamp: Date
    ) -> UsageAlertEvent {
        let valueText = display(value, for: metric)
        let thresholdText = display(threshold, for: metric)
        let title: String
        let message: String
        switch (metric, subject) {
        case (.systemCPUPercent, .system):
            title = "High system CPU usage"
            message = "System CPU is at \(valueText), above the \(thresholdText) alert threshold."
        case (.systemRAMPercent, .system):
            title = "High system memory usage"
            message = "System memory is at \(valueText), above the \(thresholdText) alert threshold."
        case (.systemPowerWatts, .system):
            title = "High system power usage"
            message = "System power is at \(valueText), above the \(thresholdText) alert threshold."
        case (.processGroupCPUPercent, .processGroup(let group)):
            title = "High CPU usage: \(group.name)"
            message = groupMessage(
                group,
                valueText: valueText,
                thresholdText: thresholdText,
                resource: "CPU"
            )
        case (.processGroupMemoryGiB, .processGroup(let group)):
            title = "High memory usage: \(group.name)"
            message = groupMessage(
                group,
                valueText: valueText,
                thresholdText: thresholdText,
                resource: "memory"
            )
        default:
            title = "High \(metric.title.lowercased()) usage"
            message = "Usage is at \(valueText), above the \(thresholdText) alert threshold."
        }
        return UsageAlertEvent(
            metric: metric,
            subject: subject,
            value: value,
            threshold: threshold,
            timestamp: timestamp,
            title: title,
            message: message
        )
    }

    private func groupMessage(
        _ group: UsageAlertEvent.ProcessGroup,
        valueText: String,
        thresholdText: String,
        resource: String
    ) -> String {
        let childText = group.descendantCount == 1
            ? "1 child process"
            : "\(group.descendantCount) child processes"
        return "\(group.name) and its \(childText) use \(valueText) of \(resource), above the \(thresholdText) alert threshold."
    }

    private func display(_ value: Double, for metric: UsageAlertMetric) -> String {
        switch metric {
        case .systemCPUPercent, .systemRAMPercent, .processGroupCPUPercent:
            return String(format: "%.1f%%", value)
        case .systemPowerWatts:
            return String(format: "%.1f W", value)
        case .processGroupMemoryGiB:
            return String(format: "%.2f GiB", value)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
