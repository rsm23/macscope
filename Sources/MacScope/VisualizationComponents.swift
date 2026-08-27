import Charts
import MacScopeCore
import SwiftUI

struct MetricPoint: Identifiable, Hashable {
    let timestamp: Date
    let value: Double?
    let ordinal: Int

    init(timestamp: Date, value: Double?, ordinal: Int = 0) {
        self.timestamp = timestamp
        self.value = value
        self.ordinal = ordinal
    }

    var id: String { "\(timestamp.timeIntervalSinceReferenceDate)-\(ordinal)" }
}

enum MetricInterpolation: Sendable {
    case linear
    case stepEnd
}

struct MetricSeries: Identifiable {
    let id: String
    let title: String
    let unit: String
    let tint: Color
    let points: [MetricPoint]
    var availability: DataAvailability = .available
    var quality: MetricQuality = .measured
    var interpolation: MetricInterpolation = .linear

    init(
        id: String,
        title: String,
        unit: String,
        tint: Color,
        points: [MetricPoint],
        interpolation: MetricInterpolation = .linear,
        availability: DataAvailability = .available,
        quality: MetricQuality = .measured
    ) {
        self.id = id
        self.title = title
        self.unit = unit
        self.tint = tint
        self.points = points
        self.availability = availability
        self.quality = quality
        self.interpolation = interpolation
    }

    init(
        id: String,
        title: String,
        unit: String,
        tint: Color,
        points: [MetricPoint],
        availability: DataAvailability,
        quality: MetricQuality,
        interpolation: MetricInterpolation
    ) {
        self.init(
            id: id,
            title: title,
            unit: unit,
            tint: tint,
            points: points,
            interpolation: interpolation,
            availability: availability,
            quality: quality
        )
    }
}

struct DistributionSegment: Identifiable {
    let id: String
    let label: String
    let value: Double?
    let formattedValue: String
    let tint: Color
    var availability: DataAvailability = .available

    init(
        id: String,
        label: String,
        value: Double?,
        formattedValue: String? = nil,
        tint: Color,
        availability: DataAvailability = .available
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.formattedValue = formattedValue ?? value?.formatted(.number.precision(.fractionLength(0...1))) ?? "Unavailable"
        self.tint = tint
        self.availability = availability
    }
}

struct RankedMetric: Identifiable {
    let id: String
    let label: String
    let value: Double
    let formattedValue: String
    let tint: Color
    var availability: DataAvailability = .available

    init(
        id: String,
        label: String,
        value: Double,
        formattedValue: String? = nil,
        tint: Color,
        availability: DataAvailability = .available
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.formattedValue = formattedValue ?? value.formatted(.number.precision(.fractionLength(0...1)))
        self.tint = tint
        self.availability = availability
    }

    init(
        id: String,
        title: String,
        value: Double,
        formattedValue: String? = nil,
        tint: Color,
        availability: DataAvailability = .available
    ) {
        self.init(id: id, label: title, value: value, formattedValue: formattedValue, tint: tint, availability: availability)
    }
}

struct VisualPanel<Content: View>: View {
    private static var cardVerticalInsets: CGFloat { 32 }
    private static var headerHeight: CGFloat { 44 }

    let title: String
    let subtitle: String?
    let icon: String
    let availability: DataAvailability?
    let minHeight: CGFloat
    let height: CGFloat?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        icon: String = "chart.xyaxis.line",
        availability: DataAvailability? = nil,
        minHeight: CGFloat = 0,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.availability = availability
        self.minHeight = minHeight
        self.height = height
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if let height {
            panel
                .frame(height: height, alignment: .topLeading)
        } else {
            panel
        }
    }

    private var panel: some View {
        Card {
            panelContents
        }
    }

    @ViewBuilder
    private var panelContents: some View {
        if let height {
            panelStack
                .frame(
                    height: max(height - Self.cardVerticalInsets, 0),
                    alignment: .topLeading
                )
        } else {
            panelStack
                .frame(minHeight: minHeight, alignment: .topLeading)
        }
    }

    private var panelStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(subtitle)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.headerHeight,
                    maxHeight: Self.headerHeight,
                    alignment: .topLeading
                )
                if let availability {
                    AvailabilityBadge(availability: availability)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct MetricRing: View {
    let title: String
    let value: Double?
    let range: ClosedRange<Double>
    let valueText: String
    let unit: String
    let icon: String
    let tint: Color
    var availability: DataAvailability = .available
    var diameter: CGFloat = 90

    init(
        title: String,
        value: Double?,
        range: ClosedRange<Double>,
        valueText: String,
        unit: String,
        icon: String,
        tint: Color,
        availability: DataAvailability = .available,
        diameter: CGFloat = 90
    ) {
        self.title = title
        self.value = value
        self.range = range
        self.valueText = valueText
        self.unit = unit
        self.icon = icon
        self.tint = tint
        self.availability = availability
        self.diameter = diameter
    }

    init(
        title: String,
        value: String,
        unit: String,
        fraction: Double?,
        tint: Color,
        icon: String,
        availability: DataAvailability = .available,
        diameter: CGFloat = 90
    ) {
        self.init(
            title: title,
            value: fraction,
            range: 0...1,
            valueText: value,
            unit: unit,
            icon: icon,
            tint: tint,
            availability: availability,
            diameter: diameter
        )
    }

    private var fraction: Double? {
        guard let value, value.isFinite, range.upperBound > range.lowerBound else { return nil }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
    private var clampedFraction: Double { fraction ?? 0 }
    private var iconColor: Color { fraction == nil ? .secondary : tint }
    private var gaugeTint: Color { fraction == nil ? Color.secondary.opacity(0.3) : tint }

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: clampedFraction, in: 0...1) {
                Text(title)
            } currentValueLabel: {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(gaugeTint)
            .frame(width: diameter, height: diameter)

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(valueText)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: diameter + 56)
        .background(tint.opacity(fraction == nil ? 0.025 : 0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(fraction == nil ? 0.06 : 0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(fraction == nil ? "unavailable" : valueText + (unit.isEmpty ? "" : " " + unit))")
    }
}

struct MetricSparkline: View {
    let points: [MetricPoint]
    let tint: Color
    let domain: ClosedRange<Double>?
    let interpolation: MetricInterpolation
    let includesZero: Bool
    let height: CGFloat
    let accessibilityText: String

    private var validPoints: [MetricPoint] { points.filter { $0.value != nil } }

    init(
        points: [MetricPoint],
        tint: Color,
        domain: ClosedRange<Double>? = nil,
        interpolation: MetricInterpolation = .linear,
        includesZero: Bool = false,
        height: CGFloat = 44,
        accessibilityLabel: String = "Metric trend"
    ) {
        self.points = points
        self.tint = tint
        self.domain = domain
        self.interpolation = interpolation
        self.includesZero = includesZero
        self.height = height
        self.accessibilityText = accessibilityLabel
    }

    init(
        series: MetricSeries,
        domain: ClosedRange<Double>? = nil,
        includesZero: Bool = false,
        height: CGFloat = 44,
        accessibilityLabel: String? = nil
    ) {
        self.points = series.points
        self.tint = series.tint
        self.domain = domain
        self.interpolation = series.interpolation
        self.includesZero = includesZero
        self.height = height
        self.accessibilityText = accessibilityLabel ?? "\(series.title) trend"
    }

    var body: some View {
        Group {
            if validPoints.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                    Text("No samples")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(validPoints) { point in
                    if interpolation == .stepEnd {
                        if let value = point.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Value", value))
                                .foregroundStyle(tint)
                                .lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.stepEnd)
                        }
                    } else {
                        if let value = point.value {
                            LineMark(x: .value("Time", point.timestamp), y: .value("Value", value))
                                .foregroundStyle(tint)
                                .lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.linear)
                        }
                    }
                }
                .chartYScale(domain: resolvedDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .clipped()
                .accessibilityLabel("\(accessibilityText), \(validPoints.count) samples")
            }
        }
        .frame(height: height)
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let domain { return domain }
        let values = validPoints.compactMap(\.value)
        guard var minimum = values.min(), var maximum = values.max() else { return 0...1 }
        if includesZero {
            minimum = min(minimum, 0)
            maximum = max(maximum, 0)
        }
        let padding = max((maximum - minimum) * 0.12, max(abs(maximum), 1) * 0.04)
        if includesZero && minimum == 0 { return 0...max(maximum + padding, 1) }
        return (minimum - padding)...(maximum + padding)
    }
}

struct MetricTrendChart: View {
    let series: [MetricSeries]
    let unit: String
    var domain: ClosedRange<Double>? = nil
    var includesZero = false
    var height: CGFloat = 210
    var showsLegend = true

    init(
        series: [MetricSeries],
        domain: ClosedRange<Double>? = nil,
        includesZero: Bool = false,
        height: CGFloat = 210,
        showsLegend: Bool = true
    ) {
        self.series = series
        self.unit = series.first?.unit ?? "Value"
        self.domain = domain
        self.includesZero = includesZero
        self.height = height
        self.showsLegend = showsLegend
    }

    init(
        series: [MetricSeries],
        unit: String,
        domain: ClosedRange<Double>? = nil,
        includesZero: Bool = false,
        height: CGFloat = 210,
        showsLegend: Bool = true
    ) {
        self.series = series
        self.unit = unit
        self.domain = domain
        self.includesZero = includesZero
        self.height = height
        self.showsLegend = showsLegend
    }

    private var visibleSeries: [MetricSeries] {
        series.filter { metric in
            metric.availability != .unsupported && metric.points.contains { $0.value != nil }
        }
    }

    var body: some View {
        if visibleSeries.isEmpty {
            ChartEmptyState(title: "No chart samples", icon: "chart.xyaxis.line")
                .frame(height: height)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Chart {
                    ForEach(visibleSeries) { metric in
                        ForEach(metric.points) { point in
                            if metric.interpolation == .stepEnd {
                                if let value = point.value {
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value(metric.unit, value),
                                        series: .value("Series", metric.id)
                                    )
                                    .foregroundStyle(metric.tint)
                                    .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.stepEnd)
                                }
                            } else {
                                if let value = point.value {
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value(metric.unit, value),
                                        series: .value("Series", metric.id)
                                    )
                                    .foregroundStyle(metric.tint)
                                    .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.linear)
                                }
                            }
                        }
                    }
                }
                .chartYScale(domain: resolvedDomain)
                .chartYAxisLabel(unit)
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .clipped()
                .frame(height: chartHeight)
                .accessibilityLabel("\(unit) trend with \(visibleSeries.count) series")

                if showsLegend {
                    MetricLegend(series: visibleSeries)
                }
            }
            .frame(height: height, alignment: .topLeading)
        }
    }

    private var chartHeight: CGFloat {
        showsLegend ? max(height - 22, 1) : height
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let domain { return domain }
        let values = visibleSeries.flatMap { $0.points.compactMap(\.value) }
        guard var minimum = values.min(), var maximum = values.max() else { return 0...1 }
        if includesZero {
            minimum = min(0, minimum)
            maximum = max(0, maximum)
        }
        let padding = max((maximum - minimum) * 0.1, max(abs(maximum), 1) * 0.035)
        if includesZero && minimum == 0 {
            return 0...max(maximum + padding, 1)
        }
        return (minimum - padding)...(maximum + padding)
    }
}

private struct MetricLegend: View {
    let series: [MetricSeries]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(series) { metric in
                HStack(spacing: 5) {
                    Capsule().fill(metric.tint).frame(width: 12, height: 3)
                    Text(metric.title).font(.caption2).foregroundStyle(.secondary)
                    if metric.quality != .measured {
                        Text(metric.quality.rawValue.capitalized)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .lineLimit(1)
    }
}

struct MetricDistributionBar: View {
    let segments: [DistributionSegment]
    var height: CGFloat = 10
    var showsLegend = true

    private var positiveSegments: [DistributionSegment] { segments.filter { ($0.value ?? 0) > 0 } }
    private var total: Double { positiveSegments.reduce(0) { $0 + ($1.value ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let gap = CGFloat(max(positiveSegments.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(positiveSegments) { segment in
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .fill(segment.tint.gradient)
                            .frame(width: max((proxy.size.width - gap) * (segment.value ?? 0) / max(total, 1), 2))
                    }
                }
            }
            .frame(height: height)
            .background(.secondary.opacity(0.11), in: Capsule())

            if showsLegend {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(segments) { segment in
                        HStack(spacing: 6) {
                            Circle().fill(segment.tint).frame(width: 6, height: 6)
                            Text(segment.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(segment.formattedValue)
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RankedMetricBars: View {
    let items: [RankedMetric]
    let unit: String
    var maximumCount = 6
    var height: CGFloat = 150
    private let rowHeight: CGFloat?
    private let showsAxis: Bool

    init(items: [RankedMetric], unit: String, maximumCount: Int = 6, height: CGFloat = 150) {
        self.items = items
        self.unit = unit
        self.maximumCount = maximumCount
        self.height = height
        self.rowHeight = nil
        self.showsAxis = true
    }

    init(metrics: [RankedMetric], limit: Int = 6, rowHeight: CGFloat = 24, showsAxis: Bool = false) {
        self.items = metrics
        self.unit = "Value"
        self.maximumCount = limit
        self.height = CGFloat(max(min(limit, metrics.count), 1)) * rowHeight
        self.rowHeight = rowHeight
        self.showsAxis = showsAxis
    }

    private var visibleItems: [RankedMetric] { Array(items.prefix(maximumCount)) }

    var body: some View {
        if visibleItems.isEmpty {
            ChartEmptyState(title: "No ranked values", icon: "chart.bar.xaxis")
                .frame(height: height)
        } else {
            Chart(visibleItems) { item in
                BarMark(
                    x: .value(unit, item.value),
                    y: .value("Item", item.label)
                )
                .foregroundStyle(item.tint.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading, spacing: 5) {
                    Text(item.formattedValue)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: .automatic(includesZero: true))
            .chartXAxis(showsAxis ? .visible : .hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel().font(.caption2)
                }
            }
            .clipped()
            .frame(height: height)
            .accessibilityLabel("Top \(visibleItems.count) items by \(unit)")
        }
    }
}

struct StatusComposition: View {
    let segments: [DistributionSegment]
    var centerTitle: String
    var centerValue: String

    private var positiveSegments: [DistributionSegment] { segments.filter { ($0.value ?? 0) > 0 } }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                if positiveSegments.isEmpty {
                    Circle().stroke(.secondary.opacity(0.12), lineWidth: 13)
                } else {
                    Chart(positiveSegments) { segment in
                        SectorMark(
                            angle: .value("Count", segment.value ?? 0),
                            innerRadius: .ratio(0.7),
                            angularInset: 1.2
                        )
                        .foregroundStyle(segment.tint)
                        .cornerRadius(2)
                    }
                    .chartLegend(.hidden)
                }
                VStack(spacing: 1) {
                    Text(centerValue)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(centerTitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments.prefix(7)) { segment in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(segment.tint).frame(width: 9, height: 9)
                        Text(segment.label).font(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(segment.formattedValue)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChartEmptyState: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
