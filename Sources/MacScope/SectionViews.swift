import Charts
import MacScopeCore
import ServiceManagement
import SwiftUI

private enum SectionRowLayout {
    static let acceleratorPanelHeight: CGFloat = 300
    static let memoryPanelHeight: CGFloat = 256
    static let powerPanelHeight: CGFloat = 250
}

struct SectionContent: View {
    let section: AppSection
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch section {
            case .overview: OverviewView(model: model)
            case .cpu: CPUView(model: model)
            case .gpu:
                if model.snapshot.acceleratorCapabilities.gpuTelemetryAvailable {
                    AcceleratorView(kind: .gpu, model: model)
                } else {
                    OverviewView(model: model)
                }
            case .npu:
                if model.snapshot.acceleratorCapabilities.aneTelemetryAvailable {
                    AcceleratorView(kind: .npu, model: model)
                } else {
                    OverviewView(model: model)
                }
            case .memory: MemoryView(model: model)
            case .thermals: ThermalsView(model: model)
            case .power: PowerView(model: model)
            case .network: NetworkView(model: model)
            case .storage: StorageView(model: model)
            case .processes: ProcessesView(model: model)
            case .startup: StartupView(model: model)
            case .features: MacOSFeaturesView()
            case .hardware: HardwareView(model: model)
            case .raw: RawDataView(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OverviewView: View {
    let model: AppModel

    private var acceleratorCapabilities: AcceleratorCapabilities { model.snapshot.acceleratorCapabilities }
    private var download: Double { model.snapshot.networks.reduce(0) { $0 + $1.downloadRate } }
    private var upload: Double { model.snapshot.networks.reduce(0) { $0 + $1.uploadRate } }
    private var memoryPercent: Double {
        guard model.snapshot.memory.total > 0 else { return 0 }
        return Double(model.snapshot.memory.used) / Double(model.snapshot.memory.total) * 100
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "System overview", subtitle: "Live health and utilization across \(model.snapshot.inventory.modelName)")
                GlassGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                        MetricCard(title: "CPU", value: percent(model.snapshot.cpuUsage), subtitle: loadSubtitle, icon: "cpu")
                        MetricCard(title: "Memory", value: percent(memoryPercent), subtitle: "\(ByteCountFormatter.macScope(model.snapshot.memory.used)) of \(ByteCountFormatter.macScope(model.snapshot.memory.total))", icon: "memorychip", tint: MacScopeTheme.cyan)
                        if acceleratorCapabilities.gpuTelemetryAvailable {
                            MetricCard(title: "GPU", value: optionalPercent(model.snapshot.deep.gpuUsage), subtitle: model.snapshot.deep.detail, icon: "rectangle.3.group", availability: model.snapshot.deep.availability)
                        }
                        if acceleratorCapabilities.aneTelemetryAvailable {
                            MetricCard(title: "ANE", value: optionalPercent(model.snapshot.deep.aneUsage), subtitle: "System-wide neural engine activity", icon: "brain.head.profile", availability: model.snapshot.deep.availability)
                        }
                        MetricCard(title: "Download", value: rate(download), subtitle: "Upload \(rate(upload))", icon: "arrow.down.circle")
                        MetricCard(title: "Processes", value: model.snapshot.processes.count.formatted(), subtitle: "\(model.snapshot.startupItems.count) startup definitions", icon: "list.bullet.rectangle")
                    }
                }

                OverviewSystemPulse(snapshot: model.snapshot, history: model.history)
                OverviewNetworkTrend(snapshot: model.snapshot, history: model.history)

                CapabilityStrip(snapshot: model.snapshot)
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private var loadSubtitle: String {
        guard !model.snapshot.loadAverages.isEmpty else { return "Collecting load averages" }
        return "Load " + model.snapshot.loadAverages.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " · ")
    }
}

private struct OverviewSystemPulse: View {
    let snapshot: SystemSnapshot
    let history: [SystemSnapshot]

    private var memoryUsage: Double? {
        guard snapshot.memory.total > 0 else { return nil }
        return min(max(Double(snapshot.memory.used) / Double(snapshot.memory.total) * 100, 0), 100)
    }

    private var series: [MetricSeries] {
        var result = [
            MetricSeries(
                id: "overview.cpu",
                title: "CPU",
                unit: "%",
                tint: MacScopeTheme.accent,
                points: history.map { sample in
                    MetricPoint(timestamp: sample.timestamp, value: min(max(sample.cpuUsage, 0), 100))
                },
                availability: .available,
                quality: .measured,
                interpolation: .linear
            ),
            MetricSeries(
                id: "overview.memory",
                title: "Memory",
                unit: "%",
                tint: MacScopeTheme.cyan,
                points: history.compactMap { sample in
                    guard sample.memory.total > 0 else { return nil }
                    let value = min(max(Double(sample.memory.used) / Double(sample.memory.total) * 100, 0), 100)
                    return MetricPoint(timestamp: sample.timestamp, value: value)
                },
                availability: snapshot.memory.total > 0 ? .available : .unsupported,
                quality: .derived,
                interpolation: .linear
            )
        ]
        let capabilities = snapshot.acceleratorCapabilities
        if capabilities.gpuTelemetryAvailable {
            result.append(MetricSeries(
                id: "overview.gpu",
                title: "GPU",
                unit: "%",
                tint: .orange,
                points: history.compactMap { sample in
                    sample.deep.gpuUsage.map { MetricPoint(timestamp: sample.timestamp, value: min(max($0, 0), 100)) }
                },
                availability: snapshot.deep.gpuUsage == nil ? snapshot.deep.availability : .available,
                quality: .measured,
                interpolation: .stepEnd
            ))
        }
        if capabilities.aneTelemetryAvailable {
            result.append(MetricSeries(
                id: "overview.ane",
                title: "ANE",
                unit: "%",
                tint: .purple,
                points: history.compactMap { sample in
                    sample.deep.aneUsage.map { MetricPoint(timestamp: sample.timestamp, value: min(max($0, 0), 100)) }
                },
                availability: snapshot.deep.aneUsage == nil ? snapshot.deep.availability : .available,
                quality: .measured,
                interpolation: .stepEnd
            ))
        }
        return result
    }

    var body: some View {
        VisualPanel(
            title: "System pulse",
            subtitle: "Current utilization and this session's recent history",
            availability: .available
        ) {
            HStack(alignment: .top, spacing: 24) {
                MetricRing(
                    title: "CPU",
                    value: percent(snapshot.cpuUsage),
                    unit: "",
                    fraction: min(max(snapshot.cpuUsage / 100, 0), 1),
                    tint: MacScopeTheme.accent,
                    icon: "cpu",
                    availability: .available
                )
                MetricRing(
                    title: "Memory",
                    value: memoryUsage.map(percent) ?? "—",
                    unit: "",
                    fraction: memoryUsage.map { $0 / 100 },
                    tint: MacScopeTheme.cyan,
                    icon: "memorychip",
                    availability: memoryUsage == nil ? .unsupported : .available
                )
                if snapshot.acceleratorCapabilities.gpuTelemetryAvailable {
                    MetricRing(
                        title: "GPU",
                        value: snapshot.deep.gpuUsage.map(percent) ?? "—",
                        unit: "",
                        fraction: snapshot.deep.gpuUsage.map { min(max($0 / 100, 0), 1) },
                        tint: .orange,
                        icon: "rectangle.3.group",
                        availability: snapshot.deep.gpuUsage == nil ? snapshot.deep.availability : .available
                    )
                }
                if snapshot.acceleratorCapabilities.aneTelemetryAvailable {
                    MetricRing(
                        title: "ANE",
                        value: snapshot.deep.aneUsage.map(percent) ?? "—",
                        unit: "",
                        fraction: snapshot.deep.aneUsage.map { min(max($0 / 100, 0), 1) },
                        tint: .purple,
                        icon: "brain.head.profile",
                        availability: snapshot.deep.aneUsage == nil ? snapshot.deep.availability : .available
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            MetricTrendChart(series: series, unit: "%", domain: 0...100, includesZero: true, height: 150, showsLegend: true)
        }
        .frame(minHeight: 330)
    }
}

private struct OverviewNetworkTrend: View {
    let snapshot: SystemSnapshot
    let history: [SystemSnapshot]

    private var series: [MetricSeries] {
        let download = history.map { sample in
            MetricPoint(
                timestamp: sample.timestamp,
                value: sample.networks.reduce(0) { $0 + $1.downloadRate } / 1_048_576
            )
        }
        let upload = history.map { sample in
            MetricPoint(
                timestamp: sample.timestamp,
                value: sample.networks.reduce(0) { $0 + $1.uploadRate } / 1_048_576
            )
        }
        return [
            MetricSeries(id: "overview.network.download", title: "Download", unit: "MiB/s", tint: MacScopeTheme.cyan, points: download, availability: .available, quality: .derived, interpolation: .linear),
            MetricSeries(id: "overview.network.upload", title: "Upload", unit: "MiB/s", tint: .purple, points: upload, availability: .available, quality: .derived, interpolation: .linear)
        ]
    }

    var body: some View {
        VisualPanel(
            title: "Network traffic",
            subtitle: "Aggregate rate across all reported interfaces · Down \(rate(snapshot.networks.reduce(0) { $0 + $1.downloadRate })) · Up \(rate(snapshot.networks.reduce(0) { $0 + $1.uploadRate }))",
            availability: .available
        ) {
            MetricTrendChart(series: series, unit: "MiB/s", domain: nil, includesZero: true, height: 190, showsLegend: true)
        }
        .frame(minHeight: 260)
    }
}

private struct CapabilityStrip: View {
    let snapshot: SystemSnapshot
    @State private var helperMessage: String?
    private var helperRegistered: Bool {
        SMAppService.daemon(plistName: "local.taskmanager.MacScope.Helper.plist").status == .enabled
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: snapshot.deep.helperConnected == true ? "checkmark.shield" : "lock.shield")
                    .font(.title2)
                    .foregroundStyle(snapshot.deep.helperConnected == true ? .green : .purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.deep.helperConnected == true ? "Privileged helper connected" : helperRegistered ? "Privileged helper registered" : "Public telemetry mode")
                        .font(.headline)
                    Text(helperMessage ?? snapshot.deep.detail ?? "All available collectors are reporting normally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.deep.helperConnected != true && !helperRegistered {
                    Button("Install Helper…") { installHelper() }
                        .macScopeGlassButton(prominent: true)
                        .help("Register the bundled privileged helper. macOS will request administrator approval.")
                } else if snapshot.deep.helperConnected == true {
                    AvailabilityBadge(availability: snapshot.deep.availability)
                } else {
                    ProgressView().controlSize(.small).help("Waiting for the registered helper to respond")
                }
            }
        }
    }

    private func installHelper() {
        do {
            try SMAppService.daemon(plistName: "local.taskmanager.MacScope.Helper.plist").register()
            helperMessage = "Helper registered. Approve MacScope in System Settings if macOS requests it."
        } catch {
            helperMessage = error.localizedDescription
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

struct CPUView: View {
    let model: AppModel
    @State private var graphMode = CPUGraphMode.total

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "CPU", subtitle: "Aggregate and logical-core utilization from Mach host statistics")
                GlassGroup {
                    HStack(alignment: .top, spacing: 12) {
                        MetricCard(title: "Total", value: percent(model.snapshot.cpuUsage), icon: "cpu")
                        MetricCard(title: "User", value: percent(model.snapshot.cpuUser), icon: "person")
                        MetricCard(title: "System", value: percent(model.snapshot.cpuSystem), icon: "gearshape.2")
                        MetricCard(title: "Frequency", value: optionalMHz(model.snapshot.deep.cpuFrequencyMHz), icon: "gauge.with.dots.needle.67percent", availability: model.snapshot.deep.availability)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(graphMode == .total ? "CPU utilization" : "Per-core utilization").font(.headline)
                            Spacer()
                            Picker("Graph mode", selection: $graphMode) {
                                ForEach(CPUGraphMode.allCases) { mode in Text(mode.title).tag(mode) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 310)
                            .macScopeGlassControl()
                        }
                        if graphMode == .total {
                            Chart(model.history, id: \.timestamp) { item in
                                AreaMark(x: .value("Time", item.timestamp), y: .value("CPU", item.cpuUsage))
                                    .foregroundStyle(LinearGradient(colors: [MacScopeTheme.accent.opacity(0.38), MacScopeTheme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Time", item.timestamp), y: .value("CPU", item.cpuUsage))
                                    .foregroundStyle(MacScopeTheme.accent)
                                    .lineStyle(.init(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.linear)
                            }
                            .chartYScale(domain: 0...100)
                            .chartXAxis(.hidden)
                            .chartPlotStyle { plotArea in plotArea.clipped() }
                            .frame(height: 220)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        } else {
                            Chart {
                                ForEach(model.history, id: \.timestamp) { sample in
                                    ForEach(sample.cores) { core in
                                        LineMark(
                                            x: .value("Time", sample.timestamp),
                                            y: .value("Usage", core.usage),
                                            series: .value("Core", "Core \(core.id + 1)")
                                        )
                                        .foregroundStyle(by: .value("Core", "Core \(core.id + 1)"))
                                        .lineStyle(.init(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                                        .interpolationMethod(.linear)
                                    }
                                }
                            }
                            .chartYScale(domain: 0...100)
                            .chartXAxis(.hidden)
                            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                            .chartPlotStyle { plotArea in plotArea.clipped() }
                            .frame(height: 270)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .animation(.smooth(duration: 0.35), value: graphMode)
                }
                if graphMode == .perCore {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Logical cores").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(model.snapshot.cores) { core in
                                    CoreGauge(core: core, history: model.history)
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.smooth(duration: 0.35), value: graphMode)
            .padding(24)
        }
        .navigationTitle("CPU")
    }
}

private enum CPUGraphMode: String, CaseIterable, Identifiable {
    case total
    case perCore
    var id: String { rawValue }
    var title: String { self == .total ? "CPU utilization" : "Per-core utilization" }
}

private struct CoreGauge: View {
    let core: CPUCoreSnapshot
    let history: [SystemSnapshot]

    private var points: [(date: Date, usage: Double)] {
        history.compactMap { snapshot in
            snapshot.cores.first(where: { $0.id == core.id }).map { (snapshot.timestamp, $0.usage) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Core \(core.id + 1)").font(.caption.weight(.medium))
                Spacer()
                Text(percent(core.usage)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Chart(points, id: \.date) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Usage", point.usage))
                    .foregroundStyle(LinearGradient(colors: [MacScopeTheme.accent.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("Usage", point.usage))
                    .foregroundStyle(MacScopeTheme.accent)
                    .lineStyle(.init(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plotArea in plotArea.clipped() }
            .frame(height: 34)
            Text("User \(percent(core.user)) · System \(percent(core.system))")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(height: 86, alignment: .topLeading)
        .macScopeGlassSurface(cornerRadius: 8)
    }
}

enum AcceleratorKind { case gpu, npu }

struct AcceleratorView: View {
    let kind: AcceleratorKind
    let model: AppModel

    private var name: String { kind == .gpu ? "GPU" : "NPU / ANE" }
    private var usage: Double? { kind == .gpu ? model.snapshot.deep.gpuUsage : model.snapshot.deep.aneUsage }
    private var frequency: Double? { kind == .gpu ? model.snapshot.deep.gpuFrequencyMHz : model.snapshot.deep.aneFrequencyMHz }
    private var power: Double? { kind == .gpu ? model.snapshot.deep.gpuPowerWatts : model.snapshot.deep.anePowerWatts }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: name, subtitle: kind == .gpu ? "System-wide graphics activity and residency" : "System-wide Apple Neural Engine telemetry")
                GlassGroup {
                    HStack(alignment: .top, spacing: 12) {
                        MetricCard(title: "Activity", value: optionalPercent(usage), icon: kind == .gpu ? "rectangle.3.group" : "brain.head.profile", availability: model.snapshot.deep.availability)
                        MetricCard(title: "Frequency", value: optionalMHz(frequency), icon: "waveform.path", availability: model.snapshot.deep.availability)
                        MetricCard(title: "Estimated power", value: optionalWatts(power), icon: "bolt", availability: model.snapshot.deep.availability)
                    }
                }
                AcceleratorVisuals(kind: kind, snapshot: model.snapshot, history: model.history)
                if kind == .gpu, let device = model.snapshot.inventory.gpus?.first {
                    Card {
                        LabeledContent("Detected GPU", value: device.name)
                        if let cores = device.coreCount { LabeledContent("GPU cores", value: cores.formatted()) }
                    }
                }
                if model.snapshot.deep.availability != .available {
                    EmptyMetricView(title: "Privileged telemetry required", detail: model.snapshot.deep.detail ?? "Approve the helper to collect these counters.", icon: "lock.shield")
                }
            }
            .padding(24)
        }
        .navigationTitle(name)
    }
}

private struct AcceleratorVisuals: View {
    let kind: AcceleratorKind
    let snapshot: SystemSnapshot
    let history: [SystemSnapshot]

    private var name: String { kind == .gpu ? "GPU" : "ANE" }
    private var icon: String { kind == .gpu ? "rectangle.3.group" : "brain.head.profile" }
    private var tint: Color { kind == .gpu ? MacScopeTheme.cyan : .purple }
    private var usage: Double? { kind == .gpu ? snapshot.deep.gpuUsage : snapshot.deep.aneUsage }
    private var frequency: Double? { kind == .gpu ? snapshot.deep.gpuFrequencyMHz : snapshot.deep.aneFrequencyMHz }
    private var power: Double? { kind == .gpu ? snapshot.deep.gpuPowerWatts : snapshot.deep.anePowerWatts }

    private var activitySeries: MetricSeries {
        let points = history.compactMap { sample -> MetricPoint? in
            guard let raw = kind == .gpu ? sample.deep.gpuUsage : sample.deep.aneUsage,
                  raw.isFinite else { return nil }
            return MetricPoint(timestamp: sample.timestamp, value: min(max(raw, 0), 100))
        }
        return MetricSeries(
            id: "\(name.lowercased()).activity",
            title: "Activity",
            unit: "%",
            tint: tint,
            points: points,
            availability: metricAvailability(current: usage, hasHistory: !points.isEmpty),
            quality: .measured,
            interpolation: .stepEnd
        )
    }

    private var frequencySeries: MetricSeries {
        let points = history.compactMap { sample -> MetricPoint? in
            guard let value = kind == .gpu ? sample.deep.gpuFrequencyMHz : sample.deep.aneFrequencyMHz,
                  value.isFinite, value >= 0 else { return nil }
            return MetricPoint(timestamp: sample.timestamp, value: value)
        }
        return MetricSeries(
            id: "\(name.lowercased()).frequency",
            title: "Frequency",
            unit: "MHz",
            tint: .orange,
            points: points,
            availability: metricAvailability(current: frequency, hasHistory: !points.isEmpty),
            quality: .measured,
            interpolation: .stepEnd
        )
    }

    private var powerSeries: MetricSeries {
        let points = history.compactMap { sample -> MetricPoint? in
            guard let value = kind == .gpu ? sample.deep.gpuPowerWatts : sample.deep.anePowerWatts,
                  value.isFinite, value >= 0 else { return nil }
            return MetricPoint(timestamp: sample.timestamp, value: value)
        }
        return MetricSeries(
            id: "\(name.lowercased()).power",
            title: "Estimated power",
            unit: "W",
            tint: .yellow,
            points: points,
            availability: metricAvailability(current: power, hasHistory: !points.isEmpty),
            quality: .estimated,
            interpolation: .stepEnd
        )
    }

    var body: some View {
        GlassGroup {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 390), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                VisualPanel(
                    title: "\(name) activity",
                    subtitle: "System-wide active residency",
                    availability: activitySeries.availability,
                    height: SectionRowLayout.acceleratorPanelHeight
                ) {
                    HStack(alignment: .top, spacing: 22) {
                        MetricRing(
                            title: "Activity",
                            value: usage.map(percent) ?? "—",
                            unit: "",
                            fraction: usage.map { min(max($0 / 100, 0), 1) },
                            tint: tint,
                            icon: icon,
                            availability: activitySeries.availability
                        )
                        MetricSparkline(points: activitySeries.points, tint: activitySeries.tint, domain: 0...100, interpolation: activitySeries.interpolation, height: 126)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                VisualPanel(
                    title: "Frequency & power",
                    subtitle: "Separate scales preserve the reported units",
                    availability: combinedAvailability,
                    height: SectionRowLayout.acceleratorPanelHeight
                ) {
                    AcceleratorTrendLane(icon: "waveform.path", value: optionalMHz(frequency), series: frequencySeries)
                    Divider()
                    AcceleratorTrendLane(icon: "bolt.fill", value: optionalWatts(power), series: powerSeries)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var combinedAvailability: DataAvailability {
        if frequency != nil || power != nil || !frequencySeries.points.isEmpty || !powerSeries.points.isEmpty { return .available }
        return snapshot.deep.availability
    }

    private func metricAvailability(current: Double?, hasHistory: Bool) -> DataAvailability {
        current != nil || hasHistory ? .available : snapshot.deep.availability
    }
}

private struct AcceleratorTrendLane: View {
    let icon: String
    let value: String
    let series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(series.title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            }
            MetricSparkline(points: series.points, tint: series.tint, domain: nil, interpolation: series.interpolation, height: 68)
        }
    }
}

struct MemoryView: View {
    let model: AppModel
    private var memory: MemorySnapshot { model.snapshot.memory }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Memory", subtitle: "Physical memory, compression, cache, and swap")
                GlassGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                        MetricCard(title: "Used", value: ByteCountFormatter.macScope(memory.used), icon: "memorychip")
                        MetricCard(title: "Wired", value: ByteCountFormatter.macScope(memory.wired), icon: "lock")
                        MetricCard(title: "Compressed", value: ByteCountFormatter.macScope(memory.compressed), icon: "arrow.down.right.and.arrow.up.left")
                        MetricCard(title: "Cached", value: ByteCountFormatter.macScope(memory.cached), icon: "shippingbox")
                        MetricCard(title: "Free", value: ByteCountFormatter.macScope(memory.free), icon: "circle.dotted")
                        MetricCard(title: "Swap", value: ByteCountFormatter.macScope(memory.swapUsed), subtitle: "of \(ByteCountFormatter.macScope(memory.swapTotal))", icon: "internaldrive")
                    }
                }
                MemoryCompositionGraphic(memory: memory)
                MemoryHistoryGraphic(memory: memory, history: model.history)
            }
            .padding(24)
        }
        .navigationTitle("Memory")
    }
}

private struct MemoryCompositionGraphic: View {
    let memory: MemorySnapshot

    private var usedPercent: Double? {
        guard memory.total > 0 else { return nil }
        return min(max(Double(memory.used) / Double(memory.total) * 100, 0), 100)
    }

    private var swapPercent: Double? {
        guard memory.swapTotal > 0 else { return nil }
        return min(max(Double(memory.swapUsed) / Double(memory.swapTotal) * 100, 0), 100)
    }

    private var segments: [DistributionSegment] {
        [
            DistributionSegment(id: "active", label: "Active (GiB)", value: gibibytes(memory.active), tint: MacScopeTheme.accent),
            DistributionSegment(id: "inactive", label: "Inactive (GiB)", value: gibibytes(memory.inactive), tint: MacScopeTheme.cyan),
            DistributionSegment(id: "wired", label: "Wired (GiB)", value: gibibytes(memory.wired), tint: .orange),
            DistributionSegment(id: "compressed", label: "Compressed (GiB)", value: gibibytes(memory.compressed), tint: .purple)
        ]
    }

    var body: some View {
        GlassGroup {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 390), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                VisualPanel(
                    title: "Capacity",
                    subtitle: "Physical memory and swap utilization",
                    availability: memory.total > 0 ? .available : .unsupported,
                    height: SectionRowLayout.memoryPanelHeight
                ) {
                    HStack(alignment: .top, spacing: 34) {
                        MetricRing(
                            title: "Physical memory",
                            value: usedPercent.map(percent) ?? "—",
                            unit: "",
                            fraction: usedPercent.map { $0 / 100 },
                            tint: MacScopeTheme.accent,
                            icon: "memorychip",
                            availability: memory.total > 0 ? .available : .unsupported
                        )
                        MetricRing(
                            title: "Swap",
                            value: swapPercent.map(percent) ?? "—",
                            unit: "",
                            fraction: swapPercent.map { $0 / 100 },
                            tint: .purple,
                            icon: "internaldrive",
                            availability: memory.swapTotal > 0 ? .available : .unsupported
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)

                VisualPanel(
                    title: "Reported used-memory composition",
                    subtitle: "VM counters that contribute to the reported used value",
                    availability: memory.total > 0 ? .available : .unsupported,
                    height: SectionRowLayout.memoryPanelHeight
                ) {
                    MetricDistributionBar(segments: segments, height: 28, showsLegend: true)
                    Text("Cached and free counters are shown separately because they are not additive partitions of used memory.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct MemoryHistoryGraphic: View {
    let memory: MemorySnapshot
    let history: [SystemSnapshot]

    private var series: [MetricSeries] {
        [
            makeSeries(id: "memory.used", title: "Used", tint: MacScopeTheme.accent, value: { gibibytes($0.memory.used) }),
            makeSeries(id: "memory.wired", title: "Wired", tint: MacScopeTheme.cyan, value: { gibibytes($0.memory.wired) }),
            makeSeries(id: "memory.compressed", title: "Compressed", tint: .purple, value: { gibibytes($0.memory.compressed) })
        ]
    }

    var body: some View {
        VisualPanel(
            title: "Memory usage over time",
            subtitle: "Used, wired, and compressed physical memory",
            availability: memory.total > 0 ? .available : .unsupported
        ) {
            MetricTrendChart(
                series: series,
                unit: "GiB",
                domain: memory.total > 0 ? 0...max(gibibytes(memory.total), 1) : nil,
                includesZero: true,
                height: 240,
                showsLegend: true
            )
        }
    }

    private func makeSeries(id: String, title: String, tint: Color, value: (SystemSnapshot) -> Double) -> MetricSeries {
        MetricSeries(
            id: id,
            title: title,
            unit: "GiB",
            tint: tint,
            points: history.map { sample in
                MetricPoint(timestamp: sample.timestamp, value: value(sample))
            },
            availability: memory.total > 0 ? .available : .unsupported,
            quality: .measured,
            interpolation: .linear
        )
    }
}

struct ThermalsView: View {
    let model: AppModel

    private var hottestSensor: (key: String, value: Double)? {
        model.snapshot.deep.sensors.max(by: { $0.value < $1.value })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Thermals", subtitle: "System thermal pressure and discoverable SMC sensors")
                GlassGroup {
                    HStack(alignment: .top, spacing: 12) {
                        MetricCard(title: "Thermal pressure", value: model.snapshot.deep.thermalPressure ?? model.snapshot.inventory.details["Thermal State"] ?? "Unknown", icon: "thermometer.medium", availability: model.snapshot.deep.thermalPressure == nil ? .degraded : .available)
                        MetricCard(title: "Sensors", value: model.snapshot.deep.sensors.count.formatted(), icon: "sensor")
                        MetricCard(title: "Hottest sensor", value: hottestSensor.map { "\($0.value.formatted(.number.precision(.fractionLength(1)))) °C" } ?? "Unavailable", subtitle: hottestSensor.map { ThermalSensorPresentation(key: $0.key).title }, icon: "thermometer.high", availability: hottestSensor == nil ? .unsupported : .available)
                        MetricCard(title: "Fans", value: model.snapshot.deep.fanSpeeds.count.formatted(), subtitle: model.snapshot.deep.fanSpeeds.isEmpty ? "RPM unavailable" : "Live AppleSMC readings", icon: "fan", availability: model.snapshot.deep.fanSpeeds.isEmpty ? .unsupported : .available)
                    }
                }
                ThermalLocationMap(
                    sensors: model.snapshot.deep.sensors,
                    fanSpeeds: model.snapshot.deep.fanSpeeds
                )
                ThermalHistoryGraphic(sensors: model.snapshot.deep.sensors, history: model.history, fallbackAvailability: model.snapshot.deep.availability)
                if !model.snapshot.deep.fanSpeeds.isEmpty {
                    GlassGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                            ForEach(model.snapshot.deep.fanSpeeds.sorted(by: { $0.key < $1.key }), id: \.key) { key, rpm in
                                FanSpeedCard(name: key, rpm: rpm, history: model.history)
                            }
                        }
                    }
                }
                if model.snapshot.deep.sensors.isEmpty {
                    EmptyMetricView(title: "No SMC sensors available", detail: model.snapshot.deep.detail ?? "The helper is required to read model-specific sensors.", icon: "thermometer.medium.slash")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Temperature sensors").font(.headline)
                            Spacer()
                            Text("Live · 2 second sampling").font(.caption).foregroundStyle(.secondary)
                        }
                        GlassGroup(spacing: 10) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 245), spacing: 10)], spacing: 10) {
                                ForEach(model.snapshot.deep.sensors.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }), id: \.key) { key, value in
                                    ThermalSensorCard(key: key, temperature: value)
                                }
                            }
                        }
                    }
                }
            }.padding(24)
        }.navigationTitle("Thermals")
    }
}

private struct ThermalHistoryGraphic: View {
    let sensors: [String: Double]
    let history: [SystemSnapshot]
    let fallbackAvailability: DataAvailability

    private let palette: [Color] = [MacScopeTheme.cyan, .orange, .purple, MacScopeTheme.accent]

    private var hottestKeys: [String] {
        var maxima = sensors
        let availableKeys = Set(sensors.keys)
        for sample in history.suffix(180) {
            for (key, value) in sample.deep.sensors where availableKeys.contains(key) && value.isFinite {
                maxima[key] = max(maxima[key] ?? value, value)
            }
        }
        return maxima
            .sorted {
                if $0.value == $1.value { return $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                return $0.value > $1.value
            }
            .prefix(4)
            .map(\.key)
    }

    private var series: [MetricSeries] {
        hottestKeys.enumerated().map { seriesIndex, key in
            let points = history.compactMap { sample -> MetricPoint? in
                guard let value = sample.deep.sensors[key], value.isFinite, value > -20, value < 160 else { return nil }
                return MetricPoint(timestamp: sample.timestamp, value: value)
            }
            let presentation = ThermalSensorPresentation(key: key)
            return MetricSeries(
                id: "thermal.\(key)",
                title: "\(presentation.title) · \(key)",
                unit: "°C",
                tint: palette[seriesIndex % palette.count],
                points: points,
                availability: points.isEmpty ? fallbackAvailability : .available,
                quality: .measured,
                interpolation: .linear
            )
        }
    }

    private var domain: ClosedRange<Double>? {
        let values = series.flatMap { $0.points.compactMap(\.value) }
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        let lower = floor(minimum - 2)
        let upper = max(ceil(maximum + 2), lower + 4)
        return lower...upper
    }

    var body: some View {
        VisualPanel(
            title: "Hottest sensor history",
            subtitle: "Up to four hottest available sensors over this session",
            availability: series.contains(where: { !$0.points.isEmpty }) ? .available : fallbackAvailability
        ) {
            MetricTrendChart(series: series, unit: "°C", domain: domain, includesZero: false, height: 235, showsLegend: true)
        }
    }
}

private struct ThermalSensorPresentation {
    let key: String

    var title: String {
        let lower = key.lowercased()
        if lower.hasPrefix("tdie") { return "SoC die \(suffix)" }
        if lower.hasPrefix("tdev") { return "Device sensor \(suffix)" }
        if lower.hasPrefix("tcal") { return "Calibration sensor \(suffix)" }
        if lower.hasPrefix("tp") { return "Proximity sensor \(suffix)" }
        if lower.hasPrefix("tg") { return "GPU proximity \(suffix)" }
        if lower.hasPrefix("tc") { return "CPU proximity \(suffix)" }
        if lower.hasPrefix("tb") { return "Battery proximity \(suffix)" }
        return "Thermal sensor"
    }

    var icon: String {
        let lower = key.lowercased()
        if lower.hasPrefix("tdie") { return "cpu" }
        if lower.hasPrefix("tdev") { return "memorychip" }
        if lower.hasPrefix("tp") { return "dot.radiowaves.left.and.right" }
        if lower.hasPrefix("tg") { return "rectangle.3.group" }
        if lower.hasPrefix("tb") { return "battery.75percent" }
        if lower.hasPrefix("tcal") { return "slider.horizontal.3" }
        return "thermometer.medium"
    }

    private var suffix: String {
        let components = key.split(separator: "#", maxSplits: 1).map(String.init)
        let baseDigits = components[0].filter(\.isNumber)
        guard components.count == 2 else { return baseDigits }
        let duplicate = components[1].trimmingCharacters(in: .whitespaces)
        return baseDigits.isEmpty ? duplicate : "\(baseDigits) · \(duplicate)"
    }
}

private struct ThermalSensorCard: View {
    let key: String
    let temperature: Double

    private var presentation: ThermalSensorPresentation { .init(key: key) }
    private var tint: Color {
        if temperature >= 90 { return .red }
        if temperature >= 75 { return .orange }
        if temperature >= 60 { return .yellow }
        return MacScopeTheme.cyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text(key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
            }
            Text("\(temperature.formatted(.number.precision(.fractionLength(1)))) °C")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Capsule().fill(tint.gradient)
                        .frame(width: proxy.size.width * min(max(temperature / 110, 0), 1), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .frame(height: 112, alignment: .topLeading)
        .macScopeGlassSurface()
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.16), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title), \(temperature.formatted(.number.precision(.fractionLength(1)))) degrees Celsius, sensor \(key)")
    }
}

private struct FanSpeedCard: View {
    let name: String
    let rpm: Double
    let history: [SystemSnapshot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var series: MetricSeries {
        MetricSeries(
            id: "fan.\(name)",
            title: name,
            unit: "RPM",
            tint: MacScopeTheme.cyan,
            points: history.compactMap { sample in
                guard let value = sample.deep.fanSpeeds[name], value.isFinite, value >= 0 else { return nil }
                return MetricPoint(timestamp: sample.timestamp, value: value)
            },
            availability: .available,
            quality: .measured,
            interpolation: .linear
        )
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion || rpm < 1)) { timeline in
                        let mappedRotationsPerSecond = min(max(rpm / 2_500, 0.12), 1.8)
                        let angle = timeline.date.timeIntervalSinceReferenceDate * mappedRotationsPerSecond * 360
                        Image(systemName: "fan.fill")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(MacScopeTheme.cyan.gradient)
                            .rotationEffect(.degrees(angle))
                    }
                    .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(rpm.formatted(.number.precision(.fractionLength(0)))) RPM")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                            .monospacedDigit()
                    }
                }
                MetricSparkline(points: series.points, tint: series.tint, domain: nil, interpolation: series.interpolation, height: 38)
            }
            .frame(height: 106, alignment: .topLeading)
        }
        .frame(height: 138)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(rpm.formatted(.number.precision(.fractionLength(0)))) revolutions per minute")
    }
}

struct PowerView: View {
    let model: AppModel

    private var battery: BatterySnapshot { model.snapshot.battery }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Power & Battery", subtitle: "Battery health, charge state, and estimated SoC rail power")

                GlassGroup {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 390), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        BatteryOverviewGraphic(battery: battery)
                        PowerFlowGraphic(snapshot: model.snapshot)
                    }
                }

                PowerHistoryGraphic(
                    history: model.history,
                    isRunning: model.isRunning,
                    acceleratorCapabilities: model.snapshot.acceleratorCapabilities
                )

                if battery.isPresent {
                    BatteryHistoryGraphic(history: model.history)
                }

                HStack {
                    Text("Live telemetry").font(.headline)
                    Spacer()
                    Text("Measured and estimated values").font(.caption).foregroundStyle(.secondary)
                }
                GlassGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                        MetricCard(title: "Battery", value: battery.chargePercent.map(percent) ?? (battery.isPresent ? "Unknown" : "Not present"), subtitle: battery.powerSourceState, icon: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent", availability: battery.availability)
                        MetricCard(title: "Battery health", value: battery.healthPercent.map(percent) ?? "Unavailable", subtitle: battery.health ?? battery.condition, icon: "heart.text.square", availability: battery.healthPercent == nil && battery.isPresent ? .degraded : battery.availability)
                        MetricCard(title: "Charge cycles", value: battery.cycleCount?.formatted() ?? "Unavailable", subtitle: battery.designCycleCount.map { "Rated for \($0.formatted()) cycles" }, icon: "arrow.triangle.2.circlepath", availability: battery.cycleCount == nil && battery.isPresent ? .degraded : battery.availability)
                        MetricCard(title: "Battery temperature", value: battery.temperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" } ?? "Unavailable", icon: "thermometer.medium", availability: battery.temperatureCelsius == nil && battery.isPresent ? .degraded : battery.availability)
                        MetricCard(title: "System power", value: optionalWatts(battery.systemPowerWatts), subtitle: battery.adapterName ?? (battery.isExternalPowerConnected ? "External power" : "On battery"), icon: "powerplug", availability: battery.systemPowerWatts == nil ? .degraded : .available)
                        MetricCard(title: "Battery power", value: optionalWatts(battery.batteryPowerWatts), subtitle: battery.isCharging ? "Charging" : battery.isFullyCharged ? "Fully charged" : "Discharging", icon: "bolt.fill", availability: battery.batteryPowerWatts == nil ? .degraded : .available)
                        MetricCard(title: "CPU power", value: optionalWatts(model.snapshot.deep.cpuPowerWatts), icon: "cpu", availability: model.snapshot.deep.availability)
                        if model.snapshot.acceleratorCapabilities.gpuTelemetryAvailable {
                            MetricCard(title: "GPU power", value: optionalWatts(model.snapshot.deep.gpuPowerWatts), icon: "rectangle.3.group", availability: model.snapshot.deep.availability)
                        }
                        if model.snapshot.acceleratorCapabilities.aneTelemetryAvailable {
                            MetricCard(title: "ANE power", value: optionalWatts(model.snapshot.deep.anePowerWatts), icon: "brain.head.profile", availability: model.snapshot.deep.availability)
                        }
                        MetricCard(title: "Low Power Mode", value: model.snapshot.inventory.details["Low Power Mode"] ?? "Unknown", icon: "leaf")
                    }
                }
                Text("Power values reported by powermetrics are estimates and are labeled accordingly.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.navigationTitle("Power & Battery")
    }
}

private struct BatteryOverviewGraphic: View {
    let battery: BatterySnapshot

    private var charge: Double? { battery.chargePercent.map { min(max($0, 0), 100) } }
    private var health: Double? { battery.healthPercent.map { min(max($0, 0), 100) } }
    private var cycleFraction: Double? {
        guard let cycles = battery.cycleCount, let design = battery.designCycleCount, design > 0 else { return nil }
        return min(max(Double(cycles) / Double(design), 0), 1)
    }

    private var chargeTint: Color {
        guard let charge else { return .secondary }
        if battery.isCharging { return MacScopeTheme.cyan }
        if charge > 40 { return .green }
        if charge > 20 { return .orange }
        return .red
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(battery.name, systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(chargeTint)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(chargeTint.opacity(0.12), in: Capsule())
                }

                HStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.12), lineWidth: 13)
                        Circle()
                            .trim(from: 0, to: (charge ?? 0) / 100)
                            .stroke(
                                AngularGradient(colors: [chargeTint.opacity(0.45), chargeTint], center: .center),
                                style: StrokeStyle(lineWidth: 13, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.smooth(duration: 0.55), value: charge)
                        Circle()
                            .trim(from: 0, to: (health ?? 0) / 100)
                            .stroke(MacScopeTheme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(19)
                            .animation(.smooth(duration: 0.55), value: health)
                        VStack(spacing: 1) {
                            Text(charge.map(percent) ?? "—")
                                .font(.system(size: 27, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(battery.isPresent ? "charge" : "no battery")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 132, height: 132)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Battery charge, \(charge.map(percent) ?? "unavailable")")

                    VStack(spacing: 13) {
                        BatteryLevelRow(
                            title: "Health",
                            value: health.map(percent) ?? "Unavailable",
                            fraction: health.map { $0 / 100 },
                            tint: health.map { $0 >= 80 ? .green : .orange } ?? .secondary
                        )
                        BatteryLevelRow(
                            title: "Cycle life",
                            value: cycleText,
                            fraction: cycleFraction,
                            tint: MacScopeTheme.cyan
                        )
                        HStack(spacing: 14) {
                            BatteryTinyMetric(icon: "thermometer.medium", value: battery.temperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" } ?? "—")
                            BatteryTinyMetric(icon: "clock", value: remainingTimeText)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 218, alignment: .topLeading)
        }
        .frame(height: 250)
    }

    private var statusText: String {
        if !battery.isPresent { return "Not present" }
        if battery.isCharging { return "Charging" }
        if battery.isFullyCharged { return "Fully charged" }
        return battery.isExternalPowerConnected ? "On AC power" : "On battery"
    }

    private var cycleText: String {
        guard let cycles = battery.cycleCount else { return "Unavailable" }
        guard let design = battery.designCycleCount else { return "\(cycles.formatted()) cycles" }
        return "\(cycles.formatted()) / \(design.formatted())"
    }

    private var remainingTimeText: String {
        if battery.isCharging, let minutes = battery.timeToFullMinutes { return compactDuration(minutes) }
        if let minutes = battery.timeToEmptyMinutes { return compactDuration(minutes) }
        return battery.isFullyCharged ? "Full" : "—"
    }
}

private struct BatteryLevelRow: View {
    let title: String
    let value: String
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.medium).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.12))
                    if let fraction {
                        Capsule().fill(tint.gradient)
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                            .animation(.smooth(duration: 0.5), value: fraction)
                    }
                }
            }
            .frame(height: 6)
        }
    }
}

private struct BatteryTinyMetric: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PowerFlowGraphic: View {
    let snapshot: SystemSnapshot

    private var battery: BatterySnapshot { snapshot.battery }
    private var availability: DataAvailability {
        let hasPublicPower = battery.systemPowerWatts != nil || battery.batteryPowerWatts != nil
        let hasDeepPower = snapshot.deep.cpuPowerWatts != nil || snapshot.deep.gpuPowerWatts != nil || snapshot.deep.anePowerWatts != nil
        if hasPublicPower && hasDeepPower && snapshot.deep.availability == .available { return .available }
        if hasPublicPower || hasDeepPower { return .degraded }
        return snapshot.deep.availability
    }

    private var hasAcceleratorPower: Bool {
        let capabilities = snapshot.acceleratorCapabilities
        return (capabilities.gpuTelemetryAvailable && snapshot.deep.gpuPowerWatts != nil)
            || (capabilities.aneTelemetryAvailable && snapshot.deep.anePowerWatts != nil)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Live power flow", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                    Spacer()
                    AvailabilityBadge(availability: availability)
                }

                HStack(spacing: 8) {
                    PowerFlowNode(
                        title: battery.isExternalPowerConnected ? "Adapter rating" : "Battery",
                        value: battery.isExternalPowerConnected ? battery.adapterWatts.map { "\($0.formatted(.number.precision(.fractionLength(0)))) W max" } ?? "Rated —" : optionalWatts(battery.batteryPowerWatts),
                        icon: battery.isExternalPowerConnected ? "powerplug.fill" : "battery.75percent",
                        tint: battery.isExternalPowerConnected ? MacScopeTheme.cyan : .green
                    )
                    PowerFlowConnector(active: battery.systemPowerWatts != nil)
                    PowerFlowNode(
                        title: "System power",
                        value: optionalWatts(battery.systemPowerWatts),
                        icon: "desktopcomputer",
                        tint: MacScopeTheme.accent
                    )
                    PowerFlowConnector(active: snapshot.deep.cpuPowerWatts != nil || hasAcceleratorPower)
                    VStack(spacing: 7) {
                        PowerRailRow(title: "CPU", value: snapshot.deep.cpuPowerWatts, icon: "cpu", tint: MacScopeTheme.accent)
                        if snapshot.acceleratorCapabilities.gpuTelemetryAvailable {
                            PowerRailRow(title: "GPU", value: snapshot.deep.gpuPowerWatts, icon: "rectangle.3.group", tint: MacScopeTheme.cyan)
                        }
                        if snapshot.acceleratorCapabilities.aneTelemetryAvailable {
                            PowerRailRow(title: "ANE", value: snapshot.deep.anePowerWatts, icon: "brain.head.profile", tint: .purple)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("Adapter wattage is rated capacity; system power may report input or load depending on the available hardware counter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .frame(height: 218, alignment: .topLeading)
        }
        .frame(height: 250)
    }
}

private struct PowerFlowNode: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint.gradient)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.65)
                .contentTransition(.numericText())
        }
        .padding(9)
        .frame(width: 88, height: 104)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.16), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct PowerFlowConnector: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right.2")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(active ? MacScopeTheme.accent : .secondary)
            .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.45), isActive: active && !reduceMotion)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

private struct PowerRailRow: View {
    let title: String
    let value: Double?
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).font(.caption.weight(.medium))
            Spacer(minLength: 4)
            Text(optionalWatts(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 9)
        .frame(height: 37)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.13), lineWidth: 1) }
    }
}

private enum PowerHistorySeries: String, CaseIterable {
    case system = "System power"
    case battery = "Battery"
    case cpu = "CPU"
    case gpu = "GPU"
    case ane = "ANE"
}

private struct PowerHistoryPoint: Identifiable {
    let timestamp: Date
    let watts: Double
    let series: PowerHistorySeries
    var id: String { "\(series.rawValue)-\(timestamp.timeIntervalSinceReferenceDate)" }
}

private struct PowerHistoryGraphic: View {
    let history: [SystemSnapshot]
    let isRunning: Bool
    let acceleratorCapabilities: AcceleratorCapabilities

    private var points: [PowerHistoryPoint] {
        history.flatMap { snapshot in
            var values: [PowerHistoryPoint] = []
            if let value = snapshot.battery.systemPowerWatts { values.append(.init(timestamp: snapshot.timestamp, watts: value, series: .system)) }
            if let value = snapshot.battery.batteryPowerWatts { values.append(.init(timestamp: snapshot.timestamp, watts: value, series: .battery)) }
            if let value = snapshot.deep.cpuPowerWatts { values.append(.init(timestamp: snapshot.timestamp, watts: value, series: .cpu)) }
            if acceleratorCapabilities.gpuTelemetryAvailable, let value = snapshot.deep.gpuPowerWatts {
                values.append(.init(timestamp: snapshot.timestamp, watts: value, series: .gpu))
            }
            if acceleratorCapabilities.aneTelemetryAvailable, let value = snapshot.deep.anePowerWatts {
                values.append(.init(timestamp: snapshot.timestamp, watts: value, series: .ane))
            }
            return values
        }
    }

    private var systemPoints: [PowerHistoryPoint] { points.filter { $0.series == .system } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Power draw history").font(.headline)
                        Text("Live rail estimates over \(historyDuration) this session")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(isRunning ? "Live" : "Paused", systemImage: isRunning ? "waveform.path.ecg" : "pause.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isRunning ? .green : .secondary)
                }

                if points.isEmpty {
                    ContentUnavailableView("Power history unavailable", systemImage: "bolt.slash", description: Text("Deep telemetry and battery power counters have not reported samples yet."))
                        .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Chart {
                        ForEach(systemPoints) { point in
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Watts", point.watts))
                                .foregroundStyle(LinearGradient(colors: [MacScopeTheme.accent.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.linear)
                        }
                        ForEach(points) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Watts", point.watts),
                                series: .value("Source", point.series.rawValue)
                            )
                            .foregroundStyle(by: .value("Source", point.series.rawValue))
                            .lineStyle(.init(lineWidth: point.series == .system ? 2.4 : 1.6, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(point.series == .cpu || point.series == .gpu || point.series == .ane ? .stepEnd : .linear)
                        }
                    }
                    .chartForegroundStyleScale([
                        PowerHistorySeries.system.rawValue: MacScopeTheme.accent,
                        PowerHistorySeries.battery.rawValue: .green,
                        PowerHistorySeries.cpu.rawValue: .orange,
                        PowerHistorySeries.gpu.rawValue: MacScopeTheme.cyan,
                        PowerHistorySeries.ane.rawValue: .purple
                    ])
                    .chartYScale(domain: .automatic(includesZero: true))
                    .chartYAxisLabel("Watts")
                    .chartXAxis(.hidden)
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                    .chartPlotStyle { plotArea in plotArea.clipped() }
                    .frame(height: 225)
                    .accessibilityLabel("Power draw history in watts")
                }
            }
        }
    }

    private var historyDuration: String {
        guard let first = points.map(\.timestamp).min(), let last = points.map(\.timestamp).max() else { return "a few seconds" }
        let seconds = max(Int(last.timeIntervalSince(first)), 0)
        if seconds < 60 {
            let displayedSeconds = max(seconds, 1)
            return "\(displayedSeconds) second\(displayedSeconds == 1 ? "" : "s")"
        }
        return "\(seconds / 60) minutes"
    }
}

private enum BatteryTrendSeries: String { case charge = "Charge", health = "Health" }

private struct BatteryTrendPoint: Identifiable {
    let timestamp: Date
    let value: Double
    let series: BatteryTrendSeries
    var id: String { "\(series.rawValue)-\(timestamp.timeIntervalSinceReferenceDate)" }
}

private struct BatteryTemperaturePoint: Identifiable {
    let timestamp: Date
    let value: Double
    var id: Date { timestamp }
}

private struct BatteryHistoryGraphic: View {
    let history: [SystemSnapshot]

    private var percentPoints: [BatteryTrendPoint] {
        history.flatMap { snapshot in
            var values: [BatteryTrendPoint] = []
            if let value = snapshot.battery.chargePercent { values.append(.init(timestamp: snapshot.timestamp, value: value, series: .charge)) }
            if let value = snapshot.battery.healthPercent { values.append(.init(timestamp: snapshot.timestamp, value: value, series: .health)) }
            return values
        }
    }

    private var temperaturePoints: [BatteryTemperaturePoint] {
        history.compactMap { snapshot in
            snapshot.battery.temperatureCelsius.map { .init(timestamp: snapshot.timestamp, value: $0) }
        }
    }

    private var temperatureDomain: ClosedRange<Double> {
        guard let minimum = temperaturePoints.map(\.value).min(),
              let maximum = temperaturePoints.map(\.value).max() else { return 0...100 }
        let lower = floor(minimum - 2)
        let upper = max(ceil(maximum + 2), lower + 4)
        return lower...upper
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Battery trends").font(.headline)
                    Spacer()
                    Text("Charge, capacity health, and temperature").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Charge & health", systemImage: "battery.75percent").font(.subheadline.weight(.medium))
                        Chart(percentPoints) { point in
                            if point.series == .charge {
                                AreaMark(x: .value("Time", point.timestamp), y: .value("Percent", point.value))
                                    .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.linear)
                            }
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Percent", point.value),
                                series: .value("Metric", point.series.rawValue)
                            )
                            .foregroundStyle(by: .value("Metric", point.series.rawValue))
                            .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                        }
                        .chartForegroundStyleScale([BatteryTrendSeries.charge.rawValue: .green, BatteryTrendSeries.health.rawValue: MacScopeTheme.accent])
                        .chartYScale(domain: 0...100)
                        .chartYAxisLabel("Percent")
                        .chartXAxis(.hidden)
                        .chartLegend(position: .bottom, alignment: .leading)
                        .chartPlotStyle { plotArea in plotArea.clipped() }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Temperature", systemImage: "thermometer.medium").font(.subheadline.weight(.medium))
                        if temperaturePoints.isEmpty {
                            ContentUnavailableView("Unavailable", systemImage: "thermometer.medium.slash")
                        } else {
                            Chart(temperaturePoints) { point in
                                LineMark(x: .value("Time", point.timestamp), y: .value("Temperature", point.value))
                                    .foregroundStyle(.orange)
                                    .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.linear)
                            }
                            .chartYScale(domain: temperatureDomain)
                            .chartYAxisLabel("°C")
                            .chartXAxis(.hidden)
                            .chartPlotStyle { plotArea in plotArea.clipped() }
                            .clipped()
                        }
                    }
                }
                .frame(height: 205)
            }
        }
    }
}

@MainActor private func compactDuration(_ minutes: Int) -> String {
    guard minutes >= 0 else { return "—" }
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours > 0 { return "\(hours)h \(remainder)m" }
    return "\(remainder)m"
}

@MainActor private func percent(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...1))))%" }
@MainActor private func optionalPercent(_ value: Double?) -> String { value.map(percent) ?? "Unavailable" }
@MainActor private func optionalMHz(_ value: Double?) -> String { value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) MHz" } ?? "Unavailable" }
@MainActor private func optionalWatts(_ value: Double?) -> String { value.map { "\($0.formatted(.number.precision(.fractionLength(1...2)))) W" } ?? "Unavailable" }
@MainActor private func rate(_ value: Double) -> String { "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary))/s" }
@MainActor private func gibibytes(_ value: UInt64) -> Double { Double(value) / 1_073_741_824 }
