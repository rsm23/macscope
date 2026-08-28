import AppKit
import Charts
import MacScopeCore
import SwiftUI

struct MenuBarStatusLabel: View {
    let presentation: MenuBarPresentation
    @AppStorage("menuBarReadoutMetrics") private var storedMetrics = MenuBarReadoutMetric.cpu.rawValue
    @AppStorage("menuBarReadoutStyle") private var storedStyle = MenuBarReadoutStyle.values.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: [MenuBarReadoutMetric] {
        MenuBarReadoutMetric.selected(from: storedMetrics)
    }

    private var fractions: [Double?] {
        metrics.map { $0.fraction(presentation) }
    }

    @ViewBuilder
    var body: some View {
        if (MenuBarReadoutStyle(rawValue: storedStyle) ?? .values) == .bars {
            MenuBarGraphStatusArtwork(metrics: metrics, presentation: presentation)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72),
                    value: fractions
                )
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityLabel(
                    "MacScope, \(metrics.map { $0.accessibilityValue(presentation) }.joined(separator: ", "))"
                )
        } else {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                Text(metrics.map { $0.value(presentation) }.joined(separator: " · "))
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel(
                "MacScope, \(metrics.map { $0.accessibilityValue(presentation) }.joined(separator: ", "))"
            )
        }
    }
}

enum MenuBarUsageGauge {
    static let segmentCount = 7

    static func activeSegmentCount(for fraction: Double) -> Int {
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * Double(segmentCount)).rounded())
    }

    static func displayText(label: String, fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(label) \(Int((clamped * 100).rounded()))%"
    }
}

enum MenuBarNetworkGraph {
    static let width: CGFloat = 46
    static let maximumSampleCount = 24

    static func normalizedSamples(_ values: [Double]) -> [Double] {
        let samples = values.suffix(maximumSampleCount).map { value in
            value.isFinite ? max(value, 0) : 0
        }
        guard let peak = samples.max(), peak > 0 else {
            return Array(repeating: 0, count: samples.count)
        }
        return samples.map { min(max(sqrt($0 / peak), 0), 1) }
    }
}

private struct MenuBarGraphStatusArtwork: View {
    let metrics: [MenuBarReadoutMetric]
    let presentation: MenuBarPresentation

    var body: some View {
        Image(nsImage: artwork)
            .interpolation(.high)
            .contentTransition(.interpolate)
            .fixedSize()
    }

    @MainActor private var artwork: NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let barWidth: CGFloat = 3.5
        let barSpacing: CGFloat = 1.5
        let barGroupWidth = (barWidth * CGFloat(MenuBarUsageGauge.segmentCount))
            + (barSpacing * CGFloat(MenuBarUsageGauge.segmentCount - 1))
        let entries = metrics.map { metric -> (metric: MenuBarReadoutMetric, text: String, fraction: Double?) in
            guard metric.fraction(presentation) != nil else {
                return (metric, metric.value(presentation), nil)
            }
            let fraction = currentFraction(for: metric)
            return (metric, MenuBarUsageGauge.displayText(label: metric.shortName, fraction: fraction), fraction)
        }
        let textSizes = entries.map { $0.text.size(withAttributes: attributes) }
        let entriesWidth = zip(entries, textSizes).reduce(CGFloat.zero) { total, pair in
            let graphWidth: CGFloat
            if pair.0.metric == .network {
                graphWidth = 5 + MenuBarNetworkGraph.width
            } else if pair.0.fraction != nil {
                graphWidth = 5 + barGroupWidth
            } else {
                graphWidth = 0
            }
            return total + ceil(pair.1.width) + graphWidth
        }
        let interEntrySpacing = CGFloat(max(entries.count - 1, 0)) * 7
        let imageSize = NSSize(
            width: 16 + 5 + entriesWidth + interEntrySpacing,
            height: 16
        )

        let image = NSImage(size: imageSize, flipped: false) { _ in
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor]))
            let waveform = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration)
            waveform?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 14))

            let gradient = NSGradient(colors: [
                NSColor(deviceRed: 0.18, green: 0.78, blue: 0.92, alpha: 1),
                NSColor(deviceRed: 0.12, green: 0.58, blue: 0.95, alpha: 1),
                NSColor(deviceRed: 0.95, green: 0.38, blue: 0.93, alpha: 1),
            ])
            var x: CGFloat = 21

            for (entry, textSize) in zip(entries, textSizes) {
                entry.text.draw(
                    at: NSPoint(x: x, y: (imageSize.height - textSize.height) / 2),
                    withAttributes: attributes
                )
                x += ceil(textSize.width)

                if entry.metric == .network {
                    x += 5
                    drawNetworkGraph(
                        in: NSRect(x: x, y: 1, width: MenuBarNetworkGraph.width, height: 14)
                    )
                    x += MenuBarNetworkGraph.width
                } else if let fraction = entry.fraction {
                    x += 5
                    let level = min(max(fraction, 0), 1) * Double(MenuBarUsageGauge.segmentCount)
                    for index in 0..<MenuBarUsageGauge.segmentCount {
                        let rect = NSRect(
                            x: x + (CGFloat(index) * (barWidth + barSpacing)),
                            y: 1,
                            width: barWidth,
                            height: 14
                        )
                        let path = NSBezierPath(
                            roundedRect: rect,
                            xRadius: barWidth / 2,
                            yRadius: barWidth / 2
                        )
                        NSColor.labelColor.withAlphaComponent(0.16).setFill()
                        path.fill()

                        let activation = min(max(level - Double(index), 0), 1)
                        guard activation > 0, let gradient else { continue }
                        NSGraphicsContext.saveGraphicsState()
                        path.addClip()
                        NSGraphicsContext.current?.cgContext.setAlpha(activation)
                        gradient.draw(in: rect, angle: 90)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    x += barGroupWidth
                }
                x += 7
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func currentFraction(for metric: MenuBarReadoutMetric) -> Double {
        metric.fraction(presentation) ?? 0
    }

    @MainActor private func drawNetworkGraph(in rect: NSRect) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        background.fill()
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        background.lineWidth = 0.5
        background.stroke()

        let baselineY = rect.midY
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX + 2, y: baselineY))
        baseline.line(to: NSPoint(x: rect.maxX - 2, y: baselineY))
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        baseline.lineWidth = 0.5
        baseline.stroke()

        let download = networkSamples(
            trend: presentation.downloadTrend,
            currentBytesPerSecond: presentation.downloadRate
        )
        let upload = networkSamples(
            trend: presentation.uploadTrend,
            currentBytesPerSecond: presentation.uploadRate
        )
        drawNetworkSeries(
            MenuBarNetworkGraph.normalizedSamples(download),
            in: rect,
            baselineY: baselineY,
            direction: 1,
            color: NSColor(deviceRed: 0.10, green: 0.76, blue: 1.0, alpha: 1)
        )
        drawNetworkSeries(
            MenuBarNetworkGraph.normalizedSamples(upload),
            in: rect,
            baselineY: baselineY,
            direction: -1,
            color: NSColor(deviceRed: 0.96, green: 0.32, blue: 0.86, alpha: 1)
        )
    }

    private func networkSamples(trend: [MetricPoint], currentBytesPerSecond: Double) -> [Double] {
        var samples = trend.compactMap(\.value)
        let currentMiBPerSecond = max(currentBytesPerSecond, 0) / 1_048_576
        if samples.isEmpty {
            samples = [currentMiBPerSecond, currentMiBPerSecond]
        } else {
            samples.append(currentMiBPerSecond)
        }
        return samples
    }

    @MainActor private func drawNetworkSeries(
        _ samples: [Double],
        in rect: NSRect,
        baselineY: CGFloat,
        direction: CGFloat,
        color: NSColor
    ) {
        guard !samples.isEmpty else { return }
        let values = samples.count == 1 ? [samples[0], samples[0]] : samples
        let horizontalInset: CGFloat = 2
        let amplitude = (rect.height / 2) - 2
        let step = (rect.width - (horizontalInset * 2)) / CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            NSPoint(
                x: rect.minX + horizontalInset + (CGFloat(index) * step),
                y: baselineY + (direction * CGFloat(value) * amplitude)
            )
        }

        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() { line.line(to: point) }
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        let fill = NSBezierPath()
        fill.append(line)
        fill.line(to: NSPoint(x: points.last!.x, y: baselineY))
        fill.line(to: NSPoint(x: points[0].x, y: baselineY))
        fill.close()
        color.withAlphaComponent(0.18).setFill()
        fill.fill()

        color.withAlphaComponent(0.28).setStroke()
        line.lineWidth = 3
        line.stroke()
        color.setStroke()
        line.lineWidth = 1.15
        line.stroke()
    }
}

enum MenuBarReadoutStyle: String, CaseIterable, Identifiable {
    case values = "Values"
    case bars = "Usage bars"
    var id: String { rawValue }
}

enum MenuBarReadoutMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case network = "Network"
    case battery = "Battery"
    case batteryTime = "Battery time"
    case fan = "Fan"

    var id: String { rawValue }
    var shortName: String {
        switch self { case .memory: "MEM"; case .network: "NET"; case .battery: "BAT"; case .batteryTime: "TIME"; default: rawValue.uppercased() }
    }

    static func selected(from stored: String) -> [MenuBarReadoutMetric] {
        let decoded = stored.split(separator: "|").compactMap { MenuBarReadoutMetric(rawValue: String($0)) }
        return decoded.isEmpty ? [.cpu] : Array(decoded.prefix(4))
    }

    func value(_ data: MenuBarPresentation) -> String {
        switch self {
        case .cpu: "CPU \(menuPercent(data.cpuUsage))"
        case .memory: "MEM \(data.memoryPercent.map(menuPercent) ?? "—")"
        case .network: "↓\(compactRate(data.downloadRate)) ↑\(compactRate(data.uploadRate))"
        case .battery: "BAT \(data.batteryPercent.map(menuPercent) ?? "—")"
        case .batteryTime: data.batteryTimeRemaining ?? "TIME —"
        case .fan: data.fanRPM.map { "FAN \(Int($0.rounded()))" } ?? "FAN —"
        }
    }

    func accessibilityValue(_ data: MenuBarPresentation) -> String {
        switch self {
        case .cpu: "CPU \(menuPercent(data.cpuUsage))"
        case .memory: "memory \(data.memoryPercent.map(menuPercent) ?? "unavailable")"
        case .network: "download \(menuRate(data.downloadRate)), upload \(menuRate(data.uploadRate))"
        case .battery: "battery \(data.batteryPercent.map(menuPercent) ?? "unavailable")"
        case .batteryTime: "battery time \(data.batteryTimeRemaining ?? "unavailable")"
        case .fan: "fan \(data.fanRPM.map { "\(Int($0.rounded())) RPM" } ?? "unavailable")"
        }
    }

    func fraction(_ data: MenuBarPresentation) -> Double? {
        switch self {
        case .cpu: min(max(data.cpuUsage / 100, 0), 1)
        case .memory: data.memoryPercent.map { min(max($0 / 100, 0), 1) }
        case .battery: data.batteryPercent.map { min(max($0 / 100, 0), 1) }
        case .network, .batteryTime, .fan: nil
        }
    }

    private func compactRate(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return "\(Int(max(value, 0)))"
    }
}

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    @State private var selectedTab = MenuBarPanelTab.overview
    @AppStorage("menuBarPanelTabOrder") private var storedTabOrder = ""
    @AppStorage("menuBarPanelHiddenTabs") private var storedHiddenTabs = ""
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    private var visibleTabs: [MenuBarPanelTab] {
        MenuBarPanelTab.ordered(from: storedTabOrder).filter { tab in
            let featureAvailable = tab != .windows
                || UtilityFeatureStore.isEnabled(.windows, stored: disabledModules)
            return featureAvailable
                && (tab.isRequired || !MenuBarPanelTab.hidden(from: storedHiddenTabs).contains(tab))
        }
    }

    var body: some View {
        let dashboard = model.menuBarPresentation

        VStack(alignment: .leading, spacing: 10) {
            header(dashboard)

            Picker("Preview", selection: $selectedTab) {
                ForEach(visibleTabs) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .overview:
                    overviewPanel(dashboard)
                case .audio:
                    MenuBarAudioPanel(mixer: model.audioMixer) {
                        showMainWindow(section: .utilities)
                    }
                case .disk:
                    MenuBarDiskPanel(disks: model.snapshot.disks) {
                        showMainWindow(section: .storage)
                    }
                case .windows:
                    MenuBarWindowsPanel()
                case .quick:
                    MenuBarQuickPanel(
                        screenshots: model.screenshots,
                        keepAwake: model.keepAwake,
                        toggles: model.quickToggles
                    ) {
                        showMainWindow(section: .utilities)
                    }
                }
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
        .task { model.audioMixer.start() }
        .onAppear { selectAvailableTab() }
        .onChange(of: storedTabOrder) { _, _ in selectAvailableTab() }
        .onChange(of: storedHiddenTabs) { _, _ in selectAvailableTab() }
        .onChange(of: disabledModules) { _, _ in selectAvailableTab() }
        .onDisappear { model.audioMixer.stop() }
    }

    @ViewBuilder private func overviewPanel(_ dashboard: MenuBarPresentation) -> some View {
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

    private func selectAvailableTab() {
        if !visibleTabs.contains(selectedTab) {
            selectedTab = visibleTabs.first ?? .audio
        }
    }
}

enum MenuBarPanelTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case audio = "Audio"
    case disk = "Disk"
    case windows = "Windows"
    case quick = "Quick"

    var id: String { rawValue }
    var isRequired: Bool { self == .audio || self == .disk }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .audio: "speaker.wave.2"
        case .disk: "internaldrive"
        case .windows: "macwindow.on.rectangle"
        case .quick: "bolt.fill"
        }
    }


    static func ordered(from stored: String) -> [MenuBarPanelTab] {
        var result = stored.split(separator: "|").compactMap { MenuBarPanelTab(rawValue: String($0)) }
        for tab in allCases where !result.contains(tab) { result.append(tab) }
        return result
    }

    static func hidden(from stored: String) -> Set<MenuBarPanelTab> {
        Set(stored.split(separator: "|").compactMap { MenuBarPanelTab(rawValue: String($0)) })
    }
}

private struct MenuBarWindowsPanel: View {
    @State private var service = WindowSwitcherService()
    @AppStorage("workspace.switcherThumbnailPrivacyApps") private var thumbnailPrivacyAppsRaw = ""

    private var privacyExclusions: Set<String> {
        Set(thumbnailPrivacyAppsRaw.split(separator: "|").map(String.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Open windows").font(.headline)
                Spacer()
                Button(service.isLoadingThumbnails ? "Loading…" : "Refresh", systemImage: "arrow.clockwise") {
                    refresh()
                }
                .disabled(service.isLoadingThumbnails)
                .macScopeGlassButton()
            }
            if service.windows.isEmpty {
                ContentUnavailableView(
                    "No switchable windows",
                    systemImage: "macwindow.badge.plus",
                    description: Text("Open another app window, then refresh.")
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(service.windows.prefix(20)) { window in
                            Button {
                                service.activate(window)
                            } label: {
                                HStack(spacing: 10) {
                                    if let thumbnail = service.thumbnails[window.id] {
                                        Image(nsImage: thumbnail)
                                            .resizable().scaledToFill()
                                            .frame(width: 92, height: 54).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        Image(nsImage: window.icon)
                                            .resizable().scaledToFit().frame(width: 32, height: 32)
                                            .frame(width: 92, height: 54)
                                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(window.title).font(.callout.weight(.medium)).lineLimit(1)
                                        Text("\(window.ownerName) · \(window.isOnScreen ? "Visible" : "Minimized")")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            if let status = service.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        service.refresh()
        service.loadThumbnails(excludingBundleIdentifiers: privacyExclusions)
    }
}

private struct MenuBarQuickPanel: View {
    let screenshots: ScreenshotService
    let keepAwake: KeepAwakeService
    let toggles: QuickToggleService
    let openUtilities: () -> Void
    @State private var confirmation: Confirmation?
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    private enum Confirmation: String, Identifiable {
        case emptyTrash
        case ejectVolumes
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions").font(.headline)
            if UtilityFeatureStore.isEnabled(.capture, stored: disabledModules) {
                HStack(spacing: 8) {
                    Button("Full screen", systemImage: "rectangle.inset.filled") {
                        screenshots.capture(.fullScreen, copyToClipboard: true)
                    }
                    .disabled(screenshots.isCapturing)
                    .macScopeGlassButton(prominent: true)
                    Button("Selection", systemImage: "viewfinder") {
                        screenshots.capture(.selection, copyToClipboard: true)
                    }
                    .disabled(screenshots.isCapturing)
                    .macScopeGlassButton()
                }
            }
            HStack(spacing: 8) {
                Button("Lock Screen", systemImage: "lock.fill") { lockScreen() }
                    .macScopeGlassButton()
                Button("Sound Settings", systemImage: "speaker.wave.2") {
                    openSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension")
                }
                .macScopeGlassButton()
                Button("Displays", systemImage: "display") {
                    openSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension")
                }
                .macScopeGlassButton()
            }
            HStack(spacing: 8) {
                Toggle("Hidden files", isOn: Binding(
                    get: { toggles.showsHiddenFiles },
                    set: { toggles.setShowsHiddenFiles($0) }
                ))
                Toggle("Desktop icons", isOn: Binding(
                    get: { toggles.showsDesktopIcons },
                    set: { toggles.setShowsDesktopIcons($0) }
                ))
            }
            .font(.caption)
            .disabled(toggles.isApplying || toggles.isRefreshing)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Button("Appearance", systemImage: "circle.lefthalf.filled") { toggles.toggleAppearance() }
                    .macScopeGlassButton()
                Button("Keyboard Light", systemImage: "keyboard.badge.ellipsis") {
                    openSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                }
                .macScopeGlassButton()
                Button("Eject All…", systemImage: "eject.fill") { confirmation = .ejectVolumes }
                    .macScopeGlassButton()
                Button("Empty Trash…", systemImage: "trash") { confirmation = .emptyTrash }
                    .macScopeGlassButton()
            }
            .disabled(toggles.isApplying)
            if UtilityFeatureStore.isEnabled(.power, stored: disabledModules) {
                HStack(spacing: 10) {
                    Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "moon.zzz")
                        .foregroundStyle(keepAwake.isActive ? MacScopeTheme.accent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(keepAwake.isActive ? "Keeping Mac awake" : "Normal sleep behavior")
                            .font(.callout.weight(.medium))
                        Text(keepAwake.endsAt?.formatted(date: .omitted, time: .shortened) ?? "Until stopped")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(keepAwake.isActive ? "Stop" : "Keep Awake") {
                        if keepAwake.isActive { keepAwake.stop() }
                        else { keepAwake.start(duration: nil, includesDisplay: false) }
                    }
                    .macScopeGlassButton()
                }
            }
            if let error = screenshots.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let message = toggles.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Open all utilities", systemImage: "arrow.up.forward.app", action: openUtilities)
                    .buttonStyle(.link)
            }
        }
        .task {
            if UtilityFeatureStore.isEnabled(.capture, stored: disabledModules) { screenshots.refresh() }
            toggles.refresh()
        }
        .confirmationDialog(
            confirmation == .emptyTrash ? "Permanently empty the Trash?" : "Eject all removable volumes?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if confirmation == .emptyTrash {
                Button("Empty Trash", role: .destructive) {
                    confirmation = nil
                    toggles.emptyTrash()
                }
            } else if confirmation == .ejectVolumes {
                Button("Eject Removable Volumes") {
                    confirmation = nil
                    toggles.ejectRemovableVolumes()
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation == .emptyTrash
                 ? "Items in the Trash cannot be recovered after this action."
                 : "Save any open files on external volumes before ejecting them.")
        }
    }

    private func openSettings(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func lockScreen() {
        let executable = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-suspend"]
        try? process.run()
    }
}

private struct MenuBarAudioPanel: View {
    let mixer: AudioMixerService
    let openFullMixer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    mixer.toggleSystemMute()
                } label: {
                    Image(systemName: mixer.systemMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(mixer.systemMuted == nil)

                if let volume = mixer.systemVolume {
                    Slider(
                        value: Binding(
                            get: { mixer.systemVolume ?? volume },
                            set: { mixer.setSystemVolume($0) }
                        ),
                        in: 0...1
                    )
                    Text("\(Int((mixer.systemVolume ?? volume) * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                } else {
                    Text("Hardware-controlled output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Divider().frame(height: 22)
                Button {
                    mixer.toggleInputMute()
                } label: {
                    Image(systemName: mixer.inputMuted == true ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(mixer.inputMuted == true ? .red : .primary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(mixer.inputMuted == nil)
                .help(mixer.inputMuted == true ? "Unmute microphone" : "Mute microphone")
            }

            if mixer.apps.isEmpty {
                Label("Start audio in an app to show it here.", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(mixer.apps.prefix(5)) { app in
                        MenuBarAppVolumeRow(app: app, mixer: mixer)
                        if app.id != mixer.apps.prefix(5).last?.id { Divider() }
                    }
                }
            }

            HStack {
                if mixer.apps.count > 5 {
                    Text("+\(mixer.apps.count - 5) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open full mixer", systemImage: "arrow.up.forward.app", action: openFullMixer)
                    .buttonStyle(.link)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MenuBarAppVolumeRow: View {
    let app: AudioMixerApp
    let mixer: AudioMixerService
    @State private var volume: Double

    init(app: AudioMixerApp, mixer: AudioMixerService) {
        self.app = app
        self.mixer = mixer
        _volume = State(initialValue: app.volume)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(app.isPlaying ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(app.name).font(.caption.weight(.medium)).lineLimit(1).frame(width: 90, alignment: .leading)
            Button {
                volume = app.volume > 0.001 ? 0 : 1
                mixer.toggleMute(app)
            } label: {
                Image(systemName: app.volume <= 0.001 ? "speaker.slash" : "speaker.wave.1")
            }
            .buttonStyle(.plain)
            Slider(value: $volume, in: 0...2) { editing in
                if !editing { mixer.setVolume(volume, for: app) }
            }
            Text("\(Int(volume * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .onChange(of: app.volume) { _, next in
            if abs(next - volume) > 0.005 { volume = next }
        }
    }
}

private struct MenuBarDiskPanel: View {
    let disks: [DiskSnapshot]
    let openStorage: () -> Void

    private var devices: [PhysicalDiskActivity] {
        PhysicalDiskActivityProjection.make(from: disks)
    }

    private var totalRead: Double {
        devices.reduce(0) { $0 + max($1.io.readBytesPerSecond ?? 0, 0) }
    }

    private var totalWrite: Double {
        devices.reduce(0) { $0 + max($1.io.writeBytesPerSecond ?? 0, 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                diskRateCard(title: "Read", value: totalRead, icon: "arrow.down.to.line", tint: MacScopeTheme.cyan)
                diskRateCard(title: "Write", value: totalWrite, icon: "arrow.up.to.line", tint: .orange)
            }

            if devices.isEmpty {
                Label("Waiting for physical disk counters…", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(devices.prefix(4)) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.caption.weight(.medium)).lineLimit(1)
                                Text(device.deviceIdentifier ?? device.io.provenance)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Label(compactRate(device.io.readBytesPerSecond), systemImage: "arrow.down")
                                    .foregroundStyle(MacScopeTheme.cyan)
                                Label(compactRate(device.io.writeBytesPerSecond), systemImage: "arrow.up")
                                    .foregroundStyle(.orange)
                            }
                            .font(.caption2.monospacedDigit())
                        }
                        .padding(.vertical, 7)
                        if device.id != devices.prefix(4).last?.id { Divider() }
                    }
                }
            }

            HStack {
                Text("Updated live with MacScope sampling")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open storage", systemImage: "arrow.up.forward.app", action: openStorage)
                    .buttonStyle(.link)
            }
        }
    }

    private func diskRateCard(title: String, value: Double, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(compactRate(value)).font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private func compactRate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary))/s"
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
    let batteryPercent: Double?
    let batteryTimeRemaining: String?
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
        batteryPercent = snapshot.battery.chargePercent
        let batteryMinutes = snapshot.battery.isCharging
            ? snapshot.battery.timeToFullMinutes
            : snapshot.battery.timeToEmptyMinutes
        if let batteryMinutes, batteryMinutes >= 0 {
            batteryTimeRemaining = "\(snapshot.battery.isCharging ? "FULL" : "BAT") \(batteryMinutes / 60)h \(batteryMinutes % 60)m"
        } else {
            batteryTimeRemaining = nil
        }

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
