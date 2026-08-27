import MacScopeCore
import SwiftUI

struct StorageLiveActivityOverview: View {
    let disks: [DiskSnapshot]
    let history: [SystemSnapshot]

    private var devices: [PhysicalDiskActivity] {
        PhysicalDiskActivityProjection.make(from: disks)
    }

    private var liveDevices: [PhysicalDiskActivity] {
        devices.filter { $0.io.availability == .available }
    }

    private var hasLiveCounters: Bool {
        liveDevices.contains {
            $0.io.readBytesPerSecond != nil
                || $0.io.writeBytesPerSecond != nil
                || $0.io.readOperationsPerSecond != nil
                || $0.io.writeOperationsPerSecond != nil
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                header
                if hasLiveCounters {
                    metrics
                    throughputChart
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            operationsChart
                            latencyChart
                        }
                        VStack(spacing: 12) {
                            operationsChart
                            latencyChart
                        }
                    }
                    deviceList
                } else {
                    ContentUnavailableView(
                        "Live disk counters unavailable",
                        systemImage: "internaldrive.fill",
                        description: Text(unavailableDetail)
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.12))
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(MacScopeTheme.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Live disk activity")
                        .font(.headline)
                    Circle()
                        .fill(hasLiveCounters ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text("Unique physical devices • 1-second IOKit driver deltas in Balanced and Maximum profiles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if let sampledAt = liveDevices.compactMap(\.io.sampledAt).max() {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last sample")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(sampledAt.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 10)], spacing: 10) {
            StorageLiveMetricTile(
                title: "Read now",
                value: formattedRate(total(\.readBytesPerSecond)),
                subtitle: formattedIntervalBytes(read: true),
                icon: "arrow.down.circle.fill",
                tint: MacScopeTheme.cyan,
                points: aggregatePoints(\.readBytesPerSecond, divisor: 1_048_576)
            )
            StorageLiveMetricTile(
                title: "Write now",
                value: formattedRate(total(\.writeBytesPerSecond)),
                subtitle: formattedIntervalBytes(read: false),
                icon: "arrow.up.circle.fill",
                tint: MacScopeTheme.accent,
                points: aggregatePoints(\.writeBytesPerSecond, divisor: 1_048_576)
            )
            StorageLiveMetricTile(
                title: "Read IOPS",
                value: formattedOperations(total(\.readOperationsPerSecond)),
                subtitle: formattedIntervalOperations(read: true),
                icon: "arrow.down.right.circle.fill",
                tint: MacScopeTheme.cyan,
                points: aggregatePoints(\.readOperationsPerSecond)
            )
            StorageLiveMetricTile(
                title: "Write IOPS",
                value: formattedOperations(total(\.writeOperationsPerSecond)),
                subtitle: formattedIntervalOperations(read: false),
                icon: "arrow.up.right.circle.fill",
                tint: MacScopeTheme.accent,
                points: aggregatePoints(\.writeOperationsPerSecond)
            )
            StorageLiveMetricTile(
                title: "Read latency",
                value: formattedLatency(weightedAverage(\.averageReadLatencyMilliseconds, weight: \.readOperationsPerSecond)),
                subtitle: "Operation-weighted average",
                icon: "timer",
                tint: MacScopeTheme.cyan,
                points: aggregateWeightedPoints(\.averageReadLatencyMilliseconds, weight: \.readOperationsPerSecond)
            )
            StorageLiveMetricTile(
                title: "Write latency",
                value: formattedLatency(weightedAverage(\.averageWriteLatencyMilliseconds, weight: \.writeOperationsPerSecond)),
                subtitle: "Operation-weighted average",
                icon: "timer",
                tint: MacScopeTheme.accent,
                points: aggregateWeightedPoints(\.averageWriteLatencyMilliseconds, weight: \.writeOperationsPerSecond)
            )
        }
    }

    private var throughputChart: some View {
        StorageInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Read and write throughput", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                MetricTrendChart(
                    series: [
                        MetricSeries(
                            id: "all-disks-read",
                            title: "Read",
                            unit: "MiB/s",
                            tint: MacScopeTheme.cyan,
                            points: aggregatePoints(\.readBytesPerSecond, divisor: 1_048_576),
                            interpolation: .stepEnd
                        ),
                        MetricSeries(
                            id: "all-disks-write",
                            title: "Write",
                            unit: "MiB/s",
                            tint: MacScopeTheme.accent,
                            points: aggregatePoints(\.writeBytesPerSecond, divisor: 1_048_576),
                            interpolation: .stepEnd
                        )
                    ],
                    unit: "MiB/s",
                    includesZero: true,
                    height: 190,
                    showsLegend: true
                )
            }
        }
    }

    private var operationsChart: some View {
        StorageInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Operations per second", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                MetricTrendChart(
                    series: [
                        MetricSeries(
                            id: "all-disks-read-iops",
                            title: "Read",
                            unit: "ops/s",
                            tint: MacScopeTheme.cyan,
                            points: aggregatePoints(\.readOperationsPerSecond),
                            interpolation: .stepEnd
                        ),
                        MetricSeries(
                            id: "all-disks-write-iops",
                            title: "Write",
                            unit: "ops/s",
                            tint: MacScopeTheme.accent,
                            points: aggregatePoints(\.writeOperationsPerSecond),
                            interpolation: .stepEnd
                        )
                    ],
                    unit: "ops/s",
                    includesZero: true,
                    height: 148,
                    showsLegend: true
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var latencyChart: some View {
        StorageInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Average operation latency", systemImage: "timer")
                    .font(.subheadline.weight(.semibold))
                MetricTrendChart(
                    series: [
                        MetricSeries(
                            id: "all-disks-read-latency",
                            title: "Read",
                            unit: "ms",
                            tint: MacScopeTheme.cyan,
                            points: aggregateWeightedPoints(\.averageReadLatencyMilliseconds, weight: \.readOperationsPerSecond),
                            interpolation: .stepEnd
                        ),
                        MetricSeries(
                            id: "all-disks-write-latency",
                            title: "Write",
                            unit: "ms",
                            tint: MacScopeTheme.accent,
                            points: aggregateWeightedPoints(\.averageWriteLatencyMilliseconds, weight: \.writeOperationsPerSecond),
                            interpolation: .stepEnd
                        )
                    ],
                    unit: "ms",
                    includesZero: true,
                    height: 148,
                    showsLegend: true
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical devices")
                .font(.subheadline.weight(.semibold))
            ForEach(devices) { device in
                StoragePhysicalActivityRow(device: device)
            }
        }
    }

    private var unavailableDetail: String {
        devices.first?.io.detail
            ?? "No mounted volume currently maps to documented IOBlockStorageDriver statistics."
    }

    private func total(_ keyPath: KeyPath<DiskIOSnapshot, Double?>) -> Double? {
        let values = liveDevices.compactMap { $0.io[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private func totalInterval(_ keyPath: KeyPath<DiskIOSnapshot, UInt64?>) -> UInt64? {
        let values = liveDevices.compactMap { $0.io[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, &+)
    }

    private func weightedAverage(
        _ value: KeyPath<DiskIOSnapshot, Double?>,
        weight: KeyPath<DiskIOSnapshot, Double?>
    ) -> Double? {
        weightedAverage(in: liveDevices, value: value, weight: weight)
    }

    private func weightedAverage(
        in devices: [PhysicalDiskActivity],
        value: KeyPath<DiskIOSnapshot, Double?>,
        weight: KeyPath<DiskIOSnapshot, Double?>
    ) -> Double? {
        let pairs = devices.compactMap { device -> (Double, Double)? in
            guard let value = device.io[keyPath: value], value.isFinite,
                  let weight = device.io[keyPath: weight], weight.isFinite, weight > 0 else { return nil }
            return (value, weight)
        }
        let totalWeight = pairs.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        return pairs.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
    }

    private func aggregatePoints(
        _ keyPath: KeyPath<DiskIOSnapshot, Double?>,
        divisor: Double = 1
    ) -> [MetricPoint] {
        Array(history.suffix(120)).enumerated().map { ordinal, snapshot in
            let devices = PhysicalDiskActivityProjection.make(from: snapshot.disks)
            let values = devices.compactMap { $0.io[keyPath: keyPath] }
            return MetricPoint(
                timestamp: snapshot.timestamp,
                value: values.isEmpty ? nil : values.reduce(0, +) / divisor,
                ordinal: ordinal
            )
        }
    }

    private func aggregateWeightedPoints(
        _ value: KeyPath<DiskIOSnapshot, Double?>,
        weight: KeyPath<DiskIOSnapshot, Double?>
    ) -> [MetricPoint] {
        Array(history.suffix(120)).enumerated().map { ordinal, snapshot in
            let devices = PhysicalDiskActivityProjection.make(from: snapshot.disks)
            return MetricPoint(
                timestamp: snapshot.timestamp,
                value: weightedAverage(in: devices, value: value, weight: weight),
                ordinal: ordinal
            )
        }
    }

    private func formattedRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(ByteCountFormatter.macScope(UInt64(max(value, 0))))/s"
    }

    private func formattedOperations(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) ops/s"
    }

    private func formattedLatency(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) ms"
    }

    private func formattedIntervalBytes(read: Bool) -> String {
        let bytes = totalInterval(read ? \.bytesReadSinceLastSample : \.bytesWrittenSinceLastSample)
        return bytes.map { "\(ByteCountFormatter.macScope($0)) in latest sample" } ?? "Waiting for the next sample"
    }

    private func formattedIntervalOperations(read: Bool) -> String {
        let operations = totalInterval(read ? \.readOperationsSinceLastSample : \.writeOperationsSinceLastSample)
        return operations.map { "\($0.formatted()) in latest sample" } ?? "Waiting for the next sample"
    }
}

private struct StorageLiveMetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color
    let points: [MetricPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            MetricSparkline(
                points: points,
                tint: tint,
                includesZero: true,
                height: 30,
                accessibilityLabel: "\(title) history"
            )
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(subtitle)")
    }
}

private struct StoragePhysicalActivityRow: View {
    let device: PhysicalDiskActivity

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                identity
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric("Read", value: formattedRate(device.io.readBytesPerSecond), icon: "arrow.down", tint: MacScopeTheme.cyan)
                metric("Write", value: formattedRate(device.io.writeBytesPerSecond), icon: "arrow.up", tint: MacScopeTheme.accent)
                metric("IOPS", value: formattedOperations(device.io.totalOperationsPerSecond), icon: "bolt.horizontal", tint: .mint)
                metric("Latency", value: formattedCombinedLatency, icon: "timer", tint: .orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                HStack(spacing: 10) {
                    metric("Read", value: formattedRate(device.io.readBytesPerSecond), icon: "arrow.down", tint: MacScopeTheme.cyan)
                    metric("Write", value: formattedRate(device.io.writeBytesPerSecond), icon: "arrow.up", tint: MacScopeTheme.accent)
                    metric("IOPS", value: formattedOperations(device.io.totalOperationsPerSecond), icon: "bolt.horizontal", tint: .mint)
                    metric("Latency", value: formattedCombinedLatency, icon: "timer", tint: .orange)
                }
            }
        }
        .padding(11)
        .background(.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.1))
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(MacScopeTheme.accent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(deviceSubtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(device.mountPoints.joined(separator: " • "))
            }
        }
    }

    private func metric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 88, alignment: .leading)
    }

    private var deviceSubtitle: String {
        let identifier = device.deviceIdentifier ?? "Unmapped"
        return "\(identifier) • \(device.volumeNames.count) volume\(device.volumeNames.count == 1 ? "" : "s")"
    }

    private var formattedCombinedLatency: String {
        let values = [device.io.averageReadLatencyMilliseconds, device.io.averageWriteLatencyMilliseconds].compactMap { $0 }
        guard !values.isEmpty else { return "Unavailable" }
        let average = values.reduce(0, +) / Double(values.count)
        return "\(average.formatted(.number.precision(.fractionLength(0...2)))) ms"
    }

    private func formattedRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(ByteCountFormatter.macScope(UInt64(max(value, 0))))/s"
    }

    private func formattedOperations(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct StorageDiskDetailCard: View {
    let disk: DiskSnapshot
    let history: [SystemSnapshot]
    let canBenchmark: Bool
    let benchmark: () -> Void

    @State private var isExpanded = false

    private var capacityAvailability: DataAvailability {
        disk.total > 0 ? .available : .degraded
    }

    private var ioAvailability: DataAvailability {
        disk.io?.availability ?? .unsupported
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary

                if isExpanded {
                    Divider().opacity(0.55)
                    expandedDetails
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(capacityTint.opacity(0.13))
                Image(systemName: disk.isReadOnly ? "externaldrive.badge.lock" : "internaldrive.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(capacityTint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(disk.name.isEmpty ? disk.mountPoint : disk.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(disk.fileSystem.uppercased())
                    Text("•")
                    Text(disk.mountPoint)
                    if let physicalDeviceLabel {
                        Text("•")
                        Text(physicalDeviceLabel)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(identityHelp)
            }

            Spacer()
            AvailabilityBadge(availability: capacityAvailability)
            Button("Benchmark", systemImage: "speedometer", action: benchmark)
                .macScopeGlassButton()
                .disabled(!canBenchmark)
                .help(canBenchmark ? "Run a temporary-file benchmark on this volume" : "Benchmarking requires a writable volume and no other benchmark in progress")
            Button {
                withAnimation(.smooth(duration: 0.24)) {
                    isExpanded.toggle()
                }
            } label: {
                Label(isExpanded ? "Hide Details" : "Show Details", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macScopeGlassControl()
            .help(isExpanded ? "Hide per-disk details" : "Show usage, activity graphs, and driver counters")
            .accessibilityLabel(isExpanded ? "Hide details for \(disk.name)" : "Show details for \(disk.name)")
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 14) {
            MetricRing(
                title: "Capacity used",
                value: disk.total > 0 ? disk.usageFraction.formatted(.percent.precision(.fractionLength(0))) : "Unavailable",
                unit: "",
                fraction: disk.total > 0 ? disk.usageFraction : nil,
                tint: capacityTint,
                icon: "chart.pie.fill",
                availability: capacityAvailability,
                diameter: 82
            )
            .frame(width: 148)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Usage breakdown", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteCountFormatter.macScope(disk.total))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                MetricDistributionBar(segments: capacitySegments, height: 12, showsLegend: true)
                HStack(spacing: 12) {
                    Label(disk.isReadOnly ? "Read-only" : "Writable", systemImage: disk.isReadOnly ? "lock.fill" : "lock.open")
                    if let volumeBSDName = disk.volumeBSDName {
                        Label(volumeBSDName, systemImage: "shippingbox")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)

            HStack(spacing: 10) {
                StorageActivityMiniCard(
                    title: "Read now",
                    value: formattedRate(disk.io?.readBytesPerSecond),
                    icon: "arrow.down",
                    tint: MacScopeTheme.cyan,
                    points: readRatePoints,
                    availability: ioAvailability
                )
                StorageActivityMiniCard(
                    title: "Write now",
                    value: formattedRate(disk.io?.writeBytesPerSecond),
                    icon: "arrow.up",
                    tint: MacScopeTheme.accent,
                    points: writeRatePoints,
                    availability: ioAvailability
                )
            }
            .frame(maxWidth: 360)
        }
        .frame(minHeight: 154, alignment: .top)
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            StorageInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Physical-device activity", systemImage: "waveform.path.ecg.rectangle")
                                .font(.headline)
                            Text(activitySubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        AvailabilityBadge(availability: ioAvailability)
                    }
                    MetricTrendChart(
                        series: activitySeries,
                        unit: "MiB/s",
                        includesZero: true,
                        height: 184,
                        showsLegend: true
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    operationsPanel
                    latencyPanel
                }
                VStack(spacing: 12) {
                    operationsPanel
                    latencyPanel
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 10)], spacing: 10) {
                StorageCounterTile(
                    title: "Latest read",
                    value: formattedBytes(disk.io?.bytesReadSinceLastSample),
                    subtitle: sampleIntervalLabel,
                    icon: "arrow.down.circle",
                    tint: MacScopeTheme.cyan,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Latest write",
                    value: formattedBytes(disk.io?.bytesWrittenSinceLastSample),
                    subtitle: sampleIntervalLabel,
                    icon: "arrow.up.circle",
                    tint: MacScopeTheme.accent,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Read IOPS",
                    value: formattedOperationsRate(disk.io?.readOperationsPerSecond),
                    subtitle: formattedIntervalCount(disk.io?.readOperationsSinceLastSample),
                    icon: "arrow.down.right.circle",
                    tint: MacScopeTheme.cyan,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Write IOPS",
                    value: formattedOperationsRate(disk.io?.writeOperationsPerSecond),
                    subtitle: formattedIntervalCount(disk.io?.writeOperationsSinceLastSample),
                    icon: "arrow.up.right.circle",
                    tint: MacScopeTheme.accent,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Read request",
                    value: formattedAverageBytes(disk.io?.averageReadRequestBytes),
                    subtitle: "Average size this interval",
                    icon: "arrow.down.square",
                    tint: MacScopeTheme.cyan,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Write request",
                    value: formattedAverageBytes(disk.io?.averageWriteRequestBytes),
                    subtitle: "Average size this interval",
                    icon: "arrow.up.square",
                    tint: MacScopeTheme.accent,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Read service time",
                    value: formattedLatency(disk.io?.averageReadServiceTimeMilliseconds),
                    subtitle: "Average performing a read",
                    icon: "gauge.with.dots.needle.33percent",
                    tint: MacScopeTheme.cyan,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Write service time",
                    value: formattedLatency(disk.io?.averageWriteServiceTimeMilliseconds),
                    subtitle: "Average performing a write",
                    icon: "gauge.with.dots.needle.67percent",
                    tint: MacScopeTheme.accent,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Read latency",
                    value: formattedLatency(disk.io?.averageReadLatencyMilliseconds),
                    subtitle: "Driver latency this interval",
                    icon: "timer",
                    tint: MacScopeTheme.cyan,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "Write latency",
                    value: formattedLatency(disk.io?.averageWriteLatencyMilliseconds),
                    subtitle: "Driver latency this interval",
                    icon: "timer",
                    tint: MacScopeTheme.accent,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "New I/O errors",
                    value: formattedPair(
                        read: disk.io?.readErrorsSinceLastSample,
                        write: disk.io?.writeErrorsSinceLastSample
                    ),
                    subtitle: "Read / write in latest sample",
                    icon: "exclamationmark.triangle",
                    tint: errorTint,
                    availability: ioAvailability
                )
                StorageCounterTile(
                    title: "New retries",
                    value: formattedPair(
                        read: disk.io?.readRetriesSinceLastSample,
                        write: disk.io?.writeRetriesSinceLastSample
                    ),
                    subtitle: "Read / write in latest sample",
                    icon: "arrow.clockwise",
                    tint: retryTint,
                    availability: ioAvailability
                )
            }

            StorageInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Cumulative driver counters", systemImage: "sum")
                        .font(.headline)
                    Text("Values reported since this physical block-storage driver was instantiated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                        storageDetailRow("Bytes read", formattedBytes(disk.io?.bytesRead))
                        storageDetailRow("Bytes written", formattedBytes(disk.io?.bytesWritten))
                        storageDetailRow("Read operations", formattedCount(disk.io?.readOperations))
                        storageDetailRow("Write operations", formattedCount(disk.io?.writeOperations))
                        storageDetailRow("Read errors", formattedCount(disk.io?.readErrors))
                        storageDetailRow("Write errors", formattedCount(disk.io?.writeErrors))
                        storageDetailRow("Read retries", formattedCount(disk.io?.readRetries))
                        storageDetailRow("Write retries", formattedCount(disk.io?.writeRetries))
                        storageDetailRow("Total read time", formattedNanoseconds(disk.io?.totalReadTimeNanoseconds))
                        storageDetailRow("Total write time", formattedNanoseconds(disk.io?.totalWriteTimeNanoseconds))
                        storageDetailRow("Read latency time", formattedNanoseconds(disk.io?.totalReadLatencyNanoseconds))
                        storageDetailRow("Write latency time", formattedNanoseconds(disk.io?.totalWriteLatencyNanoseconds))
                    }
                }
            }

            StorageInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Volume and device", systemImage: "info.circle")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                        storageDetailRow("Mount point", disk.mountPoint)
                        storageDetailRow("File system", disk.fileSystem.uppercased())
                        storageDetailRow("Volume identity", disk.deviceIdentifier ?? "Unavailable")
                        storageDetailRow("Volume BSD", disk.volumeBSDName ?? "Unavailable")
                        storageDetailRow("Physical device", physicalDeviceLabel ?? "Unavailable")
                        storageDetailRow("Total capacity", ByteCountFormatter.macScope(disk.total))
                        storageDetailRow("Available now", ByteCountFormatter.macScope(min(disk.available, disk.total)))
                        if let important = disk.availableForImportantUsage {
                            storageDetailRow("Important use", ByteCountFormatter.macScope(min(important, disk.total)))
                        }
                        if let opportunistic = disk.availableForOpportunisticUsage {
                            storageDetailRow("Opportunistic use", ByteCountFormatter.macScope(min(opportunistic, disk.total)))
                        }
                        storageDetailRow("Access", disk.isReadOnly ? "Read-only" : "Read and write")
                        storageDetailRow("I/O source", disk.io?.provenance ?? "Unavailable")
                    }
                    if let detail = disk.io?.detail, !detail.isEmpty {
                        Label(detail, systemImage: ioAvailability == .available ? "checkmark.circle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Label(
                        "These are documented physical-driver counters. APFS sibling volumes share them; macOS does not expose queue depth, cache-hit rate, or per-file activity through this interface.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var operationsPanel: some View {
        StorageInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Read and write IOPS", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                MetricTrendChart(
                    series: operationsSeries,
                    unit: "ops/s",
                    includesZero: true,
                    height: 148,
                    showsLegend: true
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var latencyPanel: some View {
        StorageInsetPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Driver latency", systemImage: "timer")
                    .font(.subheadline.weight(.semibold))
                MetricTrendChart(
                    series: latencySeries,
                    unit: "ms",
                    includesZero: true,
                    height: 148,
                    showsLegend: true
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func storageDetailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private var capacitySegments: [DistributionSegment] {
        let total = disk.total
        let availableNow = min(disk.available, total)
        let allocated = min(disk.used, total)
        let reclaimable = min(disk.reclaimable, allocated)
        let used = allocated - min(reclaimable, allocated)
        return [
            DistributionSegment(
                id: "used",
                label: "Used",
                value: total > 0 ? Double(used) : nil,
                formattedValue: ByteCountFormatter.macScope(used),
                tint: capacityTint,
                availability: capacityAvailability
            ),
            DistributionSegment(
                id: "available",
                label: "Available now",
                value: total > 0 ? Double(availableNow) : nil,
                formattedValue: ByteCountFormatter.macScope(availableNow),
                tint: MacScopeTheme.cyan,
                availability: capacityAvailability
            ),
            DistributionSegment(
                id: "reclaimable",
                label: "Reclaimable",
                value: reclaimable > 0 ? Double(reclaimable) : nil,
                formattedValue: ByteCountFormatter.macScope(reclaimable),
                tint: .mint,
                availability: disk.availableForImportantUsage == nil ? .unsupported : .available
            )
        ]
    }

    private var activitySeries: [MetricSeries] {
        [
            MetricSeries(
                id: "storage-read-\(disk.id)",
                title: "Read",
                unit: "MiB/s",
                tint: MacScopeTheme.cyan,
                points: readRatePoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            ),
            MetricSeries(
                id: "storage-write-\(disk.id)",
                title: "Write",
                unit: "MiB/s",
                tint: MacScopeTheme.accent,
                points: writeRatePoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            )
        ]
    }

    private var operationsSeries: [MetricSeries] {
        [
            MetricSeries(
                id: "storage-read-iops-\(disk.id)",
                title: "Read",
                unit: "ops/s",
                tint: MacScopeTheme.cyan,
                points: readOperationsPoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            ),
            MetricSeries(
                id: "storage-write-iops-\(disk.id)",
                title: "Write",
                unit: "ops/s",
                tint: MacScopeTheme.accent,
                points: writeOperationsPoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            )
        ]
    }

    private var latencySeries: [MetricSeries] {
        [
            MetricSeries(
                id: "storage-read-latency-\(disk.id)",
                title: "Read",
                unit: "ms",
                tint: MacScopeTheme.cyan,
                points: readLatencyPoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            ),
            MetricSeries(
                id: "storage-write-latency-\(disk.id)",
                title: "Write",
                unit: "ms",
                tint: MacScopeTheme.accent,
                points: writeLatencyPoints,
                interpolation: .stepEnd,
                availability: ioAvailability,
                quality: .measured
            )
        ]
    }

    private var readRatePoints: [MetricPoint] {
        ratePoints { $0.io?.readBytesPerSecond }
    }

    private var writeRatePoints: [MetricPoint] {
        ratePoints { $0.io?.writeBytesPerSecond }
    }

    private var readOperationsPoints: [MetricPoint] {
        samplePoints { $0.io?.readOperationsPerSecond }
    }

    private var writeOperationsPoints: [MetricPoint] {
        samplePoints { $0.io?.writeOperationsPerSecond }
    }

    private var readLatencyPoints: [MetricPoint] {
        samplePoints { $0.io?.averageReadLatencyMilliseconds }
    }

    private var writeLatencyPoints: [MetricPoint] {
        samplePoints { $0.io?.averageWriteLatencyMilliseconds }
    }

    private func ratePoints(_ value: (DiskSnapshot) -> Double?) -> [MetricPoint] {
        samplePoints { disk in value(disk).map { $0 / 1_048_576 } }
    }

    private func samplePoints(_ value: (DiskSnapshot) -> Double?) -> [MetricPoint] {
        Array(history.suffix(120)).enumerated().compactMap { ordinal, snapshot in
            guard let sample = snapshot.disks.first(where: matchesCurrentDisk) else { return nil }
            return MetricPoint(
                timestamp: snapshot.timestamp,
                value: value(sample),
                ordinal: ordinal
            )
        }
    }

    private func matchesCurrentDisk(_ candidate: DiskSnapshot) -> Bool {
        if let deviceIdentifier = disk.deviceIdentifier,
           let candidateIdentifier = candidate.deviceIdentifier {
            return deviceIdentifier == candidateIdentifier
        }
        return disk.mountPoint == candidate.mountPoint
    }

    private var activitySubtitle: String {
        let device = physicalDeviceLabel ?? "unmapped device"
        if let detail = disk.io?.detail, !detail.isEmpty {
            return "\(device) • \(detail)"
        }
        return "Session throughput for \(device); APFS volumes may share these physical-driver counters"
    }

    private var physicalDeviceLabel: String? {
        switch (disk.physicalDeviceIdentifier, disk.physicalDeviceName) {
        case let (identifier?, name?) where !name.isEmpty: return "\(identifier) · \(name)"
        case let (identifier?, _): return identifier
        case let (_, name?) where !name.isEmpty: return name
        default: return nil
        }
    }

    private var identityHelp: String {
        [disk.mountPoint, disk.volumeBSDName, physicalDeviceLabel]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    private var capacityTint: Color {
        switch disk.usageFraction {
        case 0.9...: MacScopeTheme.critical
        case 0.75...: MacScopeTheme.warning
        default: MacScopeTheme.accent
        }
    }

    private var errorTint: Color {
        let errors = (disk.io?.readErrors ?? 0) + (disk.io?.writeErrors ?? 0)
        return errors > 0 ? MacScopeTheme.critical : .green
    }

    private var retryTint: Color {
        let retries = (disk.io?.readRetries ?? 0) + (disk.io?.writeRetries ?? 0)
        return retries > 0 ? MacScopeTheme.warning : .green
    }

    private func formattedRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(ByteCountFormatter.macScope(UInt64(max(value, 0))))/s"
    }

    private func formattedBytes(_ value: UInt64?) -> String {
        value.map(ByteCountFormatter.macScope) ?? "Unavailable"
    }

    private func formattedCount(_ value: UInt64?) -> String {
        value?.formatted() ?? "Unavailable"
    }

    private func formattedOperationsRate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Live rate unavailable" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) ops/s"
    }

    private func formattedIntervalCount(_ value: UInt64?) -> String {
        value.map { "\($0.formatted()) in the latest sample" } ?? "Waiting for the next sample"
    }

    private func formattedLatency(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2)))) ms"
    }

    private func formattedAverageBytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return ByteCountFormatter.macScope(UInt64(value.rounded()))
    }

    private func formattedNanoseconds(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        let seconds = Double(value) / 1_000_000_000
        let formatted = seconds.formatted(.number.precision(.fractionLength(0...3)))
        return "\(formatted) s · \(value.formatted()) ns"
    }

    private var sampleIntervalLabel: String {
        guard let interval = disk.io?.intervalDurationSeconds, interval.isFinite else {
            return "Waiting for the next sample"
        }
        return "Latest \(interval.formatted(.number.precision(.fractionLength(0...2)))) s sample"
    }

    private func formattedPair(read: UInt64?, write: UInt64?) -> String {
        guard read != nil || write != nil else { return "Unavailable" }
        return "\((read ?? 0).formatted()) / \((write ?? 0).formatted())"
    }
}

private struct StorageActivityMiniCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let points: [MetricPoint]
    let availability: DataAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                AvailabilityBadge(availability: availability)
            }
            .font(.caption.weight(.semibold))
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            MetricSparkline(
                points: points,
                tint: tint,
                includesZero: true,
                height: 38,
                accessibilityLabel: "\(title) history"
            )
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct StorageCounterTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color
    let availability: DataAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Spacer(minLength: 0)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 94, maxHeight: 94, alignment: .topLeading)
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.1), lineWidth: 1)
        }
        .opacity(availability == .unsupported ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(subtitle)")
    }
}

private struct StorageInsetPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .background(.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
    }
}
