import AppKit
import Charts
import MacScopeCore
import SwiftUI

struct MenuBarStatusLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        Label {
            Text("CPU \(menuPercent(presentation.cpuUsage))")
                .monospacedDigit()
        } icon: {
            Image(systemName: "waveform.path.ecg")
        }
        .accessibilityLabel("MacScope, CPU \(menuPercent(presentation.cpuUsage))")
    }
}

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        let dashboard = model.menuBarPresentation

        VStack(alignment: .leading, spacing: 10) {
            header(dashboard)

            HStack(spacing: 8) {
                MenuBarCompactTrend(
                    title: "CPU history",
                    value: menuPercent(dashboard.cpuUsage),
                    points: dashboard.cpuTrend,
                    tint: MacScopeTheme.accent
                )
                MenuBarCompactTrend(
                    title: "Memory history",
                    value: dashboard.memoryPercent.map(menuPercent) ?? "—",
                    points: dashboard.memoryTrend,
                    tint: MacScopeTheme.cyan
                )
            }

            MenuBarThermalPanel(data: dashboard) {
                showMainWindow(section: .thermals)
            }

            MenuBarNetworkPanel(data: dashboard) {
                showMainWindow(section: .network)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    showMainWindow()
                } label: {
                    Label("Open MacScope", systemImage: "rectangle.on.rectangle")
                }
                .macScopeGlassButton(prominent: true)

                Spacer(minLength: 4)

                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Open MacScope Settings")
                .accessibilityLabel("Open MacScope Settings")

                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                    Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(model.isRunning ? "Pause sampling" : "Resume sampling")
                .accessibilityLabel(model.isRunning ? "Pause sampling" : "Resume sampling")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Quit MacScope")
                .accessibilityLabel("Quit MacScope")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 396)
    }

    private func header(_ dashboard: MenuBarPresentation) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.13))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MacScopeTheme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacScope").font(.headline)
                Text("Updated \(dashboard.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                model.isRunning ? "Live" : "Paused",
                systemImage: model.isRunning ? "circle.fill" : "pause.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.isRunning ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "MacScope, \(model.isRunning ? "live sampling" : "sampling paused"), updated \(dashboard.timestamp.formatted(date: .omitted, time: .shortened))"
        )
    }

    private func showMainWindow(section: AppSection? = nil) {
        if let section { model.selectedSection = section }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.canBecomeMain && $0.title != "Settings" })?.makeKeyAndOrderFront(nil)
        }
    }
}

struct MenuBarPresentation {
    let timestamp: Date
    let cpuUsage: Double
    let memoryPercent: Double?
    let memoryDetail: String
    let downloadRate: Double
    let uploadRate: Double
    let thermalPressure: String
    let fanRPM: Double?
    let hottestSensor: MenuBarThermalReading?
    let cpuTrend: [MetricPoint]
    let memoryTrend: [MetricPoint]
    let thermalTrend: [MetricPoint]
    let downloadTrend: [MetricPoint]
    let uploadTrend: [MetricPoint]

    init(snapshot: SystemSnapshot = SystemSnapshot(), history: [SystemSnapshot] = []) {
        timestamp = snapshot.timestamp
        cpuUsage = snapshot.cpuUsage

        if snapshot.memory.total > 0 {
            memoryPercent = min(max(Double(snapshot.memory.used) / Double(snapshot.memory.total) * 100, 0), 100)
            memoryDetail = "\(ByteCountFormatter.macScope(snapshot.memory.used)) of \(ByteCountFormatter.macScope(snapshot.memory.total))"
        } else {
            memoryPercent = nil
            memoryDetail = "Memory counters unavailable"
        }

        downloadRate = snapshot.networks.reduce(0) { $0 + max($1.downloadRate, 0) }
        uploadRate = snapshot.networks.reduce(0) { $0 + max($1.uploadRate, 0) }
        thermalPressure = snapshot.deep.thermalPressure
            ?? snapshot.inventory.details["Thermal State"]
            ?? "Unknown"
        fanRPM = snapshot.deep.fanSpeeds.values
            .filter { $0.isFinite && $0 >= 0 }
            .max()

        let thermalReadings = snapshot.deep.sensors.compactMap { key, value -> MenuBarThermalReading? in
            guard value.isFinite, value > -20, value < 160 else { return nil }
            let placement = ThermalSensorPlacement.classify(key: key)
            return MenuBarThermalReading(key: key, temperature: value, region: placement.region)
        }
        let mappedReadings = thermalReadings.filter { $0.region != .unknown }
        hottestSensor = mappedReadings.max(by: { $0.temperature < $1.temperature })
            ?? thermalReadings.max(by: { $0.temperature < $1.temperature })

        let recent = Self.recentSamples(from: history, endingAt: snapshot.timestamp)
        cpuTrend = recent.map { sample in
            MetricPoint(
                timestamp: sample.timestamp,
                value: min(max(sample.cpuUsage, 0), 100)
            )
        }
        memoryTrend = recent.compactMap { sample in
            guard sample.memory.total > 0 else { return nil }
            return MetricPoint(
                timestamp: sample.timestamp,
                value: min(max(Double(sample.memory.used) / Double(sample.memory.total) * 100, 0), 100)
            )
        }
        if let key = hottestSensor?.key {
            thermalTrend = recent.compactMap { sample in
                guard let value = sample.deep.sensors[key], value.isFinite, value > -20, value < 160 else { return nil }
                return MetricPoint(timestamp: sample.timestamp, value: value)
            }
        } else {
            thermalTrend = []
        }
        downloadTrend = recent.map { sample in
            MetricPoint(
                timestamp: sample.timestamp,
                value: sample.networks.reduce(0) { $0 + max($1.downloadRate, 0) } / 1_048_576,
                ordinal: 0
            )
        }
        uploadTrend = recent.map { sample in
            MetricPoint(
                timestamp: sample.timestamp,
                value: sample.networks.reduce(0) { $0 + max($1.uploadRate, 0) } / 1_048_576,
                ordinal: 1
            )
        }
    }

    private static func recentSamples(from history: [SystemSnapshot], endingAt end: Date) -> [SystemSnapshot] {
        let start = end.addingTimeInterval(-60)
        let window = history.filter { $0.timestamp >= start && $0.timestamp <= end }
        guard window.count > 30 else { return window }

        let strideLength = Double(window.count - 1) / 29
        var result: [SystemSnapshot] = []
        result.reserveCapacity(30)
        for index in 0..<30 {
            let sourceIndex = min(Int((Double(index) * strideLength).rounded()), window.count - 1)
            let sample = window[sourceIndex]
            if result.last?.timestamp != sample.timestamp { result.append(sample) }
        }
        if result.last?.timestamp != window.last?.timestamp, let last = window.last {
            if result.count == 30 { result.removeLast() }
            result.append(last)
        }
        return result
    }
}

struct MenuBarThermalReading {
    let key: String
    let temperature: Double
    let region: ThermalHardwareRegion

    var formattedTemperature: String {
        "\(temperature.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    var tint: Color {
        switch temperature {
        case 90...: MacScopeTheme.critical
        case 75...: MacScopeTheme.warning
        case 60...: .yellow
        default: MacScopeTheme.cyan
        }
    }
}

private struct MenuBarCompactTrend: View {
    let title: String
    let value: String
    let points: [MetricPoint]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.caption2.weight(.semibold).monospacedDigit())
            }
            MetricSparkline(
                points: points,
                tint: tint,
                domain: 0...100,
                interpolation: .linear,
                includesZero: true,
                height: 36,
                accessibilityLabel: title
            )
            .accessibilityHidden(true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62)
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), current value \(value), trailing 60 seconds")
    }
}

private struct MenuBarThermalPanel: View {
    let data: MenuBarPresentation
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Label("Thermals", systemImage: "thermometer.medium")
                    .font(.caption.weight(.semibold))
                MenuBarStatusBadge(text: data.thermalPressure)
                MenuBarStatusBadge(
                    text: data.fanRPM.map {
                        "Fan \($0.formatted(.number.precision(.fractionLength(0)))) RPM"
                    } ?? "Fan unavailable"
                )
                Spacer(minLength: 4)
                Button(action: open) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open Thermals")
                .accessibilityLabel("Open Thermals")
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(data.hottestSensor?.formattedTemperature ?? "Unavailable")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(data.hottestSensor?.tint ?? .secondary)
                Text(data.hottestSensor.map { "\($0.region.title) · \($0.key)" } ?? "No mapped sensor")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            MetricSparkline(
                points: data.thermalTrend,
                tint: data.hottestSensor?.tint ?? MacScopeTheme.cyan,
                interpolation: .linear,
                includesZero: false,
                height: 34,
                accessibilityLabel: "Hottest mapped temperature history"
            )
            .accessibilityHidden(true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
        .macScopeGlassSurface(cornerRadius: 9)
    }
}

private struct MenuBarStatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.08), in: Capsule())
    }
}

private struct MenuBarNetworkPanel: View {
    let data: MenuBarPresentation
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Network traffic", systemImage: "network")
                    .font(.caption.weight(.semibold))
                Text("Sum of reported interfaces")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Virtual interfaces can overlap traffic reported by physical interfaces.")
                Spacer()
                Button(action: open) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open Network")
                .accessibilityLabel("Open Network")
            }

            HStack(spacing: 18) {
                MenuBarDirectionValue(title: "Download", value: menuRate(data.downloadRate), tint: .mint)
                MenuBarDirectionValue(title: "Upload", value: menuRate(data.uploadRate), tint: MacScopeTheme.accent)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Label("Down", systemImage: "circle.fill").foregroundStyle(.mint)
                    Label("Up", systemImage: "circle.fill").foregroundStyle(MacScopeTheme.accent)
                }
                .font(.system(size: 8, weight: .medium))
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Network traffic, download \(menuRate(data.downloadRate)), upload \(menuRate(data.uploadRate)), trailing 60 seconds. Sum of reported interfaces; virtual traffic may overlap."
            )

            MenuBarNetworkTrend(download: data.downloadTrend, upload: data.uploadTrend)
                .accessibilityHidden(true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .macScopeGlassSurface(cornerRadius: 9)
    }
}

private struct MenuBarDirectionValue: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarNetworkTrend: View {
    let download: [MetricPoint]
    let upload: [MetricPoint]

    private var downloadPoints: [MetricPoint] { download.filter { $0.value != nil } }
    private var uploadPoints: [MetricPoint] { upload.filter { $0.value != nil } }

    var body: some View {
        Group {
            if downloadPoints.isEmpty && uploadPoints.isEmpty {
                Text("No network samples")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(downloadPoints) { point in
                        if let value = point.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("MiB/s", value))
                                .foregroundStyle(by: .value("Direction", "Download"))
                                .lineStyle(.init(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.linear)
                        }
                    }
                    ForEach(uploadPoints) { point in
                        if let value = point.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("MiB/s", value))
                                .foregroundStyle(by: .value("Direction", "Upload"))
                                .lineStyle(.init(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.linear)
                        }
                    }
                }
                .chartForegroundStyleScale(["Download": Color.mint, "Upload": MacScopeTheme.accent])
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .clipped()
            }
        }
        .frame(height: 38)
    }
}

private func menuPercent(_ value: Double) -> String {
    guard value.isFinite else { return "Unavailable" }
    return "\(min(max(value, 0), 100).formatted(.number.precision(.fractionLength(0))))%"
}

private func menuRate(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "Unavailable" }
    let bounded = min(value, Double(Int64.max))
    return "\(ByteCountFormatter.string(fromByteCount: Int64(bounded), countStyle: .binary))/s"
}
