import AppKit
import MacScopeCore
import Observation
import SwiftUI

private enum MacOSFeatureListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case recommended = "Recommended"
    case enabled = "Enabled"
    case disabled = "Disabled"
    case manual = "System Settings"
    case attention = "Needs attention"

    var id: String { rawValue }
}

private extension MacOSFeatureCategory {
    var icon: String {
        switch self {
        case .appearance: "paintbrush.fill"
        case .finder: "folder.fill"
        case .dock: "dock.rectangle"
        case .windows: "macwindow.on.rectangle"
        case .keyboard: "keyboard.fill"
        case .pointer: "cursorarrow.motionlines"
        case .menuBar: "menubar.rectangle"
        case .capture: "camera.viewfinder"
        case .files: "internaldrive.fill"
        case .applications: "app.dashed"
        case .developer: "hammer.fill"
        case .accessibility: "accessibility"
        case .security: "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appearance, .finder: MacScopeTheme.accent
        case .dock, .windows: .indigo
        case .keyboard, .pointer: MacScopeTheme.cyan
        case .menuBar, .capture: .purple
        case .files: .teal
        case .applications: .blue
        case .developer: .orange
        case .accessibility: .green
        case .security: .red
        }
    }
}

@MainActor
@Observable
private final class MacOSFeaturesViewModel {
    var statuses: [MacOSFeatureStatus] = []
    var query = ""
    var category: MacOSFeatureCategory?
    var filter: MacOSFeatureListFilter = .all
    var isLoading = false
    var isApplying = false
    var errorMessage: String?
    var lastChange: MacOSFeatureChange?

    private let manager = MacOSFeatureManager()

    var filteredStatuses: [MacOSFeatureStatus] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return statuses.filter { status in
            if let category, status.descriptor.category != category { return false }
            switch filter {
            case .all: break
            case .recommended where status.descriptor.tier != .recommended: return false
            case .enabled where status.state != .enabled: return false
            case .disabled where status.state != .disabled: return false
            case .manual:
                if case .manual = status.descriptor.mechanism { break }
                return false
            case .attention:
                if case .manual = status.descriptor.mechanism { return false }
                if status.availability == .available { return false }
            default: break
            }
            guard !needle.isEmpty else { return true }
            let descriptor = status.descriptor
            let searchable = [
                descriptor.title,
                descriptor.summary,
                descriptor.category.rawValue,
                descriptor.provenance,
                mechanismSearchText(descriptor.mechanism)
            ].joined(separator: " ")
            return searchable.localizedCaseInsensitiveContains(needle)
        }
    }

    var directCount: Int {
        statuses.count {
            if case .preference = $0.descriptor.mechanism { return true }
            return false
        }
    }
    var manualCount: Int {
        statuses.count {
            if case .manual = $0.descriptor.mechanism { return true }
            return false
        }
    }
    var restrictedCount: Int { statuses.count { $0.availability == .restricted } }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let values = await manager.refresh()
            statuses = values
            isLoading = false
        }
    }

    func apply(descriptorID: String, enabled: Bool) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        defer { isApplying = false }
        do {
            let change = try await manager.setEnabled(enabled, descriptorID: descriptorID)
            lastChange = change
            if let note = change.note { errorMessage = note }
            statuses = await manager.refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            statuses = await manager.refresh()
            return false
        }
    }

    func undoLastChange() async {
        guard let lastChange, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try await manager.restore(lastChange)
            self.lastChange = nil
            statuses = await manager.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mechanismSearchText(_ mechanism: MacOSFeatureMechanism) -> String {
        switch mechanism {
        case .manual(let reason, _): return reason
        case .restricted(let reason): return reason
        case .preference(let preference): return "\(preference.domain) \(preference.key)"
        }
    }
}

struct MacOSFeaturesView: View {
    @State private var viewModel = MacOSFeaturesViewModel()
    @State private var selection: MacOSFeatureStatus.ID?
    @State private var pendingChange: PendingFeatureChange?
    @AppStorage("expertModeEnabled") private var expertModeEnabled = false

    private var selectedStatus: MacOSFeatureStatus? {
        guard let selection else { return nil }
        return viewModel.statuses.first { $0.id == selection }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        GeometryReader { proxy in
            let layout = MacOSFeaturesLayout(width: proxy.size.width)
            let filteredStatuses = viewModel.filteredStatuses

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                    FeaturePageHeader(
                        isCompact: layout.isCompact,
                        showsUndo: viewModel.lastChange != nil,
                        isUndoDisabled: viewModel.isApplying,
                        isRefreshDisabled: viewModel.isLoading || viewModel.isApplying,
                        onUndo: { Task { await viewModel.undoLastChange() } },
                        onRefresh: viewModel.refresh
                    )

                    if !(layout.isCompact && selectedStatus != nil) {
                        FeatureSummaryGrid(
                            columns: layout.summaryColumnCount,
                            catalogCount: viewModel.statuses.count,
                            directCount: viewModel.directCount,
                            manualCount: viewModel.manualCount,
                            restrictedCount: viewModel.restrictedCount
                        )

                        FeatureToolbar(
                            query: $viewModel.query,
                            filter: $viewModel.filter,
                            category: $viewModel.category,
                            count: filteredStatuses.count,
                            isCompact: layout.isCompact
                        )
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, layout.topPadding)
                .padding(.bottom, layout.bottomPadding)

                Divider()

                FeatureCatalogContent(
                    statuses: filteredStatuses,
                    selection: $selection,
                    selectedStatus: selectedStatus,
                    isCompact: layout.isCompact,
                    expertModeEnabled: expertModeEnabled,
                    isApplying: viewModel.isApplying,
                    onToggle: requestChange
                )
            }
            .animation(.snappy(duration: 0.24), value: layout.isCompact)
            .animation(.snappy(duration: 0.24), value: selection)
        }
        .navigationTitle("macOS Features")
        .task {
            if viewModel.statuses.isEmpty { viewModel.refresh() }
        }
        .onChange(of: viewModel.filteredStatuses.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .sheet(item: $pendingChange) { change in
            FeatureChangeConfirmation(change: change, isApplying: viewModel.isApplying) {
                let succeeded = await viewModel.apply(descriptorID: change.status.id, enabled: change.enabled)
                if succeeded { pendingChange = nil }
            } onCancel: {
                pendingChange = nil
            }
        }
        .alert("macOS feature", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .overlay {
            if viewModel.isLoading && viewModel.statuses.isEmpty {
                ProgressView("Reading macOS preferences…")
                    .padding(18)
                    .macScopeGlassSurface(cornerRadius: 12)
            }
        }
    }

    private func requestChange(_ status: MacOSFeatureStatus, _ enabled: Bool) {
        guard status.availability == .available || status.availability == .unmapped else { return }
        guard status.descriptor.tier != .experimental || expertModeEnabled else {
            viewModel.errorMessage = "Enable Expert Mode in MacScope Settings before changing experimental preferences."
            return
        }
        pendingChange = PendingFeatureChange(status: status, enabled: enabled)
    }
}

private struct MacOSFeaturesLayout {
    let width: CGFloat

    var isCompact: Bool { width < 900 }
    var summaryColumnCount: Int { isCompact ? 2 : 4 }
    var horizontalPadding: CGFloat { isCompact ? 16 : 24 }
    var topPadding: CGFloat { isCompact ? 16 : 22 }
    var bottomPadding: CGFloat { isCompact ? 12 : 14 }
    var sectionSpacing: CGFloat { isCompact ? 12 : 16 }
}

private struct FeaturePageHeader: View {
    let isCompact: Bool
    let showsUndo: Bool
    let isUndoDisabled: Bool
    let isRefreshDisabled: Bool
    let onUndo: () -> Void
    let onRefresh: () -> Void

    @ViewBuilder
    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 11) {
                header
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                header
                    .layoutPriority(1)
                actions
                    .fixedSize()
            }
        }
    }

    private var header: some View {
        SectionHeader(
            title: "macOS Features",
            subtitle: "Discover, inspect, enable, and restore hidden and useful system preferences"
        )
    }

    @ViewBuilder private var actions: some View {
        if showsUndo {
            Button("Undo last change", systemImage: "arrow.uturn.backward", action: onUndo)
                .disabled(isUndoDisabled)
                .macScopeGlassButton()
        }
        Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            .disabled(isRefreshDisabled)
            .macScopeGlassButton()
    }
}

private struct FeatureSummaryGrid: View {
    let columns: Int
    let catalogCount: Int
    let directCount: Int
    let manualCount: Int
    let restrictedCount: Int

    var body: some View {
        GlassGroup {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: columns),
                spacing: 12
            ) {
                FeatureSummaryCard(title: "Catalog", value: catalogCount, icon: "switch.2", tint: MacScopeTheme.accent)
                FeatureSummaryCard(title: "Direct controls", value: directCount, icon: "checkmark.circle", tint: .green)
                FeatureSummaryCard(title: "System Settings", value: manualCount, icon: "gear", tint: .blue)
                FeatureSummaryCard(title: "Protected", value: restrictedCount, icon: "lock.shield", tint: .purple)
            }
        }
    }
}

private struct FeatureCatalogContent: View {
    let statuses: [MacOSFeatureStatus]
    @Binding var selection: MacOSFeatureStatus.ID?
    let selectedStatus: MacOSFeatureStatus?
    let isCompact: Bool
    let expertModeEnabled: Bool
    let isApplying: Bool
    let onToggle: (MacOSFeatureStatus, Bool) -> Void

    var body: some View {
        if isCompact {
            if let selectedStatus {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button("All features", systemImage: "chevron.left") {
                            selection = nil
                        }
                        .macScopeGlassButton()
                        Text(selectedStatus.descriptor.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar.opacity(0.7))

                    Divider()

                    FeatureInspector(
                        status: selectedStatus,
                        expertModeEnabled: expertModeEnabled,
                        isApplying: isApplying,
                        onToggle: onToggle
                    )
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                FeatureCatalogList(
                    statuses: statuses,
                    selection: $selection,
                    isApplying: isApplying,
                    onToggle: onToggle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        } else {
            HSplitView {
                FeatureCatalogList(
                    statuses: statuses,
                    selection: $selection,
                    isApplying: isApplying,
                    onToggle: onToggle
                )
                .frame(minWidth: 380, idealWidth: 500)

                Group {
                    if let selectedStatus {
                        FeatureInspector(
                            status: selectedStatus,
                            expertModeEnabled: expertModeEnabled,
                            isApplying: isApplying,
                            onToggle: onToggle
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a feature",
                            systemImage: "switch.2",
                            description: Text("Its current value, exact preference key, source, and restart requirements will appear here.")
                        )
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FeatureSummaryCard: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(value.formatted())
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58)
        .macScopeGlassSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }
}

private struct FeatureToolbar: View {
    @Binding var query: String
    @Binding var filter: MacOSFeatureListFilter
    @Binding var category: MacOSFeatureCategory?
    let count: Int
    let isCompact: Bool

    var body: some View {
        if isCompact {
            VStack(spacing: 9) {
                searchField
                    .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    statusPicker
                        .frame(maxWidth: .infinity)
                    categoryPicker
                        .frame(maxWidth: .infinity)
                }
                resultCount
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 12) {
                searchField
                    .frame(minWidth: 240, idealWidth: 330, maxWidth: .infinity)
                statusPicker
                    .frame(width: 150)
                categoryPicker
                    .frame(width: 190)
                resultCount
                    .fixedSize()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search title, category, domain, or key", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .macScopeGlassSurface(cornerRadius: 8)
    }

    private var statusPicker: some View {
        Picker("Status", selection: $filter) {
            ForEach(MacOSFeatureListFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $category) {
            Text("All categories").tag(MacOSFeatureCategory?.none)
            ForEach(MacOSFeatureCategory.allCases) { item in
                Text(item.rawValue).tag(Optional(item))
            }
        }
        .labelsHidden()
    }

    private var resultCount: some View {
        Text("\(count.formatted()) features")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }
}

private struct FeatureCatalogList: View {
    let statuses: [MacOSFeatureStatus]
    @Binding var selection: MacOSFeatureStatus.ID?
    let isApplying: Bool
    let onToggle: (MacOSFeatureStatus, Bool) -> Void
    @State private var collapsedCategories: Set<MacOSFeatureCategory> = []

    private var categorySections: [FeatureCategorySection] {
        let grouped = Dictionary(grouping: statuses) { $0.descriptor.category }
        return MacOSFeatureCategory.allCases.compactMap { category in
            guard let statuses = grouped[category], !statuses.isEmpty else { return nil }
            return FeatureCategorySection(category: category, statuses: statuses)
        }
    }

    var body: some View {
        if statuses.isEmpty {
            ContentUnavailableView.search(text: "the current filters")
        } else {
            GlassGroup(spacing: 8) {
                List(selection: $selection) {
                    ForEach(categorySections) { section in
                        Section(isExpanded: expansionBinding(for: section.category)) {
                            ForEach(section.statuses) { status in
                                FeatureRow(status: status, isApplying: isApplying, onToggle: onToggle)
                                    .tag(status.id)
                            }
                        } header: {
                            FeatureCategoryHeader(
                                category: section.category,
                                count: section.statuses.count
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func expansionBinding(for category: MacOSFeatureCategory) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategories.contains(category) },
            set: { isExpanded in
                withAnimation(.snappy(duration: 0.2)) {
                    if isExpanded {
                        collapsedCategories.remove(category)
                    } else {
                        collapsedCategories.insert(category)
                    }
                }
            }
        )
    }
}

private struct FeatureCategorySection: Identifiable {
    let category: MacOSFeatureCategory
    let statuses: [MacOSFeatureStatus]

    var id: MacOSFeatureCategory { category }
}

private struct FeatureCategoryHeader: View {
    let category: MacOSFeatureCategory
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(category.tint)
                .frame(width: 25, height: 25)
                .background(category.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(category.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(count.formatted())
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.09), in: Capsule())
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .padding(.trailing, 12)
        .textCase(nil)
        .accessibilityLabel("\(category.rawValue), \(count) features")
    }
}

private struct FeatureRow: View {
    let status: MacOSFeatureStatus
    let isApplying: Bool
    let onToggle: (MacOSFeatureStatus, Bool) -> Void

    private var canChange: Bool {
        status.availability == .available || status.availability == .unmapped
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.descriptor.icon)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(status.descriptor.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    FeatureTierBadge(tier: status.descriptor.tier)
                }
                Text(status.descriptor.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if canChange {
                FeatureLiquidGlassSwitch(
                    title: status.descriptor.title,
                    isOn: status.state == .enabled,
                    isEnabled: !isApplying && status.state != .unknown,
                    tint: status.descriptor.category.tint
                ) { enabled in
                    onToggle(status, enabled)
                }
            } else {
                FeatureAvailabilityBadge(status: status)
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        status.descriptor.category.tint
    }
}

private struct FeatureLiquidGlassSwitch: View {
    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let tint: Color
    let onChange: (Bool) -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            toggle
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .glassEffect(.regular.interactive(isEnabled), in: .capsule)
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { enabled in onChange(enabled) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(tint)
        .disabled(!isEnabled)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct FeatureInspector: View {
    let status: MacOSFeatureStatus
    let expertModeEnabled: Bool
    let isApplying: Bool
    let onToggle: (MacOSFeatureStatus, Bool) -> Void

    private var canChange: Bool {
        status.state != .unknown && (status.availability == .available || status.availability == .unmapped)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: status.descriptor.icon)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(MacScopeTheme.accent)
                            .frame(width: 50, height: 50)
                            .background(MacScopeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(status.descriptor.title).font(.title3.weight(.semibold))
                            Text(status.descriptor.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canChange {
                            FeatureLiquidGlassSwitch(
                                title: status.descriptor.title,
                                isOn: status.state == .enabled,
                                isEnabled: !isApplying,
                                tint: status.descriptor.category.tint
                            ) { enabled in
                                onToggle(status, enabled)
                            }
                        }
                    }
                    Text(status.descriptor.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        FeatureStateBadge(status: status)
                        FeatureTierBadge(tier: status.descriptor.tier)
                        if status.descriptor.tier == .experimental && !expertModeEnabled {
                            Label("Expert Mode required", systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(16)
                .macScopeGlassSurface(cornerRadius: 12)

                if let detail = status.detail {
                    Label(detail, systemImage: status.availability == .restricted ? "lock.shield" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(status.availability == .restricted ? .purple : .secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }

                FeatureTechnicalDetails(status: status)

                if case .manual(_, let rawURL) = status.descriptor.mechanism,
                   let rawURL,
                   let url = URL(string: rawURL) {
                    Button("Open System Settings", systemImage: "gear") {
                        NSWorkspace.shared.open(url)
                    }
                    .macScopeGlassButton(prominent: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Provenance").font(.headline)
                    Text(status.descriptor.provenance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let rawURL = status.descriptor.sourceURL, let url = URL(string: rawURL) {
                        Link("View implementation source", destination: url)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .macScopeGlassSurface(cornerRadius: 12)
            }
            .padding(18)
        }
    }
}

private struct FeatureTechnicalDetails: View {
    let status: MacOSFeatureStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exact change").font(.headline)
            switch status.descriptor.mechanism {
            case .manual(let reason, _):
                LabeledContent("Operation", value: "Open System Settings")
                Text(reason).font(.callout).foregroundStyle(.secondary)
            case .restricted(let reason):
                LabeledContent("Operation", value: "Not offered")
                Text(reason).font(.callout).foregroundStyle(.secondary)
            case .preference(let preference):
                TechnicalValue(label: "Domain", value: preference.domain)
                TechnicalValue(label: "Key", value: preference.key)
                TechnicalValue(label: "Current", value: (status.storedValue ?? preference.defaultValue).displayValue)
                TechnicalValue(label: "Enabled", value: preference.enabledValue.displayValue)
                TechnicalValue(label: "Disabled", value: preference.disabledValue.displayValue)
                LabeledContent("Apply", value: preference.restart.displayName)
            }
            LabeledContent("macOS", value: osRange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.callout)
        .padding(16)
        .macScopeGlassSurface(cornerRadius: 12)
    }

    private var osRange: String {
        if let maximum = status.descriptor.maximumOSMajor {
            return "\(status.descriptor.minimumOSMajor)–\(maximum)"
        }
        return "\(status.descriptor.minimumOSMajor)+"
    }
}

private struct TechnicalValue: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct FeatureStateBadge: View {
    let status: MacOSFeatureStatus

    @ViewBuilder
    var body: some View {
        if shouldDisplay {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: Capsule())
        }
    }

    private var shouldDisplay: Bool {
        if case .manual = status.descriptor.mechanism { return true }
        switch status.state {
        case .enabled, .disabled:
            return true
        case .unknown:
            return status.availability != .available && status.availability != .degraded
        }
    }

    private var label: String {
        if case .manual = status.descriptor.mechanism { return "System Settings" }
        switch status.state {
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .unknown: return status.availability.rawValue.capitalized
        }
    }

    private var color: Color {
        if case .manual = status.descriptor.mechanism { return .blue }
        switch status.state {
        case .enabled: return .green
        case .disabled: return .secondary
        case .unknown: return status.availability == .restricted ? .purple : .orange
        }
    }
}

private struct FeatureAvailabilityBadge: View {
    let status: MacOSFeatureStatus

    @ViewBuilder
    var body: some View {
        if shouldDisplay {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
        }
    }

    private var shouldDisplay: Bool {
        if case .manual = status.descriptor.mechanism { return true }
        return status.availability != .available && status.availability != .degraded
    }

    private var label: String {
        if case .manual = status.descriptor.mechanism { return "System Settings" }
        return status.availability.rawValue.capitalized
    }

    private var color: Color {
        if case .manual = status.descriptor.mechanism { return .blue }
        return status.availability == .restricted ? .purple : .orange
    }
}

private struct FeatureTierBadge: View {
    let tier: MacOSFeatureTier

    var body: some View {
        Text(tier.rawValue.capitalized)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var color: Color {
        switch tier {
        case .recommended: .green
        case .advanced: .blue
        case .experimental: .orange
        case .restricted: .purple
        }
    }
}

private struct PendingFeatureChange: Identifiable {
    let status: MacOSFeatureStatus
    let enabled: Bool
    var id: String { "\(status.id)-\(enabled)" }
}

private struct FeatureChangeConfirmation: View {
    let change: PendingFeatureChange
    let isApplying: Bool
    let onApply: () async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: change.status.descriptor.icon)
                    .font(.title2)
                    .foregroundStyle(MacScopeTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(MacScopeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(change.enabled ? "Enable feature?" : "Disable feature?")
                        .font(.title3.weight(.semibold))
                    Text(change.status.descriptor.title).foregroundStyle(.secondary)
                }
            }

            Text(change.status.descriptor.summary)
                .font(.callout)

            if case .preference(let preference) = change.status.descriptor.mechanism {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    confirmationRow("Target", "\(preference.domain) / \(preference.key)")
                    confirmationRow("Current", (change.status.storedValue ?? preference.defaultValue).displayValue)
                    confirmationRow("New value", (change.enabled ? preference.enabledValue : preference.disabledValue).displayValue)
                    confirmationRow("Expected effect", preference.restart.displayName)
                    confirmationRow("Reversible", "Yes — Undo restores the prior stored value")
                }
                .font(.callout)
                .padding(14)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(change.enabled ? "Enable" : "Disable") {
                    Task { await onApply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
                .macScopeGlassButton(prominent: true)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private func confirmationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}
