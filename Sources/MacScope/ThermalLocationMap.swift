import MacScopeCore
import SwiftUI

struct ThermalLocationMap: View {
    let sensors: [String: Double]
    let fanSpeeds: [String: Double]

    @State private var selectedSensorKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let schematicHeight: CGFloat = 246
    private let footerHeight: CGFloat = 96

    var body: some View {
        let snapshot = ThermalMapSnapshot(sensors: sensors, fanSpeeds: fanSpeeds)
        let selectedReading = snapshot.selectedReading(for: selectedSensorKey)

        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Thermal location map", systemImage: "laptopcomputer")
                            .font(.headline)
                        Text("Conservative component regions · schematic positions are approximate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("\(snapshot.readings.count.formatted()) live")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.readings.isEmpty ? .secondary : MacScopeTheme.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (snapshot.readings.isEmpty ? Color.secondary : MacScopeTheme.cyan).opacity(0.11),
                            in: Capsule()
                        )
                }
                .frame(height: 42, alignment: .topLeading)

                GeometryReader { proxy in
                    let markerWidth = min(max(proxy.size.width * 0.145, 104), 128)

                    ZStack {
                        ThermalMacBookSchematic()
                            .accessibilityHidden(true)

                        ForEach(snapshot.regionSummaries) { summary in
                            let normalizedPosition = markerPosition(for: summary.region)
                            ThermalRegionMarker(
                                summary: summary,
                                width: markerWidth,
                                isSelected: selectedReading?.placement.region == summary.region
                            ) {
                                selectedSensorKey = summary.hottest.key
                            }
                            .position(
                                x: proxy.size.width * normalizedPosition.x,
                                y: proxy.size.height * normalizedPosition.y
                            )
                        }

                        if snapshot.fans.isEmpty {
                            Label("Fan RPM not reported", systemImage: "fan")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.92)
                                .accessibilityLabel("Fan speed and location telemetry are not available")
                        } else {
                            ForEach(Array(snapshot.fans.prefix(3).enumerated()), id: \.element.id) { index, fan in
                                ThermalFanMarker(fan: fan, reduceMotion: reduceMotion)
                                    .position(
                                        x: fanPosition(index: index, count: min(snapshot.fans.count, 3)) * proxy.size.width,
                                        y: proxy.size.height * 0.53
                                    )
                            }
                        }
                    }
                }
                .frame(height: schematicHeight)
                .background(.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator.opacity(0.35), lineWidth: 1)
                }

                HStack(alignment: .top, spacing: 12) {
                    ThermalSelectedSensor(reading: selectedReading)
                        .frame(maxWidth: .infinity, minHeight: footerHeight, maxHeight: footerHeight, alignment: .topLeading)

                    ThermalAmbiguousTray(
                        readings: snapshot.ambiguousReadings,
                        selectedKey: selectedReading?.key,
                        select: { selectedSensorKey = $0 }
                    )
                    .frame(maxWidth: .infinity, minHeight: footerHeight, maxHeight: footerHeight, alignment: .topLeading)
                }
            }
            .frame(height: 420, alignment: .topLeading)
        }
        .frame(height: 452)
    }

    private func markerPosition(for region: ThermalHardwareRegion) -> CGPoint {
        switch region {
        case .display: CGPoint(x: 0.5, y: 0.14)
        case .wirelessIO: CGPoint(x: 0.16, y: 0.34)
        case .processor: CGPoint(x: 0.37, y: 0.37)
        case .memory: CGPoint(x: 0.61, y: 0.37)
        case .powerDelivery: CGPoint(x: 0.84, y: 0.35)
        case .storage: CGPoint(x: 0.17, y: 0.72)
        case .battery: CGPoint(x: 0.5, y: 0.72)
        case .enclosure: CGPoint(x: 0.83, y: 0.72)
        case .unknown: CGPoint(x: 0.5, y: 0.9)
        }
    }

    private func fanPosition(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 0.5 }
        return 0.27 + (0.46 * CGFloat(index) / CGFloat(count - 1))
    }
}

private struct ThermalMapSnapshot {
    let readings: [ThermalMapReading]
    let regionSummaries: [ThermalRegionSummary]
    let ambiguousReadings: [ThermalMapReading]
    let fans: [ThermalFanReading]

    init(sensors: [String: Double], fanSpeeds: [String: Double]) {
        let readings = sensors.compactMap { key, value -> ThermalMapReading? in
            guard value.isFinite else { return nil }
            return ThermalMapReading(
                key: key,
                temperature: value,
                placement: ThermalSensorPlacement.classify(key: key)
            )
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        var readingsByRegion: [ThermalHardwareRegion: [ThermalMapReading]] = [:]
        for reading in readings where reading.placement.region != .unknown {
            readingsByRegion[reading.placement.region, default: []].append(reading)
        }

        self.readings = readings
        self.regionSummaries = ThermalHardwareRegion.allCases.compactMap { region in
            guard region != .unknown,
                  let regionReadings = readingsByRegion[region],
                  let hottest = regionReadings.max(by: { $0.temperature < $1.temperature }) else { return nil }
            return ThermalRegionSummary(region: region, hottest: hottest, sensorCount: regionReadings.count)
        }
        self.ambiguousReadings = readings.filter {
            $0.placement.confidence == .contextual || $0.placement.confidence == .unknown
        }
        self.fans = fanSpeeds.compactMap { key, value -> ThermalFanReading? in
            guard value.isFinite, value >= 0 else { return nil }
            return ThermalFanReading(key: key, rpm: value)
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    func selectedReading(for key: String?) -> ThermalMapReading? {
        if let key, let selected = readings.first(where: { $0.key == key }) {
            return selected
        }
        // Prefer a reading that can actually be highlighted on the schematic. Broad and
        // unmapped keys remain available in the tray, but should not leave every map marker
        // looking unselected on first display.
        return readings
            .filter { $0.placement.region != .unknown }
            .max(by: { $0.temperature < $1.temperature })
            ?? readings.max(by: { $0.temperature < $1.temperature })
    }
}

private struct ThermalMapReading: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let temperature: Double
    let placement: ThermalSensorPlacement

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

private struct ThermalRegionSummary: Identifiable {
    var id: ThermalHardwareRegion { region }
    let region: ThermalHardwareRegion
    let hottest: ThermalMapReading
    let sensorCount: Int

    var icon: String {
        switch region {
        case .processor: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .powerDelivery: "bolt.fill"
        case .wirelessIO: "antenna.radiowaves.left.and.right"
        case .display: "display"
        case .enclosure: "laptopcomputer"
        case .unknown: "questionmark.diamond"
        }
    }
}

private struct ThermalFanReading: Identifiable {
    var id: String { key }
    let key: String
    let rpm: Double
}

private struct ThermalRegionMarker: View {
    let summary: ThermalRegionSummary
    let width: CGFloat
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: summary.icon)
                        .foregroundStyle(summary.hottest.tint)
                    Text(summary.region.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(summary.sensorCount.formatted())
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(summary.hottest.formattedTemperature)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .background(isSelected ? summary.hottest.tint.opacity(0.12) : Color.clear)
            .macScopeGlassSurface(cornerRadius: 9)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(summary.hottest.tint.opacity(isSelected ? 0.55 : 0.18), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hottest of \(summary.sensorCount) \(summary.region.title.lowercased()) sensor readings")
        .accessibilityLabel(
            "\(summary.region.title), hottest temperature \(summary.hottest.formattedTemperature), \(summary.sensorCount) sensors. Show sensor details"
        )
    }
}

private struct ThermalFanMarker: View {
    let fan: ThermalFanReading
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion || fan.rpm < 1)) { timeline in
                let rotationsPerSecond = min(max(fan.rpm / 3_600, 0.1), 1.2)
                let angle = timeline.date.timeIntervalSinceReferenceDate * rotationsPerSecond * 360
                Image(systemName: "fan.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(MacScopeTheme.cyan.gradient)
                    .rotationEffect(.degrees(reduceMotion ? 0 : angle))
            }
            .frame(width: 34, height: 34)
            Text("\(fan.rpm.formatted(.number.precision(.fractionLength(0)))) RPM")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fan.key), \(fan.rpm.formatted(.number.precision(.fractionLength(0)))) revolutions per minute, schematic location approximate")
    }
}

private struct ThermalSelectedSensor: View {
    let reading: ThermalMapReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected reading")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reading {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reading.key)
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(reading.formattedTemperature)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(reading.tint)
                }
                Text("\(reading.placement.region.title) · \(confidenceTitle(reading.placement.confidence)) · \(reading.placement.basis)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(reading.placement.basis)
            } else {
                Label("Waiting for thermal sensor data", systemImage: "thermometer.medium.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func confidenceTitle(_ confidence: ThermalPlacementConfidence) -> String {
        switch confidence {
        case .exactName: "Exact component name"
        case .knownFamily: "Known sensor family"
        case .contextual: "Broad location only"
        case .unknown: "Unmapped"
        }
    }
}

private struct ThermalAmbiguousTray: View {
    let readings: [ThermalMapReading]
    let selectedKey: String?
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Broad or unmapped")
                    .font(.caption.weight(.semibold))
                Text(readings.count.formatted())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if readings.isEmpty {
                Label("No ambiguous live keys", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(readings) { reading in
                            Button {
                                select(reading.key)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(reading.key)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Text(reading.formattedTemperature)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(reading.tint)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(
                                    selectedKey == reading.key ? reading.tint.opacity(0.12) : Color.secondary.opacity(0.065),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(reading.tint.opacity(selectedKey == reading.key ? 0.45 : 0.12), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(reading.placement.basis)
                            .accessibilityLabel("\(reading.key), \(reading.formattedTemperature), \(reading.placement.region.title). Show sensor details")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct ThermalMacBookSchematic: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.secondary.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.secondary.opacity(0.16), lineWidth: 1)
                    }
                    .frame(width: width * 0.52, height: height * 0.25)
                    .position(x: width * 0.5, y: height * 0.15)

                Capsule()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: width * 0.3, height: 3)
                    .position(x: width * 0.5, y: height * 0.29)

                ThermalDeckShape()
                    .fill(.secondary.opacity(0.045))
                    .overlay {
                        ThermalDeckShape()
                            .stroke(.secondary.opacity(0.18), lineWidth: 1)
                    }
                    .padding(.horizontal, width * 0.055)
                    .padding(.top, height * 0.27)
                    .padding(.bottom, height * 0.055)

                // These low-contrast component silhouettes make the marker positions readable
                // as an interior map without claiming model-specific board geometry.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MacScopeTheme.accent.opacity(0.09), lineWidth: 1)
                    }
                    .frame(width: width * 0.56, height: height * 0.18)
                    .position(x: width * 0.5, y: height * 0.41)

                HStack(spacing: width * 0.025) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.green.opacity(0.022))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.green.opacity(0.07), lineWidth: 1)
                            }
                    }
                }
                .frame(width: width * 0.42, height: height * 0.18)
                .position(x: width * 0.5, y: height * 0.72)

                ForEach([0.22, 0.78], id: \.self) { normalizedX in
                    ZStack {
                        Circle()
                            .fill(.secondary.opacity(0.025))
                        Circle()
                            .stroke(.secondary.opacity(0.09), lineWidth: 1)
                        Image(systemName: "fan")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(.tertiary.opacity(0.55))
                    }
                    .frame(width: min(width * 0.075, 52), height: min(width * 0.075, 52))
                    .position(x: width * normalizedX, y: height * 0.53)
                }

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.secondary.opacity(0.09), lineWidth: 1)
                    .frame(width: width * 0.28, height: height * 0.22)
                    .position(x: width * 0.5, y: height * 0.69)
            }
        }
    }
}

private struct ThermalDeckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.08, y: 0))
        path.addLine(to: CGPoint(x: rect.width * 0.92, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.92),
            control: CGPoint(x: rect.width * 0.98, y: rect.height * 0.42)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.94, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.06, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height * 0.92),
            control: CGPoint(x: 0, y: rect.height)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.08, y: 0),
            control: CGPoint(x: rect.width * 0.02, y: rect.height * 0.42)
        )
        path.closeSubpath()
        return path
    }
}
