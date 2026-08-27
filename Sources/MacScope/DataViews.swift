import AppKit
import Charts
import MacScopeCore
import SwiftUI

private enum DataVisualLayout {
    /// Exact outer heights for paired glass panels. Each token budgets for the
    /// shared header lane, the section's tallest content state, and Card insets.
    static let networkPanelHeight: CGFloat = 250
    static let processPanelHeight: CGFloat = 252
    static let startupPanelHeight: CGFloat = 244
    static let rawPanelHeight: CGFloat = 208
    static let topologyContentMinHeight: CGFloat = 166
    static let topologyMetricMinHeight: CGFloat = 146
}

struct NetworkView: View {
    let model: AppModel
    @State private var benchmarkResult: NetworkBenchmarkResult?
    @State private var benchmarkError: String?
    @State private var isBenchmarking = false
    @State private var showBenchmarkConfirmation = false
    @State private var benchmarkProgress = BenchmarkProgress(phase: .networkDownload, bytesCompleted: 0, totalBytes: 25_000_000, bytesPerSecond: 0)
    @State private var networkMeasurementComplete = false
    @State private var benchmarkResultsHidden = false
    @State private var networkFilter = ""
    @State private var sortOrder = [KeyPathComparator(\NetworkInterfaceSnapshot.name)]

    private var showsBenchmarkResults: Bool {
        isBenchmarking || (benchmarkResult != nil && !benchmarkResultsHidden)
    }

    private var filteredNetworks: [NetworkInterfaceSnapshot] {
        let filtered: [NetworkInterfaceSnapshot]
        if networkFilter.isEmpty {
            filtered = model.snapshot.networks
        } else {
            filtered = model.snapshot.networks.filter { interface in
                interface.name.localizedCaseInsensitiveContains(networkFilter)
                    || interface.displayName.localizedCaseInsensitiveContains(networkFilter)
                    || interface.addresses.contains { $0.localizedCaseInsensitiveContains(networkFilter) }
                    || (interface.isUp ? "up" : "down").localizedCaseInsensitiveContains(networkFilter)
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Network", subtitle: "Interface counters, rates, addresses, packets, errors, and an on-demand speed test")
                Button(isBenchmarking ? "Testing…" : "Run Speed Test", systemImage: "speedometer") { showBenchmarkConfirmation = true }
                    .disabled(isBenchmarking)
                    .macScopeGlassButton(prominent: true)
            }.padding(.horizontal, 24).padding(.top, 24)
            NetworkVisualSection(history: model.history, interfaces: model.snapshot.networks)
                .padding(.horizontal, 24)
            if showsBenchmarkResults {
                VStack(alignment: .leading, spacing: 12) {
                    if benchmarkResult != nil && !isBenchmarking {
                        HStack {
                            Text("Latest network benchmark").font(.headline)
                            Spacer()
                            Button("Hide Results", systemImage: "eye.slash") {
                                withAnimation(.smooth(duration: 0.25)) { benchmarkResultsHidden = true }
                            }
                            .macScopeGlassButton()
                            .help("Hide the completed speed gauge and benchmark details")
                        }
                    }
                    BenchmarkGaugeCard(
                        title: networkMeasurementComplete ? "Download measured" : benchmarkProgress.bytesCompleted == 0 ? "Preparing download" : "Live download speed",
                        phase: networkMeasurementComplete ? "Speed test complete" : benchmarkProgress.bytesCompleted == 0 ? "Measuring HTTPS latency" : "Cloudflare Speed Test",
                        speed: benchmarkProgress.bytesPerSecond * 8 / 1_000_000,
                        unit: "Mbps",
                        fractionCompleted: benchmarkProgress.fractionCompleted,
                        baselineMaximum: 1_000,
                        icon: "arrow.down.circle.fill",
                        tint: MacScopeTheme.cyan,
                        isActive: !networkMeasurementComplete
                    )
                    if let result = benchmarkResult {
                        GlassGroup {
                            HStack(spacing: 12) {
                                MetricCard(title: "Download", value: "\(result.downloadMegabitsPerSecond.formatted(.number.precision(.fractionLength(1)))) Mbps", subtitle: result.provider, icon: "arrow.down.circle")
                                MetricCard(title: "Latency", value: "\(result.latencyMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms", subtitle: "HTTPS round trip", icon: "timer")
                                MetricCard(title: "Transferred", value: ByteCountFormatter.macScope(UInt64(result.bytesTransferred)), icon: "arrow.left.arrow.right")
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            TableFilterBar(text: $networkFilter, prompt: "Filter interfaces, state, or address", resultCount: filteredNetworks.count, resultLabel: "interfaces")
                .padding(.horizontal, 24)
            Table(filteredNetworks, sortOrder: $sortOrder) {
                TableColumn("Interface", value: \.name) { item in
                    VStack(alignment: .leading) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("State", value: \.sortableState) { item in
                    Label(item.isUp ? "Up" : "Down", systemImage: item.isUp ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(item.isUp ? .green : .secondary)
                }.width(85)
                TableColumn("Download", value: \.downloadRate) { item in Text(dataRate(item.downloadRate)).monospacedDigit() }.width(110)
                TableColumn("Upload", value: \.uploadRate) { item in Text(dataRate(item.uploadRate)).monospacedDigit() }.width(110)
                TableColumn("Packets", value: \.sortablePackets) { item in Text(item.sortablePackets.formatted()).monospacedDigit() }.width(90)
                TableColumn("Errors", value: \.sortableErrors) { item in Text(item.sortableErrors.formatted()).monospacedDigit() }.width(75)
                TableColumn("Addresses", value: \.sortableAddresses) { item in Text(item.sortableAddresses).font(.caption.monospaced()).lineLimit(2) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
        .navigationTitle("Network")
        .confirmationDialog("Run network speed test?", isPresented: $showBenchmarkConfirmation) {
            Button("Download 25 MB and Test") { runNetworkBenchmark() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends an HTTPS request to Cloudflare Speed Test and downloads approximately 25 MB. Results vary with server distance and current traffic.")
        }
        .alert("Network benchmark failed", isPresented: Binding(get: { benchmarkError != nil }, set: { if !$0 { benchmarkError = nil } })) {
            Button("OK") { benchmarkError = nil }
        } message: { Text(benchmarkError ?? "") }
    }

    private func runNetworkBenchmark() {
        isBenchmarking = true
        benchmarkResult = nil
        benchmarkResultsHidden = false
        networkMeasurementComplete = false
        benchmarkProgress = BenchmarkProgress(phase: .networkDownload, bytesCompleted: 0, totalBytes: 25_000_000, bytesPerSecond: 0)
        Task {
            let gaugePresentedAt = Date()
            do {
                let result = try await BenchmarkRunner.network { progress in
                    Task { @MainActor in
                        benchmarkProgress = progress
                    }
                }
                benchmarkProgress = BenchmarkProgress(
                    phase: .networkDownload,
                    bytesCompleted: result.bytesTransferred,
                    totalBytes: result.bytesTransferred,
                    bytesPerSecond: result.downloadMegabitsPerSecond * 1_000_000 / 8
                )
                networkMeasurementComplete = true
                try await keepGaugeVisible(since: gaugePresentedAt)
                benchmarkResult = result
            }
            catch { benchmarkError = error.localizedDescription }
            isBenchmarking = false
        }
    }
}

private extension NetworkInterfaceSnapshot {
    var sortableState: Int { isUp ? 1 : 0 }
    var sortablePackets: UInt64 { packetsIn + packetsOut }
    var sortableErrors: UInt64 { errorsIn + errorsOut }
    var sortableAddresses: String { addresses.joined(separator: ", ") }
}

struct StorageView: View {
    let model: AppModel
    @State private var benchmarkTarget: DiskSnapshot?
    @State private var benchmarkResult: DiskBenchmarkResult?
    @State private var benchmarkError: String?
    @State private var isBenchmarking = false
    @State private var diskProgress = BenchmarkProgress(phase: .diskWrite, bytesCompleted: 0, totalBytes: 128 * 1_024 * 1_024, bytesPerSecond: 0)
    @State private var liveWriteMegabytesPerSecond = 0.0
    @State private var liveReadMegabytesPerSecond = 0.0
    @State private var liveWriteSpeedHistory: [BenchmarkSpeedPoint] = []
    @State private var liveReadSpeedHistory: [BenchmarkSpeedPoint] = []
    @State private var diskMeasurementComplete = false
    @State private var benchmarkResultsHidden = false

    private var showsBenchmarkResults: Bool {
        isBenchmarking || (benchmarkResult != nil && !benchmarkResultsHidden)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Storage & SMART", subtitle: "Live physical-disk activity, mounted volumes, benchmarks, and drive health")
                StorageLiveActivityOverview(
                    disks: model.snapshot.disks,
                    history: model.history
                )
                Text("Mounted volumes")
                    .font(.title3.weight(.semibold))
                ForEach(model.snapshot.disks) { disk in
                    StorageDiskDetailCard(
                        disk: disk,
                        history: model.history,
                        canBenchmark: !disk.isReadOnly && !isBenchmarking
                    ) {
                        benchmarkTarget = disk
                    }
                }
                if showsBenchmarkResults {
                    VStack(alignment: .leading, spacing: 12) {
                        if benchmarkResult != nil && !isBenchmarking {
                            HStack {
                                Text("Latest disk benchmark").font(.headline)
                                Spacer()
                                Button("Hide Results", systemImage: "eye.slash") {
                                    withAnimation(.smooth(duration: 0.25)) { benchmarkResultsHidden = true }
                                }
                                .macScopeGlassButton()
                                .help("Hide the completed disk gauges and benchmark details")
                            }
                        }
                        GlassGroup {
                            HStack(spacing: 12) {
                                BenchmarkGaugeCard(
                                    title: "Sequential write",
                                    phase: diskProgress.phase == .diskWrite ? "Writing temporary test data" : "Write pass complete",
                                    speed: liveWriteMegabytesPerSecond,
                                    unit: "MB/s",
                                    fractionCompleted: diskProgress.phase == .diskWrite ? diskProgress.fractionCompleted : 1,
                                    baselineMaximum: 5_000,
                                    icon: "square.and.arrow.down.fill",
                                    tint: MacScopeTheme.accent,
                                    isActive: diskProgress.phase == .diskWrite,
                                    speedHistory: liveWriteSpeedHistory
                                )
                                BenchmarkGaugeCard(
                                    title: "Sequential read",
                                    phase: diskMeasurementComplete ? "Read pass complete" : diskProgress.phase == .diskRead ? "Reading uncached test data" : "Waiting for write pass",
                                    speed: liveReadMegabytesPerSecond,
                                    unit: "MB/s",
                                    fractionCompleted: diskProgress.phase == .diskRead ? diskProgress.fractionCompleted : 0,
                                    baselineMaximum: 5_000,
                                    icon: "square.and.arrow.up.fill",
                                    tint: MacScopeTheme.cyan,
                                    isActive: diskProgress.phase == .diskRead && !diskMeasurementComplete,
                                    speedHistory: liveReadSpeedHistory
                                )
                            }
                        }
                        if let result = benchmarkResult {
                            Card {
                                HStack(spacing: 20) {
                                    LabeledContent("Sequential write", value: "\(result.writeMegabytesPerSecond.formatted(.number.precision(.fractionLength(0...1)))) MB/s")
                                    LabeledContent("Sequential read", value: "\(result.readMegabytesPerSecond.formatted(.number.precision(.fractionLength(0...1)))) MB/s")
                                    LabeledContent("Test size", value: ByteCountFormatter.macScope(UInt64(result.bytesTested)))
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                ForEach(model.snapshot.smartReports) { report in
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(report.deviceName, systemImage: "checkmark.shield")
                                    .font(.headline)
                                Spacer()
                                AvailabilityBadge(availability: report.availability)
                            }
                            LabeledContent("SMART health", value: report.health)
                            LabeledContent("Protocol", value: report.protocolName)
                            DisclosureGroup("Reported fields (\(report.attributes.count))") {
                                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                                    ForEach(report.attributes) { attribute in
                                        GridRow {
                                            Text(attribute.name).foregroundStyle(.secondary)
                                            Text(attribute.value).monospaced()
                                        }
                                    }
                                }.padding(.top, 8)
                            }
                            if let detail = report.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.padding(24)
        }
        .navigationTitle("Storage & SMART")
        .confirmationDialog("Benchmark this volume?", isPresented: Binding(get: { benchmarkTarget != nil }, set: { if !$0 { benchmarkTarget = nil } })) {
            Button("Create 128 MB Test File") {
                if let target = benchmarkTarget { runDiskBenchmark(target) }
                benchmarkTarget = nil
            }
            Button("Cancel", role: .cancel) { benchmarkTarget = nil }
        } message: {
            Text("MacScope creates, synchronizes, reads, and removes a 128 MB temporary file on the selected volume. Performance may be lower while other disk activity is running.")
        }
        .alert("Disk benchmark failed", isPresented: Binding(get: { benchmarkError != nil }, set: { if !$0 { benchmarkError = nil } })) {
            Button("OK") { benchmarkError = nil }
        } message: { Text(benchmarkError ?? "") }
    }

    private func runDiskBenchmark(_ disk: DiskSnapshot) {
        isBenchmarking = true
        benchmarkResult = nil
        benchmarkResultsHidden = false
        diskProgress = BenchmarkProgress(phase: .diskWrite, bytesCompleted: 0, totalBytes: 128 * 1_024 * 1_024, bytesPerSecond: 0)
        liveWriteMegabytesPerSecond = 0
        liveReadMegabytesPerSecond = 0
        liveWriteSpeedHistory = []
        liveReadSpeedHistory = []
        diskMeasurementComplete = false
        Task {
            let gaugePresentedAt = Date()
            do {
                let result = try await BenchmarkRunner.disk(at: URL(fileURLWithPath: disk.mountPoint, isDirectory: true)) { progress in
                    Task { @MainActor in
                        diskProgress = progress
                        let speed = progress.bytesPerSecond / 1_000_000
                        if progress.phase == .diskWrite {
                            liveWriteMegabytesPerSecond = speed
                            liveWriteSpeedHistory.append(BenchmarkSpeedPoint(timestamp: .now, value: speed))
                            if liveWriteSpeedHistory.count > 90 {
                                liveWriteSpeedHistory.removeFirst(liveWriteSpeedHistory.count - 90)
                            }
                        } else if progress.phase == .diskRead {
                            liveReadMegabytesPerSecond = speed
                            liveReadSpeedHistory.append(BenchmarkSpeedPoint(timestamp: .now, value: speed))
                            if liveReadSpeedHistory.count > 90 {
                                liveReadSpeedHistory.removeFirst(liveReadSpeedHistory.count - 90)
                            }
                        }
                    }
                }
                liveWriteMegabytesPerSecond = result.writeMegabytesPerSecond
                liveReadMegabytesPerSecond = result.readMegabytesPerSecond
                diskProgress = BenchmarkProgress(phase: .diskRead, bytesCompleted: result.bytesTested, totalBytes: result.bytesTested, bytesPerSecond: result.readMegabytesPerSecond * 1_000_000)
                diskMeasurementComplete = true
                try await keepGaugeVisible(since: gaugePresentedAt)
                benchmarkResult = result
            }
            catch { benchmarkError = error.localizedDescription }
            isBenchmarking = false
        }
    }
}

@MainActor private func keepGaugeVisible(since start: Date, minimumDuration: TimeInterval = 1.5) async throws {
    let remaining = minimumDuration - Date().timeIntervalSince(start)
    if remaining > 0 {
        try await Task.sleep(for: .seconds(remaining))
    }
}

private struct BenchmarkGaugeCard: View {
    let title: String
    let phase: String
    let speed: Double
    let unit: String
    let fractionCompleted: Double
    let baselineMaximum: Double
    let icon: String
    let tint: Color
    var isActive = true
    var speedHistory: [BenchmarkSpeedPoint]? = nil

    private var gaugeMaximum: Double {
        let target = max(baselineMaximum, speed * 1.2)
        let steps: [Double] = [100, 250, 500, 1_000, 2_500, 5_000, 10_000, 20_000, 40_000]
        return steps.first(where: { $0 >= target }) ?? max(target, 1)
    }

    private var cardHeight: CGFloat {
        speedHistory == nil ? 150 : 196
    }

    var body: some View {
        Card {
            HStack(spacing: 18) {
                Gauge(value: min(max(speed, 0), gaugeMaximum), in: 0...gaugeMaximum) {
                    Label(title, systemImage: icon)
                } currentValueLabel: {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(AngularGradient(colors: [tint.opacity(0.35), tint], center: .center))
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(title).font(.headline)
                        if isActive {
                            Circle().fill(tint).frame(width: 6, height: 6)
                                .shadow(color: tint.opacity(0.7), radius: 4)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(speed.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 31, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: min(max(fractionCompleted, 0), 1))
                        .tint(tint)
                    if let speedHistory {
                        MetricSparkline(
                            points: speedHistory.map { point in
                                MetricPoint(timestamp: point.timestamp, value: point.value)
                            },
                            tint: tint,
                            interpolation: .linear,
                            height: 38
                        )
                        .accessibilityLabel("\(title) live speed history")
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: speedHistory == nil ? 118 : 164, alignment: .leading)
        }
        .frame(height: cardHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(speed.formatted(.number.precision(.fractionLength(1)))) \(unit), \(Int(fractionCompleted * 100)) percent complete")
    }
}

private struct BenchmarkSpeedPoint: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct ProcessesView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<ProcessTableRow.ID>()
    @State private var expandedProcessIDs = Set<ProcessSnapshot.ID>()
    @State private var lockedProcessRanks: [ProcessSnapshot.ID: Int] = [:]
    @State private var actionError: String?
    @State private var sortRule = ProcessSortRule.defaultRule
    @State private var presentation = ProcessPresentation.empty
    @State private var presentationGeneration = 0
    @State private var presentationTask: Task<Void, Never>?

    var body: some View {
        let processes = presentation.rows
        let processCount = presentation.totalCount
        let isFiltering = presentation.isFiltering

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Processes", subtitle: "Live CPU, memory, threads, and disk activity")
            }
            .padding(.horizontal, 24).padding(.top, 24)

            ProcessVisualSection(processes: presentation.processes)
                .padding(.horizontal, 24)

            HStack(spacing: 10) {
                TableFilterBar(text: $model.processSearch, prompt: "Filter process, PID, user, state, or path", resultCount: processCount, resultLabel: processCount == 1 ? "process" : "processes")
                if !selection.isEmpty {
                    Button {
                        selection.removeAll()
                    } label: {
                        Label("Order locked", systemImage: "lock.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .macScopeGlassSurface(cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .help("Keep the selected process in place. Click to unlock and deselect.")
                    .accessibilityLabel("Process order locked. Unlock and clear selection")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
                .padding(.horizontal, 24)

            ProcessVirtualizedTable(
                rows: processes,
                selection: $selection,
                sortRule: sortRule,
                disclosureEnabled: !isFiltering,
                onSort: { nextRule in
                    sortRule = nextRule
                },
                onToggleExpansion: { processID in
                    if expandedProcessIDs.contains(processID) {
                        expandedProcessIDs.remove(processID)
                    } else {
                        expandedProcessIDs.insert(processID)
                    }
                    refreshPresentation()
                },
                onAction: { kind, process in
                    perform(kind, process: process)
                }
            )
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        }
        .navigationTitle("Processes")
        .alert("Process action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "Unknown error") }
        .onChange(of: selection) { oldSelection, newSelection in
            if newSelection.isEmpty {
                guard !lockedProcessRanks.isEmpty else { return }
                lockedProcessRanks.removeAll(keepingCapacity: true)
                refreshPresentation()
            } else if oldSelection != newSelection, lockedProcessRanks.isEmpty {
                lockedProcessRanks = ProcessHierarchy.stableRanks(for: presentation.tree)
            }
        }
        .onChange(of: model.processSearch) { _, _ in
            selection.removeAll()
            lockedProcessRanks.removeAll(keepingCapacity: true)
            refreshPresentation()
        }
        .onChange(of: sortRule) { _, _ in
            refreshPresentation()
        }
        .onChange(of: model.snapshot.timestamp) { _, _ in
            let activeIDs = Set(model.snapshot.processes.map(\.id))
            expandedProcessIDs.formIntersection(activeIDs)
            selection.formIntersection(activeIDs)
            if selection.isEmpty {
                lockedProcessRanks.removeAll(keepingCapacity: true)
            }
            refreshPresentation()
        }
        .onAppear { refreshPresentation() }
        .onDisappear {
            presentationTask?.cancel()
            presentationTask = nil
        }
    }

    @MainActor
    private func refreshPresentation() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let input = ProcessPresentation.Input(
            processes: model.snapshot.processes,
            query: model.processSearch,
            expandedIDs: expandedProcessIDs,
            lockedRanks: lockedProcessRanks,
            sortRule: sortRule
        )

        presentationTask?.cancel()
        presentationTask = Task { @MainActor in
            let buildTask = Task.detached(priority: .userInitiated) {
                ProcessPresentation.make(input)
            }
            let next = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled, generation == presentationGeneration else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                presentation = next
            }
        }
    }

    private func perform(_ kind: ProcessActionKind, process: ProcessSnapshot) {
        guard let startedAt = process.startedAt else {
            actionError = "The process start time is unavailable, so MacScope cannot safely validate this PID."
            return
        }
        Task {
            do {
                _ = try await ProcessController.execute(ProcessActionRequest(kind: kind, pid: process.pid, expectedStartTime: startedAt))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct ProcessPresentation: Sendable {
    struct Input: Sendable {
        let processes: [ProcessSnapshot]
        let query: String
        let expandedIDs: Set<ProcessSnapshot.ID>
        let lockedRanks: [ProcessSnapshot.ID: Int]
        let sortRule: ProcessSortRule
    }

    let processes: [ProcessSnapshot]
    let tree: [ProcessTreeNode]
    let rows: [ProcessTableRow]
    let totalCount: Int
    let isFiltering: Bool

    static let empty = ProcessPresentation(
        processes: [],
        tree: [],
        rows: [],
        totalCount: 0,
        isFiltering: false
    )

    static func make(_ input: Input) -> ProcessPresentation {
        guard !Task.isCancelled else { return .empty }
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !query.isEmpty
        let built = ProcessHierarchy.build(from: input.processes, matching: query)
        guard !Task.isCancelled else { return .empty }

        let arranged: [ProcessTreeNode]
        if input.lockedRanks.isEmpty {
            arranged = sortTree(built, using: input.sortRule)
        } else {
            arranged = ProcessHierarchy.applyingStableOrder(to: built, ranks: input.lockedRanks)
        }

        var rows: [ProcessTableRow] = []
        rows.reserveCapacity(arranged.reduce(0) { $0 + 1 + $1.descendantCount })
        appendVisibleRows(
            from: arranged,
            depth: 0,
            isFiltering: isFiltering,
            expandedIDs: input.expandedIDs,
            into: &rows
        )

        return ProcessPresentation(
            processes: input.processes,
            tree: arranged,
            rows: rows,
            totalCount: arranged.reduce(0) { $0 + 1 + $1.descendantCount },
            isFiltering: isFiltering
        )
    }

    private static func sortTree(
        _ nodes: [ProcessTreeNode],
        using sortRule: ProcessSortRule
    ) -> [ProcessTreeNode] {
        guard !Task.isCancelled else { return nodes }
        let recursivelySorted = nodes.map { node in
            ProcessTreeNode(
                process: node.process,
                children: node.children.map { sortTree($0, using: sortRule) }
            )
        }
        return recursivelySorted
            .map {
                ProcessTableRow(
                    node: $0,
                    depth: 0,
                    isExpanded: false,
                    usesGroupTotals: $0.children != nil
                )
            }
            .sorted(by: sortRule.areInIncreasingOrder)
            .map(\.node)
    }

    private static func appendVisibleRows(
        from nodes: [ProcessTreeNode],
        depth: Int,
        isFiltering: Bool,
        expandedIDs: Set<ProcessSnapshot.ID>,
        into rows: inout [ProcessTableRow]
    ) {
        for node in nodes {
            guard !Task.isCancelled else { return }
            let isExpanded = node.children != nil && (isFiltering || expandedIDs.contains(node.id))
            rows.append(
                ProcessTableRow(
                    node: node,
                    depth: depth,
                    isExpanded: isExpanded,
                    usesGroupTotals: node.children != nil && !isExpanded
                )
            )
            if isExpanded, let children = node.children {
                appendVisibleRows(
                    from: children,
                    depth: depth + 1,
                    isFiltering: isFiltering,
                    expandedIDs: expandedIDs,
                    into: &rows
                )
            }
        }
    }
}

struct StartupView: View {
    @Bindable var model: AppModel
    @State private var selection: StartupItem.ID?
    @State private var sortRule = StartupSortRule.defaultRule
    @State private var presentation = StartupTablePresentation.empty
    @State private var presentationRevision = 0
    @State private var presentationGeneration = 0
    @State private var presentationTask: Task<Void, Never>?
    @State private var pendingAction: StartupActionSheetState?
    @State private var actionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Startup", subtitle: "LaunchAgents and LaunchDaemons discovered on this Mac")
            }.padding(.horizontal, 24).padding(.top, 24)
            StartupVisualSection(summary: presentation.summary)
                .padding(.horizontal, 24)
            TableFilterBar(text: $model.startupSearch, prompt: "Filter label, domain, program, or path", resultCount: presentation.rows.count, resultLabel: "definitions")
                .padding(.horizontal, 24)
            StartupVirtualizedTable(
                rows: presentation.rows,
                rowsRevision: presentationRevision,
                selection: $selection,
                sortRule: sortRule,
                onSort: { sortRule = $0 },
                onAction: { kind, item in prepare(kind, item: item) }
            )
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        }
        .navigationTitle("Startup")
        .sheet(item: $pendingAction) { state in
            StartupActionConfirmation(state: state) { confirmation in
                Task { await execute(state: state, confirmation: confirmation) }
            }
        }
        .alert("Startup action", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
            Button("OK") { actionMessage = nil }
        } message: { Text(actionMessage ?? "") }
        .onChange(of: model.startupSearch) { _, _ in refreshPresentation() }
        .onChange(of: sortRule) { _, _ in refreshPresentation() }
        .onChange(of: model.startupItems) { _, newItems in
            selection = StartupSelection.retained(selection, in: newItems)
            refreshPresentation()
        }
        .onAppear { refreshPresentation() }
        .onDisappear {
            presentationTask?.cancel()
            presentationTask = nil
        }
    }

    @MainActor
    private func refreshPresentation() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let items = model.startupItems
        let query = model.startupSearch
        let rule = sortRule

        presentationTask?.cancel()
        presentationTask = Task { @MainActor in
            do {
                // Coalesce fast typing before any localized string work starts.
                try await Task.sleep(for: .milliseconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled, generation == presentationGeneration else { return }
            let buildTask = Task.detached(priority: .userInitiated) {
                StartupTableProjection.build(items: items, query: query, sortRule: rule)
            }
            let next = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled, generation == presentationGeneration else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                presentation = next
                presentationRevision &+= 1
            }
        }
    }

    private func prepare(_ kind: LaunchActionKind, item: StartupItem) {
        Task {
            do {
                let request = launchRequest(kind, item: item)
                let envelope = PrivilegedActionEnvelope.launchd(request)
                let preflight = try await PrivilegedActionClient.preflight(envelope)
                pendingAction = StartupActionSheetState(item: item, envelope: envelope, preflight: preflight)
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func execute(state: StartupActionSheetState, confirmation: String) async {
        pendingAction = nil
        do {
            let result = try await PrivilegedActionClient.execute(state.envelope, confirmation: confirmation)
            actionMessage = result.message
            model.refreshStartup()
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func launchRequest(_ kind: LaunchActionKind, item: StartupItem) -> LaunchActionRequest {
        LaunchActionRequest(kind: kind, domain: item.launchDomain, label: item.label, propertyListPath: item.sourcePath, userID: getuid())
    }
}

private struct StartupActionSheetState: Identifiable {
    let id = UUID()
    let item: StartupItem
    let envelope: PrivilegedActionEnvelope
    let preflight: ActionPreflight
}

private struct StartupActionConfirmation: View {
    let state: StartupActionSheetState
    let execute: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Confirm \(state.preflight.operation.capitalized)", subtitle: "This changes launchd state without deleting or rewriting the property list.")
            Card {
                LabeledContent("Target", value: state.preflight.target)
                LabeledContent("Operation", value: state.preflight.operation)
                LabeledContent("Expected effect", value: state.preflight.expectedEffect)
                LabeledContent("Reversible", value: state.preflight.reversible ? "Yes" : "No")
            }
            Text("Type **\(state.preflight.confirmationPhrase)** to continue.")
            TextField("Confirmation phrase", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { execute(confirmation) }
                    .buttonStyle(.borderedProminent)
                    .disabled(confirmation != state.preflight.confirmationPhrase)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

struct HardwareView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Hardware", subtitle: "System identity and capabilities without exporting sensitive identifiers")
                HardwareTopologyGraphic(inventory: model.snapshot.inventory, memory: model.snapshot.memory)
                GlassGroup {
                    HStack(spacing: 12) {
                        MetricCard(title: "Model", value: model.snapshot.inventory.modelName, subtitle: model.snapshot.inventory.modelIdentifier, icon: "laptopcomputer")
                        MetricCard(title: "Chip", value: model.snapshot.inventory.chip, subtitle: model.snapshot.inventory.architecture, icon: "cpu")
                        MetricCard(title: "Memory", value: ByteCountFormatter.macScope(model.snapshot.inventory.physicalMemory), icon: "memorychip")
                        MetricCard(title: "Uptime", value: uptime(model.snapshot.inventory.uptime), icon: "clock")
                    }
                }
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        ForEach(model.snapshot.inventory.details.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            GridRow {
                                Text(key).foregroundStyle(.secondary)
                                Text(value).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(24)
        }.navigationTitle("Hardware")
    }
}

struct RawDataView: View {
    let model: AppModel
    @State private var document = JSONOutlineDocument(text: "")
    @State private var isRendering = false
    @State private var renderedAt: Date?
    @State private var capturedSummary = RawSnapshotVisualSummary()
    @State private var refreshID = 0
    @AppStorage("redactExports") private var redactExports = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Raw Data", subtitle: "Bounded preview of the normalized snapshot; complete collections remain in their dedicated tables")
                Spacer()
                if isRendering {
                    ProgressView().controlSize(.small)
                } else if let renderedAt {
                    Text("Captured \(renderedAt, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID &+= 1 }
                    .disabled(isRendering)
            }
            .padding(.horizontal, 24).padding(.top, 24)
            RawSnapshotVisualSection(summary: capturedSummary)
                .padding(.horizontal, 24)
            RawJSONViewerPanel(document: document)
                .padding([.horizontal, .bottom], 24)
        }
        .task(id: refreshID, priority: .utility) { await refresh() }
        .navigationTitle("Raw Data")
        .toolbar {
            ToolbarItemGroup {
                Button("Export Inventory JSON", systemImage: "square.and.arrow.up") {
                    AppExportController.exportInventory(model.snapshot.inventory, redact: redactExports)
                }
                Button("Export Metrics CSV", systemImage: "tablecells") {
                    AppExportController.exportMetrics(model.history)
                }
            }
        }
    }

    private func refresh() async {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }
        let snapshot = model.snapshot
        capturedSummary = RawSnapshotVisualSummary(snapshot: snapshot)
        do {
            let renderedDocument = try await RawJSONDocumentRenderer.shared.render(snapshot)
            try Task.checkCancellation()
            document = renderedDocument
            renderedAt = snapshot.timestamp
        } catch is CancellationError {
            return
        } catch {
            document = JSONOutlineDocument(text: "Unable to render JSON: \(error.localizedDescription)")
        }
    }
}

private actor RawJSONDocumentRenderer {
    static let shared = RawJSONDocumentRenderer()

    func render(_ snapshot: SystemSnapshot) throws -> JSONOutlineDocument {
        try Task.checkCancellation()
        let text = RawSnapshotRenderer.previewJSON(snapshot)
        try Task.checkCancellation()
        return JSONOutlineDocument(text: text)
    }
}

// MARK: - Data section visual summaries

private struct NetworkVisualSection: View {
    let history: [SystemSnapshot]
    let interfaces: [NetworkInterfaceSnapshot]

    private var availability: DataAvailability {
        interfaces.isEmpty ? .degraded : .available
    }

    private var trafficSeries: [MetricSeries] {
        let download = history.compactMap { snapshot -> MetricPoint? in
            guard !snapshot.networks.isEmpty else { return nil }
            return MetricPoint(
                timestamp: snapshot.timestamp,
                value: snapshot.networks.reduce(0) { $0 + $1.downloadRate } / 1_048_576
            )
        }
        let upload = history.compactMap { snapshot -> MetricPoint? in
            guard !snapshot.networks.isEmpty else { return nil }
            return MetricPoint(
                timestamp: snapshot.timestamp,
                value: snapshot.networks.reduce(0) { $0 + $1.uploadRate } / 1_048_576
            )
        }
        return [
            MetricSeries(
                id: "network-download",
                title: "Download",
                unit: "MiB/s",
                tint: MacScopeTheme.accent,
                points: download,
                availability: availability,
                quality: .derived,
                interpolation: .linear
            ),
            MetricSeries(
                id: "network-upload",
                title: "Upload",
                unit: "MiB/s",
                tint: MacScopeTheme.cyan,
                points: upload,
                availability: availability,
                quality: .derived,
                interpolation: .linear
            )
        ]
    }

    private var downloadMetrics: [RankedMetric] {
        interfaces.map { interface in
            RankedMetric(
                id: "download-\(interface.id)",
                label: interface.name,
                value: interface.downloadRate / 1_048_576,
                tint: MacScopeTheme.accent
            )
        }.sorted { $0.value > $1.value }
    }

    private var uploadMetrics: [RankedMetric] {
        interfaces.map { interface in
            RankedMetric(
                id: "upload-\(interface.id)",
                label: interface.name,
                value: interface.uploadRate / 1_048_576,
                tint: MacScopeTheme.cyan
            )
        }.sorted { $0.value > $1.value }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VisualPanel(
                title: "Traffic history",
                subtitle: historyCaption,
                availability: availability,
                height: DataVisualLayout.networkPanelHeight
            ) {
                MetricTrendChart(
                    series: trafficSeries,
                    unit: "MiB/s",
                    includesZero: true,
                    height: 150,
                    showsLegend: true
                )
            }
            .frame(maxWidth: .infinity)

            VisualPanel(
                title: "Current interface rates",
                subtitle: "Highest reported rates, including virtual interfaces",
                availability: availability,
                height: DataVisualLayout.networkPanelHeight
            ) {
                if interfaces.isEmpty {
                    ContentUnavailableView("No interfaces", systemImage: "network.slash", description: Text("No network interface counters are currently available."))
                        .frame(height: 152)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Download", systemImage: "arrow.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            RankedMetricBars(items: downloadMetrics, unit: "MiB/s", maximumCount: 4, height: 132)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Upload", systemImage: "arrow.up")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            RankedMetricBars(items: uploadMetrics, unit: "MiB/s", maximumCount: 4, height: 132)
                        }
                    }
                    .frame(height: 150, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var historyCaption: String {
        guard let first = history.first?.timestamp, let last = history.last?.timestamp, last > first else {
            return "Building a session history from reported interfaces"
        }
        let seconds = max(Int(last.timeIntervalSince(first).rounded()), 1)
        return "Download and upload across all reported interfaces over the last \(seconds) s"
    }
}

private enum ProcessRankingMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    var id: String { rawValue }
}

private struct ProcessVisualSection: View {
    let processes: [ProcessSnapshot]
    @State private var rankingMetric: ProcessRankingMetric = .cpu

    private var ranking: [RankedMetric] {
        var top: [RankedMetric] = []
        top.reserveCapacity(5)
        for process in processes {
            let metric: RankedMetric
            switch rankingMetric {
            case .cpu:
                metric = RankedMetric(
                    id: processIdentity(process),
                    label: "\(process.name) · \(process.pid)",
                    value: process.cpuPercent,
                    tint: MacScopeTheme.accent
                )
            case .memory:
                metric = RankedMetric(
                    id: processIdentity(process),
                    label: "\(process.name) · \(process.pid)",
                    value: Double(process.residentMemory) / 1_048_576,
                    tint: MacScopeTheme.cyan
                )
            }
            let insertionIndex = top.firstIndex { metric.value > $0.value } ?? top.endIndex
            top.insert(metric, at: insertionIndex)
            if top.count > 5 { top.removeLast() }
        }
        return top
    }

    private var stateSegments: [DistributionSegment] {
        let counts = Dictionary(grouping: processes, by: \ProcessSnapshot.state).mapValues(\.count)
        let orderedStates = ["Running", "Sleeping", "Stopped", "Zombie", "Idle", "Unknown"]
        let colors: [Color] = [.green, MacScopeTheme.accent, .orange, .red, MacScopeTheme.cyan, .gray]
        return zip(orderedStates, colors).compactMap { state, color in
            let count = counts[state, default: 0]
            guard count > 0 else { return nil }
            return DistributionSegment(
                id: state,
                label: state,
                value: Double(count),
                tint: color
            )
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VisualPanel(
                title: "Top processes",
                subtitle: "Current snapshot; selecting a row still locks table order",
                availability: processes.isEmpty ? .degraded : .available,
                height: DataVisualLayout.processPanelHeight
            ) {
                if processes.isEmpty {
                    ContentUnavailableView("No process samples", systemImage: "list.bullet.rectangle", description: Text("Process telemetry has not reported yet."))
                        .frame(height: 150)
                } else {
                    VStack(spacing: 8) {
                        Picker("Ranking", selection: $rankingMetric) {
                            ForEach(ProcessRankingMetric.allCases) { metric in Text(metric.rawValue).tag(metric) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        RankedMetricBars(
                            items: ranking,
                            unit: rankingMetric == .cpu ? "%" : "MiB",
                            maximumCount: 5,
                            height: 124
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VisualPanel(
                title: "Process states",
                subtitle: "Composition of the current process snapshot",
                availability: processes.isEmpty ? .degraded : .available,
                height: DataVisualLayout.processPanelHeight
            ) {
                if processes.isEmpty {
                    ContentUnavailableView("No process states", systemImage: "chart.pie", description: Text("State composition appears when process telemetry is available."))
                        .frame(height: 150)
                } else {
                    StatusComposition(
                        segments: stateSegments,
                        centerTitle: "Processes",
                        centerValue: processes.count.formatted()
                    )
                    .frame(height: 150)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func processIdentity(_ process: ProcessSnapshot) -> String {
        "\(process.pid)-\(process.startedAt?.timeIntervalSince1970 ?? 0)"
    }
}

private struct StartupVisualSection: View {
    let summary: StartupVisualSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VisualPanel(
                title: "Definitions by domain",
                subtitle: "Enabled state reported by launchd overrides and property lists",
                availability: summary.total == 0 ? .degraded : .available,
                height: DataVisualLayout.startupPanelHeight
            ) {
                if summary.total == 0 {
                    ContentUnavailableView("No startup definitions", systemImage: "power", description: Text("Startup definitions have not been discovered yet."))
                        .frame(height: 140)
                } else {
                    VStack(spacing: 14) {
                        ForEach(StartupDomain.allCases, id: \.rawValue) { domain in
                            let domainSummary = summary.summary(for: domain)
                            HStack(spacing: 10) {
                                Text(domain.rawValue.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 52, alignment: .leading)
                                MetricDistributionBar(
                                    segments: enabledSegments(for: domainSummary),
                                    height: 12,
                                    showsLegend: false
                                )
                                Text(domainSummary.total.formatted())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                        HStack(spacing: 12) {
                            statusLegend("Enabled", color: .green)
                            statusLegend("Disabled", color: .orange)
                            statusLegend("Unknown", color: .gray)
                        }
                    }
                    .frame(height: 140)
                }
            }
            .frame(maxWidth: .infinity)

            VisualPanel(
                title: "Launch behavior",
                subtitle: "Declared configuration, not proof that a service is running",
                availability: summary.total == 0 ? .degraded : .available,
                height: DataVisualLayout.startupPanelHeight
            ) {
                if summary.total == 0 {
                    ContentUnavailableView("No launch behavior", systemImage: "gauge.with.dots.needle.0percent", description: Text("Configuration ratios appear after startup discovery."))
                        .frame(height: 140)
                } else {
                    HStack(spacing: 28) {
                        MetricRing(
                            title: "Run at load",
                            value: summary.runAtLoad.formatted(),
                            unit: "of \(summary.total)",
                            fraction: Double(summary.runAtLoad) / Double(max(summary.total, 1)),
                            tint: MacScopeTheme.accent,
                            icon: "play.fill",
                            availability: .available
                        )
                        MetricRing(
                            title: "Keep alive",
                            value: summary.keepAlive.formatted(),
                            unit: "of \(summary.total)",
                            fraction: Double(summary.keepAlive) / Double(max(summary.total, 1)),
                            tint: MacScopeTheme.cyan,
                            icon: "arrow.triangle.2.circlepath",
                            availability: .available
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func enabledSegments(for summary: StartupDomainSummary) -> [DistributionSegment] {
        return [
            DistributionSegment(id: "\(summary.domain.rawValue)-enabled", label: "Enabled", value: Double(summary.enabled), tint: .green),
            DistributionSegment(id: "\(summary.domain.rawValue)-disabled", label: "Disabled", value: Double(summary.disabled), tint: .orange),
            DistributionSegment(id: "\(summary.domain.rawValue)-unknown", label: "Unknown", value: Double(summary.unknown), tint: .gray)
        ]
    }

    private func statusLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct HardwareTopologyGraphic: View {
    let inventory: HardwareInventory
    let memory: MemorySnapshot

    private var detectedAvailability: DataAvailability {
        inventory.modelIdentifier == "Unknown" ? .degraded : .available
    }

    private var memoryTotal: UInt64 { max(memory.total, inventory.physicalMemory) }

    var body: some View {
        VisualPanel(
            title: "Apple silicon topology",
            subtitle: "Detected compute and memory resources; the memory ring is live usage",
            availability: detectedAvailability
        ) {
            HStack(spacing: 20) {
                topologyNode(icon: "cpu.fill", title: inventory.chip, detail: inventory.architecture, tint: MacScopeTheme.accent)
                    .frame(maxWidth: 200)

                Image(systemName: "chevron.right.2")
                    .font(.title3.weight(.semibold)).foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        processorBlock
                        MetricRing(
                            title: "Memory used",
                            value: memoryTotal > 0 ? ByteCountFormatter.macScope(memory.used) : "Unavailable",
                            unit: memoryTotal > 0 ? "of \(ByteCountFormatter.macScope(memoryTotal))" : "",
                            fraction: memoryTotal > 0 ? Double(memory.used) / Double(memoryTotal) : nil,
                            tint: MacScopeTheme.cyan,
                            icon: "memorychip",
                            availability: memoryTotal > 0 ? .available : .degraded
                        )
                    }
                    gpuRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: DataVisualLayout.topologyContentMinHeight)
        }
    }

    private var processorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Logical processors", systemImage: "square.grid.4x3.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 5), count: 8), spacing: 5) {
                ForEach(0..<max(inventory.processorCount, 0), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index < inventory.activeProcessorCount ? MacScopeTheme.accent : Color.secondary.opacity(0.18))
                        .frame(width: 12, height: 12)
                }
            }
            Text("\(inventory.activeProcessorCount) available of \(inventory.processorCount)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: DataVisualLayout.topologyMetricMinHeight,
            alignment: .leading
        )
        .macScopeGlassSurface(cornerRadius: 9)
    }

    @ViewBuilder private var gpuRow: some View {
        if inventory.gpus == nil {
            Label("Detecting graphics hardware…", systemImage: "rectangle.3.group")
                .font(.caption).foregroundStyle(.secondary)
        } else if let gpus = inventory.gpus, gpus.isEmpty {
            Label("No GPU detected", systemImage: "rectangle.3.group.slash")
                .font(.caption).foregroundStyle(.secondary)
        } else if let gpus = inventory.gpus {
            HStack(spacing: 8) {
                ForEach(gpus) { gpu in
                    Label {
                        Text(gpu.coreCount.map { "\(gpu.name) · \($0) cores" } ?? gpu.name)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "rectangle.3.group.fill")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .macScopeGlassSurface(cornerRadius: 8)
                }
            }
        }
    }

    private func topologyNode(icon: String, title: String, detail: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(12)
        .macScopeGlassSurface(cornerRadius: 10)
    }
}

private struct RawSnapshotVisualSummary: Hashable {
    var timestamp: Date?
    var processCount = 0
    var startupCount = 0
    var connectionCount = 0
    var metricCount = 0
    var qualityCounts: [MetricQuality: Int] = [:]

    init() {}

    init(snapshot: SystemSnapshot) {
        timestamp = snapshot.timestamp
        processCount = snapshot.processes.count
        startupCount = snapshot.startupItems.count
        connectionCount = snapshot.connections.count
        metricCount = snapshot.metrics.count
        qualityCounts = Dictionary(grouping: snapshot.metrics, by: \MetricSample.quality).mapValues(\.count)
    }
}

private struct RawSnapshotVisualSection: View {
    let summary: RawSnapshotVisualSummary

    private var collectionMetrics: [RankedMetric] {
        [
            RankedMetric(id: "processes", label: "Processes", value: Double(summary.processCount), tint: MacScopeTheme.accent),
            RankedMetric(id: "startup", label: "Startup", value: Double(summary.startupCount), tint: MacScopeTheme.cyan),
            RankedMetric(id: "connections", label: "Connections", value: Double(summary.connectionCount), tint: .purple),
            RankedMetric(id: "metrics", label: "Metrics", value: Double(summary.metricCount), tint: .green)
        ]
    }

    private var qualitySegments: [DistributionSegment] {
        [
            DistributionSegment(id: MetricQuality.measured.rawValue, label: "Measured", value: Double(summary.qualityCounts[.measured, default: 0]), tint: .green),
            DistributionSegment(id: MetricQuality.derived.rawValue, label: "Derived", value: Double(summary.qualityCounts[.derived, default: 0]), tint: MacScopeTheme.accent),
            DistributionSegment(id: MetricQuality.estimated.rawValue, label: "Estimated", value: Double(summary.qualityCounts[.estimated, default: 0]), tint: .orange)
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VisualPanel(
                title: "Captured collections",
                subtitle: captureSubtitle,
                availability: summary.timestamp == nil ? .stale : .available,
                height: DataVisualLayout.rawPanelHeight
            ) {
                if summary.timestamp == nil {
                    ProgressView("Capturing snapshot…").frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    RankedMetricBars(items: collectionMetrics, unit: "items", maximumCount: 4, height: 112)
                }
            }
            .frame(maxWidth: .infinity)

            VisualPanel(
                title: "Metric provenance",
                subtitle: "Quality labels carried by this captured snapshot",
                availability: summary.metricCount == 0 ? .degraded : .available,
                height: DataVisualLayout.rawPanelHeight
            ) {
                if summary.metricCount == 0 {
                    ContentUnavailableView("No metric samples", systemImage: "chart.pie", description: Text("This captured snapshot contains no normalized metric samples."))
                        .frame(height: 112)
                } else {
                    StatusComposition(
                        segments: qualitySegments,
                        centerTitle: "Samples",
                        centerValue: summary.metricCount.formatted()
                    )
                    .frame(height: 112)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var captureSubtitle: String {
        guard let timestamp = summary.timestamp else { return "Preparing a bounded normalized snapshot" }
        return "Counts captured with the JSON at \(timestamp.formatted(date: .omitted, time: .standard))"
    }
}

private func dataRate(_ value: Double) -> String { "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary))/s" }
private func cpuPercent(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...1))))%" }
private func uptime(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: interval) ?? "Unknown"
}
