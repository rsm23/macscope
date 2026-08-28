import AppKit
import MacScopeCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsTab: String, CaseIterable, Identifiable {
    case features = "Features"
    case general = "General"
    case privacy = "Privacy"
    case alerts = "Alerts"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .features: "square.grid.3x3.fill"
        case .general: "gear"
        case .privacy: "hand.raised"
        case .alerts: "bell.badge"
        case .permissions: "lock.shield"
        }
    }
}

struct SettingsView: View, @preconcurrency Equatable {
    let model: AppModel
    @AppStorage("samplingProfile") private var samplingProfile = SamplingProfile.balanced.rawValue
    @AppStorage("processHistoryEnabled") private var processHistoryEnabled = false
    @AppStorage("expertModeEnabled") private var expertModeEnabled = false
    @AppStorage("redactExports") private var redactExports = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appAppearance") private var appAppearance = MacScopeAppearance.system.rawValue
    @AppStorage("menuBarPanelTabOrder") private var menuBarPanelTabOrder = ""
    @AppStorage("menuBarPanelHiddenTabs") private var menuBarPanelHiddenTabs = ""
    @AppStorage("menuBarReadoutMetrics") private var menuBarReadoutMetrics = MenuBarReadoutMetric.cpu.rawValue
    @AppStorage("menuBarReadoutStyle") private var menuBarReadoutStyle = MenuBarReadoutStyle.values.rawValue
    @AppStorage("radialMenuActiveProfile") private var radialMenuActiveProfile = RadialMenuProfile.work.rawValue
    @AppStorage("radialMenuConfigurations") private var radialMenuConfigurations = ""
    @AppStorage("radialMenuTargets") private var radialMenuTargets = ""
    @AppStorage("radialMenuThemes") private var radialMenuThemes = ""
    @AppStorage("radialMenuKeyShortcuts") private var radialMenuKeyShortcuts = ""
    @AppStorage("workspace.shelfEdgeEnabled") private var shelfEdgeEnabled = false
    @AppStorage("workspace.shelfScreenEdge") private var shelfScreenEdge = ShelfScreenEdge.left.rawValue
    @AppStorage("workspace.shelfTopDropZoneEnabled") private var shelfTopDropZoneEnabled = true
    @State private var helperStatus = "Checking…"
    @State private var mcpConfigurationStatus: String?
    @State private var mcpConnections: [MCPClientSession] = []
    @State private var mcpConnectionError: String?
    @State private var settingsPortabilityStatus: String?
    @State private var pendingImportedSettings: [String: Any]?
    @State private var confirmsSettingsImport = false
    @State private var shortcutRevision = 0
    @State private var radialMenuStatus: String?
    @State private var selectedTab = SettingsTab.general

    private var helperService: SMAppService {
        .daemon(plistName: "local.taskmanager.MacScope.Helper.plist")
    }

    static func == (lhs: SettingsView, rhs: SettingsView) -> Bool {
        lhs.model === rhs.model
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selectedTab)
            Divider()

            Group {
                switch selectedTab {
                case .features:
                    FeatureHubSettingsView()

                case .general:
                    SettingsPage(
                title: "Sampling",
                subtitle: "Balance update frequency with battery and CPU impact.",
                icon: "waveform.path.ecg"
            ) {
                SettingsSamplingGraphic(
                    profile: SamplingProfile(rawValue: samplingProfile) ?? .balanced,
                    isRunning: model.isRunning
                )

                SettingsSection(title: "Collection") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Sampling profile",
                                detail: "Controls how frequently live collectors refresh.",
                                icon: "dial.medium"
                            )
                            Spacer(minLength: 20)
                            Picker("Sampling profile", selection: $samplingProfile) {
                                Text("Low impact").tag(SamplingProfile.lowImpact.rawValue)
                                Text("Balanced").tag(SamplingProfile.balanced.rawValue)
                                Text("Maximum").tag(SamplingProfile.maximum.rawValue)
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: samplingProfile) { _, value in
                            if let profile = SamplingProfile(rawValue: value) { model.setProfile(profile) }
                        }

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Launch at login",
                            detail: "Start monitoring automatically after you sign in.",
                            icon: "power",
                            isOn: $launchAtLogin
                        )
                        .onChange(of: launchAtLogin) { _, enabled in configureLogin(enabled) }

                        SettingsDivider()

                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Live status",
                                detail: model.isRunning ? "Collectors are actively sampling this Mac." : "Telemetry collection is currently paused.",
                                icon: model.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle"
                            )
                            Spacer(minLength: 20)
                            Label(model.isRunning ? "Sampling" : "Paused", systemImage: model.isRunning ? "circle.fill" : "pause.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(model.isRunning ? .green : .orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SettingsSection(title: "Settings portability") {
                    HStack(spacing: 16) {
                        SettingsRowLabel(
                            title: "Export or import configuration",
                            detail: "Moves feature preferences between Macs. Scratchpads, snippets, clipboard data and history are excluded.",
                            icon: "arrow.left.arrow.right.square"
                        )
                        Spacer(minLength: 20)
                        Button("Export…", systemImage: "square.and.arrow.up") { exportSettings() }
                            .macScopeGlassButton()
                        Button("Import…", systemImage: "square.and.arrow.down") { chooseSettingsImport() }
                            .macScopeGlassButton()
                    }
                    if let settingsPortabilityStatus {
                        Text(settingsPortabilityStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }

                SettingsSection(title: "Appearance") {
                    HStack(spacing: 16) {
                        SettingsRowLabel(
                            title: "MacScope appearance",
                            detail: "Follow macOS or keep every MacScope surface consistently light or dark.",
                            icon: "circle.lefthalf.filled"
                        )
                        Spacer(minLength: 20)
                        Picker("Appearance", selection: $appAppearance) {
                            ForEach(MacScopeAppearance.allCases) { appearance in
                                Text(appearance.rawValue).tag(appearance.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                SettingsSection(title: "Menu bar readout") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Live menu bar metrics",
                                detail: "Choose up to four values. Battery time and fan speed remain unavailable when macOS or the hardware does not report them.",
                                icon: "menubar.rectangle"
                            )
                            Spacer(minLength: 20)
                            Picker("Readout style", selection: $menuBarReadoutStyle) {
                                ForEach(MenuBarReadoutStyle.allCases) { style in
                                    Text(style.rawValue).tag(style.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(MenuBarReadoutMetric.allCases) { metric in
                                Toggle(metric.rawValue, isOn: menuBarReadoutBinding(metric))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }

                SettingsSection(title: "Dock and Quick preview") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(MenuBarPanelTab.ordered(from: menuBarPanelTabOrder).enumerated()), id: \.element.id) { index, tab in
                            HStack(spacing: 12) {
                                Image(systemName: tab.icon)
                                    .foregroundStyle(MacScopeTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.rawValue).font(.callout.weight(.medium))
                                    Text(tab.isRequired
                                         ? "Always shown so live audio and disk data stay available."
                                         : "Optional preview tab.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !tab.isRequired {
                                    Toggle("Shown", isOn: previewTabVisibilityBinding(tab))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                                Button {
                                    movePreviewTab(at: index, offset: -1)
                                } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)
                                    .help("Move up")
                                Button {
                                    movePreviewTab(at: index, offset: 1)
                                } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.plain)
                                    .disabled(index == MenuBarPanelTab.allCases.count - 1)
                                    .help("Move down")
                            }
                            .padding(.vertical, 8)
                            if index < MenuBarPanelTab.allCases.count - 1 { SettingsDivider() }
                        }
                    }
                }

                SettingsSection(title: "Radial menu") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Active profile",
                                detail: "Open at the pointer with Control-Option-Space. Each profile keeps eight independent actions.",
                                icon: "circle.hexagongrid.fill"
                            )
                            Spacer(minLength: 20)
                            Picker("Radial menu profile", selection: $radialMenuActiveProfile) {
                                ForEach(RadialMenuProfile.allCases) { profile in
                                    Text(profile.rawValue).tag(profile.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            Picker("Theme", selection: radialThemeBinding) {
                                ForEach(RadialMenuTheme.allCases) { theme in
                                    Text(theme.rawValue).tag(theme)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 105)
                        }
                        .padding(.vertical, 8)

                        SettingsDivider()

                        HStack(spacing: 12) {
                            Image(systemName: "tray.full").foregroundStyle(MacScopeTheme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Session Shelf").font(.callout.weight(.medium))
                                Text("Drag files or folders to the screen top, navigate in Finder, then click the shelf to move them.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Top drop zone", isOn: $shelfTopDropZoneEnabled)
                                .toggleStyle(.switch)
                                .fixedSize()
                        }
                        .padding(.vertical, 8)

                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(MacScopeTheme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shelf edge shortcut").font(.callout.weight(.medium))
                                Text("Open the full shelf with Control-Option-S or dwell at a chosen edge for 0.55 seconds.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Edge", isOn: $shelfEdgeEnabled).labelsHidden().toggleStyle(.switch)
                            Picker("Shelf edge", selection: $shelfScreenEdge) {
                                ForEach(ShelfScreenEdge.allCases) { edge in Text(edge.rawValue).tag(edge.rawValue) }
                            }
                            .labelsHidden().frame(width: 100).disabled(!shelfEdgeEnabled)
                        }
                        .padding(.vertical, 8)

                        SettingsDivider()

                        ForEach(0..<8, id: \.self) { index in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.06), in: Circle())
                                Image(systemName: radialActionBinding(at: index).wrappedValue.icon)
                                    .foregroundStyle(MacScopeTheme.accent)
                                    .frame(width: 22)
                                Text("Slot \(index + 1)")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Picker("Slot \(index + 1)", selection: radialActionBinding(at: index)) {
                                    ForEach(RadialMenuAction.allCases) { action in
                                        Label(action.rawValue, systemImage: action.icon).tag(action)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 185)
                                if radialActionBinding(at: index).wrappedValue == .customItem {
                                    Menu {
                                        Button("Choose App, File or Folder…", systemImage: "folder") {
                                            chooseRadialTarget(at: index)
                                        }
                                        Button("Enter Web Link…", systemImage: "link") {
                                            enterRadialLink(at: index)
                                        }
                                        if let target = radialTarget(at: index), !target.url.isFileURL {
                                            Button("Fetch Website Icon", systemImage: "photo.badge.arrow.down") {
                                                fetchRadialWebsiteIcon(for: target, at: index)
                                            }
                                        }
                                        if radialTarget(at: index) != nil {
                                            Divider()
                                            Button("Remove Target", systemImage: "trash", role: .destructive) {
                                                setRadialTarget(nil, at: index)
                                            }
                                        }
                                    } label: {
                                        Text(radialTarget(at: index)?.title ?? "Choose…")
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: 120)
                                } else if radialActionBinding(at: index).wrappedValue == .keyCombo {
                                    Picker("Modifiers", selection: radialShortcutModifierBinding(at: index)) {
                                        ForEach(GlobalShortcutModifier.allCases) { modifier in
                                            Text(modifier.label).tag(modifier)
                                        }
                                    }
                                    .labelsHidden().frame(width: 76)
                                    Picker("Key", selection: radialShortcutKeyBinding(at: index)) {
                                        ForEach(GlobalShortcutKey.choices) { key in
                                            Text(key.label).tag(key.keyCode)
                                        }
                                    }
                                    .labelsHidden().frame(width: 74)
                                }
                            }
                            .padding(.vertical, 7)
                            if index < 7 { SettingsDivider() }
                        }
                        if let radialMenuStatus {
                            Text(radialMenuStatus)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                }

                SettingsSection(title: "Global keyboard shortcuts") {
                    VStack(alignment: .leading, spacing: 0) {
                        let installedShortcuts = GlobalShortcutAction.allCases.filter(\.isInstalled)
                        ForEach(Array(installedShortcuts.enumerated()), id: \.element.id) { index, action in
                            let configuration = GlobalShortcutStore.configuration(for: action)
                            HStack(spacing: 12) {
                                Image(systemName: action.icon)
                                    .foregroundStyle(MacScopeTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title).font(.callout.weight(.medium))
                                    Text(GlobalShortcutStore.conflicts().contains(action)
                                         ? "Resolve this duplicate before the shortcut becomes active."
                                         : configuration.displayLabel)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(GlobalShortcutStore.conflicts().contains(action) ? .red : .secondary)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: globalShortcutEnabledBinding(action))
                                    .labelsHidden().toggleStyle(.switch)
                                Picker("Modifiers", selection: globalShortcutModifierBinding(action)) {
                                    ForEach(GlobalShortcutModifier.allCases) { modifier in
                                        Text(modifier.label).tag(modifier)
                                    }
                                }
                                .labelsHidden().frame(width: 82)
                                Picker("Key", selection: globalShortcutKeyBinding(action)) {
                                    ForEach(GlobalShortcutKey.choices) { key in
                                        Text(key.label).tag(key.keyCode)
                                    }
                                }
                                .labelsHidden().frame(width: 88)
                            }
                            .id(shortcutRevision)
                            .padding(.vertical, 7)
                            if index < installedShortcuts.count - 1 { SettingsDivider() }
                        }
                    }
                }
                    }

                case .privacy:
                    SettingsPage(
                        title: "Privacy & data",
                        subtitle: "MacScope keeps telemetry local and gives you control over retained details.",
                        icon: "hand.raised.fill"
                    ) {
                SettingsSection(title: "Local history") {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsToggleRow(
                            title: "Store encrypted process history",
                            detail: "Off by default. When enabled, history is encrypted with an AES-256 key stored in Keychain.",
                            icon: "clock.arrow.circlepath",
                            isOn: $processHistoryEnabled
                        )
                        .onChange(of: processHistoryEnabled) { _, enabled in model.setProcessHistoryEnabled(enabled) }

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Redact sensitive export fields",
                            detail: "Hide usernames, paths, addresses, identifiers, and command arguments by default.",
                            icon: "eye.slash",
                            isOn: $redactExports
                        )
                    }
                }

                SettingsSection(title: "Data boundary") {
                    Label {
                        Text("MacScope does not upload telemetry or expose a network-facing API. Exported files stay under your control.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(MacScopeTheme.cyan)
                    }
                }
                    }

                case .alerts:
                    UsageAlertsSettingsView(model: model)

                case .permissions:
                    SettingsPage(
                        title: "Permissions & helper",
                        subtitle: "Check every utility authorization and request access again when needed.",
                        icon: "lock.shield.fill"
                    ) {
                PermissionChecklistView()

                SettingsSection(title: "Advanced controls") {
                    SettingsToggleRow(
                        title: "Expert Mode",
                        detail: "Enables typed process and launchd operations. SIP and TCC restrictions are always respected.",
                        icon: "wrench.and.screwdriver",
                        isOn: $expertModeEnabled
                    )
                }

                SettingsSection(title: "Privileged helper") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: helperService.status == .enabled ? "checkmark.shield.fill" : "lock.shield")
                                .font(.title2)
                                .foregroundStyle(helperService.status == .enabled ? .green : .orange)
                                .frame(width: 38, height: 38)
                                .background((helperService.status == .enabled ? Color.green : .orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(helperService.status == .enabled ? "Helper installed" : "Helper not active")
                                    .font(.headline)
                                Text(helperStatus)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Check", systemImage: "arrow.clockwise") { checkHelper() }
                                .macScopeGlassButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        HStack(spacing: 10) {
                            if helperService.status == .enabled {
                                Button("Remove Helper", systemImage: "trash", role: .destructive) {
                                    configureHelper(enabled: false)
                                }
                                .tint(.red)
                                .macScopeGlassButton()
                            } else {
                                Button("Install Helper", systemImage: "square.and.arrow.down") {
                                    configureHelper(enabled: true)
                                }
                                .macScopeGlassButton(prominent: true)
                            }
                            Spacer()
                            Button("Open Login Items", systemImage: "gear") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .macScopeGlassButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SettingsSection(title: "AI agent access") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.title2)
                                .foregroundStyle(mcpServerIsBundled ? .green : .orange)
                                .frame(width: 38, height: 38)
                                .background((mcpServerIsBundled ? Color.green : .orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mcpServerIsBundled ? "MCP server ready" : "MCP server unavailable")
                                    .font(.headline)
                                Text(mcpServerIsBundled
                                     ? "Local stdio server with redacted read access by default."
                                     : "Build the packaged MacScope app to bundle the MCP executable.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let mcpConfigurationStatus {
                                Label(mcpConfigurationStatus, systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        Text("Read-only configuration exposes all supported telemetry and feature states. Write-enabled configuration additionally permits expiring, preflighted, reversible changes to MacScope's typed feature allowlist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                mcpConfigurationButtons
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                mcpConfigurationButtons
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        MCPConnectionsView(
                            sessions: mcpConnections,
                            errorMessage: mcpConnectionError
                        )
                    }
                }
                    }
                }
            }
        }
        .frame(width: 700, height: 560)
        .task {
            checkHelper()
            await monitorMCPConnections()
        }
        .confirmationDialog(
            "Import MacScope settings?",
            isPresented: $confirmsSettingsImport,
            titleVisibility: .visible
        ) {
            Button("Import and Restart Later") { applySettingsImport() }
            Button("Cancel", role: .cancel) { pendingImportedSettings = nil }
        } message: {
            Text("This replaces the matching feature preferences in this account. Personal scratchpads, snippets and clipboard data are not imported. Restart MacScope afterward so every service reloads its configuration.")
        }
    }

    private func exportSettings() {
        let settings = UserDefaults.standard.dictionaryRepresentation().filter { Self.isPortableSetting($0.key) }
        guard PropertyListSerialization.propertyList(settings, isValidFor: .xml) else {
            settingsPortabilityStatus = "The current settings could not be encoded as a property list."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export MacScope Settings"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "MacScope-Settings.plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: settings,
                format: .xml,
                options: 0
            )
            try data.write(to: url, options: .atomic)
            settingsPortabilityStatus = "Exported \(settings.count) settings to \(url.lastPathComponent)."
        } catch {
            settingsPortabilityStatus = error.localizedDescription
        }
    }

    private func previewTabVisibilityBinding(_ tab: MenuBarPanelTab) -> Binding<Bool> {
        Binding(
            get: { !MenuBarPanelTab.hidden(from: menuBarPanelHiddenTabs).contains(tab) },
            set: { shown in
                var hidden = MenuBarPanelTab.hidden(from: menuBarPanelHiddenTabs)
                if shown { hidden.remove(tab) } else if !tab.isRequired { hidden.insert(tab) }
                menuBarPanelHiddenTabs = MenuBarPanelTab.allCases
                    .filter(hidden.contains)
                    .map(\.rawValue)
                    .joined(separator: "|")
            }
        )
    }

    private func menuBarReadoutBinding(_ metric: MenuBarReadoutMetric) -> Binding<Bool> {
        Binding(
            get: { MenuBarReadoutMetric.selected(from: menuBarReadoutMetrics).contains(metric) },
            set: { included in
                var selected = MenuBarReadoutMetric.selected(from: menuBarReadoutMetrics)
                if included, !selected.contains(metric), selected.count < 4 {
                    selected.append(metric)
                } else if !included, selected.count > 1 {
                    selected.removeAll { $0 == metric }
                }
                menuBarReadoutMetrics = selected.map(\.rawValue).joined(separator: "|")
            }
        )
    }

    private func movePreviewTab(at index: Int, offset: Int) {
        var tabs = MenuBarPanelTab.ordered(from: menuBarPanelTabOrder)
        let destination = index + offset
        guard tabs.indices.contains(index), tabs.indices.contains(destination) else { return }
        tabs.swapAt(index, destination)
        menuBarPanelTabOrder = tabs.map(\.rawValue).joined(separator: "|")
    }

    private var selectedRadialProfile: RadialMenuProfile {
        RadialMenuProfile(rawValue: radialMenuActiveProfile) ?? .work
    }

    private func globalShortcutEnabledBinding(_ action: GlobalShortcutAction) -> Binding<Bool> {
        Binding(
            get: { GlobalShortcutStore.configuration(for: action).enabled },
            set: { enabled in
                var value = GlobalShortcutStore.configuration(for: action)
                value.enabled = enabled
                GlobalShortcutStore.save(value, for: action)
                shortcutRevision += 1
            }
        )
    }

    private func globalShortcutModifierBinding(_ action: GlobalShortcutAction) -> Binding<GlobalShortcutModifier> {
        Binding(
            get: { GlobalShortcutStore.configuration(for: action).modifier },
            set: { modifier in
                var value = GlobalShortcutStore.configuration(for: action)
                value.modifier = modifier
                GlobalShortcutStore.save(value, for: action)
                shortcutRevision += 1
            }
        )
    }

    private func globalShortcutKeyBinding(_ action: GlobalShortcutAction) -> Binding<UInt32> {
        Binding(
            get: { GlobalShortcutStore.configuration(for: action).keyCode },
            set: { keyCode in
                guard let key = GlobalShortcutKey.choices.first(where: { $0.keyCode == keyCode }) else { return }
                var value = GlobalShortcutStore.configuration(for: action)
                value.keyCode = key.keyCode
                value.keyLabel = key.label
                GlobalShortcutStore.save(value, for: action)
                shortcutRevision += 1
            }
        )
    }

    private var radialThemeBinding: Binding<RadialMenuTheme> {
        Binding(
            get: { RadialMenuConfigurationStore.theme(profile: selectedRadialProfile, json: radialMenuThemes) },
            set: { theme in
                radialMenuThemes = RadialMenuConfigurationStore.replacingTheme(
                    profile: selectedRadialProfile,
                    theme: theme,
                    json: radialMenuThemes
                )
            }
        )
    }

    private func radialActionBinding(at index: Int) -> Binding<RadialMenuAction> {
        Binding(
            get: {
                let actions = RadialMenuConfigurationStore.actions(
                    profile: selectedRadialProfile,
                    json: radialMenuConfigurations
                )
                return actions.indices.contains(index) ? actions[index] : selectedRadialProfile.defaultActions[index]
            },
            set: { action in
                var actions = RadialMenuConfigurationStore.actions(
                    profile: selectedRadialProfile,
                    json: radialMenuConfigurations
                )
                guard actions.indices.contains(index) else { return }
                actions[index] = action
                radialMenuConfigurations = RadialMenuConfigurationStore.replacing(
                    profile: selectedRadialProfile,
                    actions: actions,
                    json: radialMenuConfigurations
                )
            }
        )
    }

    private func radialTarget(at index: Int) -> RadialMenuTarget? {
        RadialMenuConfigurationStore.target(
            profile: selectedRadialProfile,
            index: index,
            json: radialMenuTargets
        )
    }

    private func radialShortcutModifierBinding(at index: Int) -> Binding<GlobalShortcutModifier> {
        Binding(
            get: {
                RadialMenuConfigurationStore.shortcut(
                    profile: selectedRadialProfile, index: index, json: radialMenuKeyShortcuts
                ).modifier
            },
            set: { modifier in
                var shortcut = RadialMenuConfigurationStore.shortcut(
                    profile: selectedRadialProfile, index: index, json: radialMenuKeyShortcuts
                )
                shortcut.modifier = modifier
                radialMenuKeyShortcuts = RadialMenuConfigurationStore.replacingShortcut(
                    profile: selectedRadialProfile,
                    index: index,
                    shortcut: shortcut,
                    json: radialMenuKeyShortcuts
                )
            }
        )
    }

    private func radialShortcutKeyBinding(at index: Int) -> Binding<UInt32> {
        Binding(
            get: {
                RadialMenuConfigurationStore.shortcut(
                    profile: selectedRadialProfile, index: index, json: radialMenuKeyShortcuts
                ).keyCode
            },
            set: { keyCode in
                guard let key = GlobalShortcutKey.choices.first(where: { $0.keyCode == keyCode }) else { return }
                var shortcut = RadialMenuConfigurationStore.shortcut(
                    profile: selectedRadialProfile, index: index, json: radialMenuKeyShortcuts
                )
                shortcut.keyCode = key.keyCode
                shortcut.keyLabel = key.label
                radialMenuKeyShortcuts = RadialMenuConfigurationStore.replacingShortcut(
                    profile: selectedRadialProfile,
                    index: index,
                    shortcut: shortcut,
                    json: radialMenuKeyShortcuts
                )
            }
        )
    }

    private func setRadialTarget(_ target: RadialMenuTarget?, at index: Int) {
        radialMenuTargets = RadialMenuConfigurationStore.replacingTarget(
            profile: selectedRadialProfile,
            index: index,
            target: target,
            json: radialMenuTargets
        )
    }

    private func chooseRadialTarget(at index: Int) {
        let panel = NSOpenPanel()
        panel.title = "Choose Radial Menu Item"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = url.pathExtension.lowercased() == "app"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        setRadialTarget(.init(url: url.standardizedFileURL, title: title), at: index)
    }

    private func enterRadialLink(at index: Int) {
        let alert = NSAlert()
        alert.messageText = "Radial menu web link"
        alert.informativeText = "Enter an HTTPS address and a short label."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let address = NSTextField(string: radialTarget(at: index)?.url.absoluteString ?? "https://")
        address.placeholderString = "https://example.com"
        let title = NSTextField(string: radialTarget(at: index)?.title ?? "")
        title.placeholderString = "Label"
        stack.addArrangedSubview(address)
        stack.addArrangedSubview(title)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 56)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else { return }
        let label = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        setRadialTarget(.init(url: url, title: String((label.isEmpty ? url.host ?? "Website" : label).prefix(40))), at: index)
    }

    private func fetchRadialWebsiteIcon(for target: RadialMenuTarget, at index: Int) {
        guard let scheme = target.url.scheme,
              let host = target.url.host,
              let faviconURL = URL(string: "\(scheme)://\(host)/favicon.ico") else { return }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: faviconURL)
                guard data.count <= 1_000_000,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      NSImage(data: data) != nil else {
                    radialMenuStatus = "That website did not provide a usable /favicon.ico image."
                    return
                }
                setRadialTarget(.init(url: target.url, title: target.title, iconData: data), at: index)
                radialMenuStatus = "Fetched the website icon for \(target.title)."
            } catch {
                radialMenuStatus = "Website icon fetch failed: \(error.localizedDescription)"
            }
        }
    }

    private func chooseSettingsImport() {
        let panel = NSOpenPanel()
        panel.title = "Import MacScope Settings"
        panel.prompt = "Review Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw NSError(
                    domain: "MacScope.Settings", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected file is not a MacScope settings dictionary."]
                )
            }
            let filtered = dictionary.filter { Self.isPortableSetting($0.key) }
            guard !filtered.isEmpty else {
                throw NSError(
                    domain: "MacScope.Settings", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected file contains no portable MacScope settings."]
                )
            }
            pendingImportedSettings = filtered
            settingsPortabilityStatus = "Ready to import \(filtered.count) settings from \(url.lastPathComponent)."
            confirmsSettingsImport = true
        } catch {
            pendingImportedSettings = nil
            settingsPortabilityStatus = error.localizedDescription
        }
    }

    private func applySettingsImport() {
        guard let pendingImportedSettings else { return }
        for (key, value) in pendingImportedSettings {
            UserDefaults.standard.set(value, forKey: key)
        }
        self.pendingImportedSettings = nil
        confirmsSettingsImport = false
        settingsPortabilityStatus = "Imported \(pendingImportedSettings.count) settings. Restart MacScope to reload every service."
    }

    private static func isPortableSetting(_ key: String) -> Bool {
        let excludedFragments = [
            "scratchpad", "savedSnippets", "clipboardPinned", "clipboardHistory",
            "processHistory", "recent", "captured", "outputURL"
        ]
        guard !excludedFragments.contains(where: { key.localizedCaseInsensitiveContains($0) }) else { return false }
        let exact: Set<String> = [
            "samplingProfile", "expertModeEnabled", "redactExports", "launchAtLogin"
        ]
        let prefixes = [
            "utility.", "workspace.", "commandBar.", "audio.", "input.",
            "screenshot.", "recording.", "quickPanel.", "menuBar.", "alerts.",
            "feature.", "usageAlert.", "radialMenu", "globalShortcut."
        ]
        return exact.contains(key) || prefixes.contains(where: key.hasPrefix)
    }

    private func configureLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func checkHelper() {
        helperStatus = helperService.status == .enabled ? "Registered — connecting…" : helperService.status.displayName
        let connection = NSXPCConnection(machServiceName: privilegedMachServiceName, options: .privileged)
        let connectionBox = XPCConnectionBox(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedTelemetryXPC.self)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in helperStatus = error.localizedDescription }
        }) as? PrivilegedTelemetryXPC else {
            helperStatus = "Unavailable"
            connectionBox.value.invalidate()
            return
        }
        proxy.handshake { version, message in
            Task { @MainActor in helperStatus = "v\(version): \(message)" }
            connectionBox.value.invalidate()
        }
    }

    private func configureHelper(enabled: Bool) {
        do {
            if enabled {
                try helperService.register()
                helperStatus = helperService.status == .enabled ? "Registered — connecting…" : "Approval required in Login Items"
                checkHelper()
            } else {
                try helperService.unregister()
                helperStatus = "Removed"
            }
        } catch {
            helperStatus = error.localizedDescription
        }
    }

    @ViewBuilder private var mcpConfigurationButtons: some View {
        Button("Copy Read-Only Config", systemImage: "doc.on.doc") {
            copyMCPConfiguration(featureWrites: false)
        }
        .disabled(!mcpServerIsBundled)
        .macScopeGlassButton(prominent: true)

        Button("Copy Full Utility Config", systemImage: "switch.2") {
            copyMCPConfiguration(featureWrites: true)
        }
        .disabled(!mcpServerIsBundled)
        .macScopeGlassButton()

        Button("Documentation", systemImage: "book.closed") {
            openMCPDocumentation()
        }
        .disabled(mcpDocumentationURL == nil)
        .macScopeGlassButton()
    }

    private var mcpServerURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MacScopeMCPServer")
    }

    private var mcpDocumentationURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("MacScope-MCP-Server.md")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var mcpServerIsBundled: Bool {
        guard let mcpServerURL else { return false }
        return FileManager.default.isExecutableFile(atPath: mcpServerURL.path)
    }

    private func copyMCPConfiguration(featureWrites: Bool) {
        guard let mcpServerURL, mcpServerIsBundled else { return }
        var server: [String: Any] = ["command": mcpServerURL.path]
        server["args"] = featureWrites
            ? ["--allow-feature-writes", "--allow-utility-writes", "--allow-artifact-read", "--allow-sensitive-read"]
            : []
        let document: [String: Any] = ["mcpServers": ["macscope": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mcpConfigurationStatus = featureWrites ? "Full utility config copied" : "Read-only config copied"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            mcpConfigurationStatus = nil
        }
    }

    private func openMCPDocumentation() {
        guard let mcpDocumentationURL else { return }
        NSWorkspace.shared.open(mcpDocumentationURL)
    }

    @MainActor
    private func monitorMCPConnections() async {
        do {
            let registry = try MCPConnectionRegistry()
            while !Task.isCancelled {
                mcpConnections = await registry.activeSessions()
                mcpConnectionError = nil
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            mcpConnections = []
            mcpConnectionError = error.localizedDescription
        }
    }
}

private struct PermissionChecklistView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var center = PermissionCenter()

    var body: some View {
        SettingsSection(title: "Utility authorizations") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(center.allowedCount) of \(center.permissions.count) allowed")
                            .font(.headline)
                        Text(summaryDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(center.isRefreshing ? "Checking…" : "Check All", systemImage: "arrow.clockwise") {
                        Task { await center.refresh() }
                    }
                    .disabled(center.isRefreshing)
                    .macScopeGlassButton(prominent: center.allowedCount != center.permissions.count)
                }
                .padding(.bottom, 12)

                if let warning = center.buildIdentityWarning {
                    Label(warning, systemImage: "signature")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 12)
                }

                SettingsDivider()

                ForEach(Array(center.permissions.enumerated()), id: \.element.id) { index, permission in
                    PermissionStatusRow(
                        permission: permission,
                        isRequesting: center.isRequesting(permission.id),
                        action: { Task { await center.request(permission.id) } }
                    )
                    if index < center.permissions.count - 1 { SettingsDivider() }
                }

                if let message = center.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 12)
                }
            }
        }
        .task { await center.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await center.refresh() }
        }
    }

    private var summaryDetail: String {
        guard let checked = center.lastCheckedAt else {
            return "Reading permission status from the currently running MacScope build."
        }
        return "Current executable checked \(checked.formatted(date: .omitted, time: .standard)). Return from System Settings to refresh automatically."
    }
}

private struct PermissionStatusRow: View {
    let permission: MacScopePermissionItem
    let isRequesting: Bool
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content; controls }
            VStack(alignment: .leading, spacing: 10) { content; controls }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .font(.body.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.callout.weight(.medium))
                Text(permission.status.note ?? permission.utilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Label(permission.status.title, systemImage: statusIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.1), in: Capsule())
            Button(isRequesting ? "Requesting…" : permission.status.actionLabel, action: action)
                .disabled(isRequesting || permission.status == .checking)
                .macScopeGlassButton(
                    prominent: permission.status == .notDetermined || permission.status == .notAllowed
                )
        }
        .fixedSize()
    }

    private var statusColor: Color {
        switch permission.status {
        case .allowed: .green
        case .denied, .restricted: .red
        case .notAllowed, .notDetermined, .needsReview: .orange
        case .checking: .secondary
        }
    }

    private var statusIcon: String {
        switch permission.status {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "hand.raised.slash.fill"
        case .notAllowed: "exclamationmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        case .needsReview: "exclamationmark.circle.fill"
        case .checking: "clock"
        }
    }
}

private struct MCPConnectionsView: View {
    let sessions: [MCPClientSession]
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected MCP clients")
                        .font(.subheadline.weight(.semibold))
                    Text("Live clients that completed a handshake with MacScope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(sessions.isEmpty ? Color.secondary.opacity(0.45) : Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(sessions.count) connected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sessions.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "cable.connector.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No clients connected")
                            .font(.callout.weight(.medium))
                        Text("Configured clients appear here after their MCP handshake completes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        MCPConnectionRow(session: session)
                        if index < sessions.count - 1 { SettingsDivider() }
                    }
                }
            }
        }
    }
}

private struct MCPConnectionRow: View {
    let session: MCPClientSession

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.1))
                Image(systemName: "terminal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacScopeTheme.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if session.displayName != session.clientName {
                        Text(session.clientName)
                    }
                    Text("v\(session.clientVersion)")
                    Text("•")
                    Text("PID \(session.serverPID)")
                    Text("•")
                    Text("MCP \(session.protocolVersion)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(policyLabel)
                    .font(.caption.weight(.medium))
                Text("Active \(relativeActivity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayName), \(policyLabel), connected")
    }

    private var policyLabel: String {
        var policies: [String] = []
        if session.policy.experimentalFeatureWrites {
            policies.append("Experimental controls")
        } else if session.policy.featureWrites {
            policies.append("Feature controls")
        }
        if session.policy.sensitiveReads { policies.append("Sensitive reads") }
        if session.policy.utilityWrites { policies.append("Utilities") }
        if session.policy.artifactReads { policies.append("Artifacts") }
        return policies.isEmpty ? "Read only" : policies.joined(separator: " · ")
    }

    private var relativeActivity: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(session.lastActivityAt)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: .medium))
                        Text(tab.rawValue)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selection == tab ? MacScopeTheme.accent : Color.secondary)
                    .frame(minWidth: 62, minHeight: 42)
                    .padding(.horizontal, 4)
                    .background(
                        selection == tab ? MacScopeTheme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let content: Content

    init(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: icon)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(MacScopeTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(MacScopeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 2)
            }
            Card { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(MacScopeTheme.accent)
                .frame(width: 32, height: 32)
                .background(MacScopeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowLabel(title: title, detail: detail, icon: icon)
                .layoutPriority(1)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 12)
    }
}

private struct SettingsSamplingGraphic: View {
    let profile: SamplingProfile
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 18) {
            Gauge(value: isRunning ? profile.visualIntensity : 0, in: 0...1) {
                Text("Sampling")
            } currentValueLabel: {
                Image(systemName: isRunning ? "waveform.path.ecg" : "pause.fill")
                    .foregroundStyle(isRunning ? MacScopeTheme.accent : .orange)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(isRunning ? MacScopeTheme.accent : .orange)
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isRunning ? "Live sampling" : "Sampling paused").font(.headline)
                    Spacer()
                    Text(profile.intervalLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(SamplingProfile.allCases) { candidate in
                    HStack(spacing: 8) {
                        Text(candidate.displayName)
                            .font(.caption)
                            .foregroundStyle(candidate == profile ? .primary : .secondary)
                            .frame(width: 72, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(candidate == profile ? MacScopeTheme.accent.gradient : Color.secondary.opacity(0.14).gradient)
                                .frame(width: proxy.size.width * candidate.visualIntensity)
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(12)
        .macScopeGlassSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName) sampling, \(profile.intervalLabel), \(isRunning ? "running" : "paused")")
    }
}

private extension SamplingProfile {
    var displayName: String {
        switch self {
        case .lowImpact: "Low impact"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        }
    }

    var intervalLabel: String {
        switch self {
        case .lowImpact: "Every 5 s"
        case .balanced: "Every 1 s"
        case .maximum: "Every 0.5 s"
        }
    }

    var visualIntensity: Double {
        switch self {
        case .lowImpact: 0.25
        case .balanced: 0.58
        case .maximum: 1
        }
    }
}

private extension SMAppService.Status {
    var displayName: String {
        switch self {
        case .notRegistered: "Not installed"
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required in Login Items"
        case .notFound: "Bundled helper not found"
        @unknown default: "Unknown"
        }
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}
