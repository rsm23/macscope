import SwiftUI

enum UtilityFeatureModule: String, CaseIterable, Identifiable {
    case capture
    case windows
    case clipboard
    case notes
    case maintenance
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: "Capture & media"
        case .windows: "Windows & input"
        case .clipboard: "Clipboard & files"
        case .notes: "Scratchpads"
        case .maintenance: "Maintenance"
        case .power: "Power & displays"
        }
    }

    var detail: String {
        switch self {
        case .capture: "Screenshots, recording, OCR, QR, color, camera and media tools."
        case .windows: "Window switching/layout, input filters and mouse utilities."
        case .clipboard: "Clipboard history, snippets, shelf, clean links and Finder helpers."
        case .notes: "Named Markdown scratchpads and quiet-period clearing."
        case .maintenance: "Cleaner, uninstaller, updates, messaging downloads and Homebrew."
        case .power: "Keep Awake, display controls and Cleaning Mode."
        }
    }

    var icon: String {
        switch self {
        case .capture: "camera.viewfinder"
        case .windows: "macwindow.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .maintenance: "wrench.and.screwdriver"
        case .power: "cup.and.saucer"
        }
    }

    var energyLabel: String {
        switch self {
        case .capture, .notes: "On demand"
        case .windows: "On demand · optional event monitors"
        case .clipboard: "Low · clipboard monitor when history is enabled"
        case .maintenance: "On demand · optional daily checks"
        case .power: "Low · automation monitor when configured"
        }
    }

    var utilityTab: UtilityTab {
        switch self {
        case .capture: .capture
        case .windows: .workspace
        case .clipboard: .clipboard
        case .notes: .notes
        case .maintenance: .maintenance
        case .power: .power
        }
    }
}

enum FeatureBundlePreset: String, CaseIterable, Identifiable {
    case essentials = "Essentials"
    case windows = "Windows"
    case batteryAndQuiet = "Battery & quiet"
    case everything = "Everything"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .essentials: "Capture, clipboard, notes and power"
        case .windows: "Window and input tools"
        case .batteryAndQuiet: "Notes and power with fewer background features"
        case .everything: "Install every MacScope module"
        }
    }

    var icon: String {
        switch self {
        case .essentials: "sparkles"
        case .windows: "macwindow.on.rectangle"
        case .batteryAndQuiet: "leaf"
        case .everything: "square.grid.3x3.fill"
        }
    }

    var modules: Set<UtilityFeatureModule> {
        switch self {
        case .essentials: [.capture, .clipboard, .notes, .power]
        case .windows: [.windows]
        case .batteryAndQuiet: [.notes, .power]
        case .everything: Set(UtilityFeatureModule.allCases)
        }
    }
}

enum UtilityFeatureStore {
    static let disabledKey = "featureHub.disabledModules"
    static let didChangeNotification = Notification.Name("MacScopeFeatureHubDidChange")

    static func disabledModules(from stored: String) -> Set<UtilityFeatureModule> {
        Set(stored.split(separator: "|").compactMap { UtilityFeatureModule(rawValue: String($0)) })
    }

    static func enabledModules(from stored: String) -> Set<UtilityFeatureModule> {
        Set(UtilityFeatureModule.allCases).subtracting(disabledModules(from: stored))
    }

    static func encodedDisabled(enabling modules: Set<UtilityFeatureModule>) -> String {
        UtilityFeatureModule.allCases
            .filter { !modules.contains($0) }
            .map(\.rawValue)
            .joined(separator: "|")
    }

    static func isEnabled(_ module: UtilityFeatureModule, stored: String? = nil) -> Bool {
        let value = stored ?? UserDefaults.standard.string(forKey: disabledKey) ?? ""
        return !disabledModules(from: value).contains(module)
    }

    static func setEnabled(_ enabled: Bool, module: UtilityFeatureModule, stored: String) -> String {
        var modules = enabledModules(from: stored)
        if enabled { modules.insert(module) } else { modules.remove(module) }
        return encodedDisabled(enabling: modules)
    }

    static func apply(_ preset: FeatureBundlePreset) -> String {
        encodedDisabled(enabling: preset.modules)
    }

    static func announceChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        NotificationCenter.default.post(name: GlobalShortcutStore.didChangeNotification, object: nil)
    }
}

extension UtilityTab {
    var featureModule: UtilityFeatureModule? {
        UtilityFeatureModule.allCases.first { $0.utilityTab == self }
    }

    static func enabled(from stored: String) -> [UtilityTab] {
        allCases.filter { tab in
            guard let module = tab.featureModule else { return true }
            return UtilityFeatureStore.isEnabled(module, stored: stored)
        }
    }
}

extension GlobalShortcutAction {
    var featureModule: UtilityFeatureModule? {
        switch self {
        case .appSwitcher, .cycleFrontAppWindow: .windows
        case .sessionShelf: .clipboard
        case .selectionScreenshot, .fullScreenScreenshot, .copyLatestScreenshot: .capture
        case .commandBar, .quickPanel, .radialMenu: nil
        }
    }

    var isInstalled: Bool {
        guard let featureModule else { return true }
        return UtilityFeatureStore.isEnabled(featureModule)
    }
}

extension RadialMenuAction {
    var featureModule: UtilityFeatureModule? {
        switch self {
        case .appSwitcher: .windows
        case .sessionShelf, .clipboard: .clipboard
        case .screenshot, .recording: .capture
        case .keepAwake: .power
        case .customItem, .keyCombo, .commandBar, .quickPanel, .mediaControls,
             .mediaPlayPause, .mediaPrevious, .mediaNext, .volumeDown, .volumeUp,
             .submenuBack, .audioMute, .microphoneMute, .lockScreen, .storage,
             .utilities: nil
        }
    }
}

struct FeatureHubSettingsView: View {
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    var body: some View {
        SettingsPage(
            title: "Features",
            subtitle: "Keep only the tools you use. Disabled modules disappear and their shortcuts stop registering.",
            icon: "square.grid.3x3.fill"
        ) {
            FeaturePresetPicker(disabledModules: $disabledModules)

            SettingsSection(title: "Always available") {
                VStack(alignment: .leading, spacing: 0) {
                    lockedRow(
                        title: "System monitor",
                        detail: "Core CPU, memory, thermals, network, storage and process telemetry.",
                        icon: "waveform.path.ecg",
                        energy: "Continuous · follows the selected sampling profile"
                    )
                    SettingsDivider()
                    lockedRow(
                        title: "Audio mixer & live disk preview",
                        detail: "Required in the Dock and Quick preview so both controls remain available.",
                        icon: "speaker.wave.2",
                        energy: "Live only while MacScope or its preview is open"
                    )
                }
            }

            SettingsSection(title: "Installed modules") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(UtilityFeatureModule.allCases.enumerated()), id: \.element.id) { index, module in
                        HStack(spacing: 12) {
                            Image(systemName: module.icon)
                                .foregroundStyle(MacScopeTheme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(module.title).font(.callout.weight(.medium))
                                Text(module.detail).font(.caption2).foregroundStyle(.secondary)
                                Label(module.energyLabel, systemImage: "leaf")
                                    .font(.caption2).foregroundStyle(.green)
                            }
                            Spacer(minLength: 16)
                            Toggle("Installed", isOn: featureBinding(module))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .padding(.vertical, 9)
                        if index < UtilityFeatureModule.allCases.count - 1 { SettingsDivider() }
                    }
                }
            }
        }
    }

    private func featureBinding(_ module: UtilityFeatureModule) -> Binding<Bool> {
        Binding(
            get: { UtilityFeatureStore.isEnabled(module, stored: disabledModules) },
            set: { enabled in
                disabledModules = UtilityFeatureStore.setEnabled(
                    enabled,
                    module: module,
                    stored: disabledModules
                )
                UtilityFeatureStore.announceChange()
            }
        )
    }

    private func lockedRow(title: String, detail: String, icon: String, energy: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(MacScopeTheme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                Label(energy, systemImage: "leaf.fill").font(.caption2).foregroundStyle(.green)
            }
            Spacer()
            Text("Required").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

private struct FeaturePresetPicker: View {
    @Binding var disabledModules: String

    var body: some View {
        SettingsSection(title: "One-click bundles") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10)], spacing: 10) {
                ForEach(FeatureBundlePreset.allCases) { preset in
                    Button {
                        disabledModules = UtilityFeatureStore.apply(preset)
                        UtilityFeatureStore.announceChange()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.icon).foregroundStyle(MacScopeTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue).font(.callout.weight(.semibold))
                                Text(preset.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct FeatureOnboardingView: View {
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Choose your MacScope", systemImage: "square.grid.3x3.fill")
                .font(.largeTitle.weight(.bold))
            Text("Start with a bundle, then install or remove individual modules. Audio and live disk activity stay available in the Dock preview.")
                .foregroundStyle(.secondary)
            FeaturePresetPicker(disabledModules: $disabledModules)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(UtilityFeatureModule.allCases) { module in
                        Toggle(isOn: Binding(
                            get: { UtilityFeatureStore.isEnabled(module, stored: disabledModules) },
                            set: { enabled in
                                disabledModules = UtilityFeatureStore.setEnabled(enabled, module: module, stored: disabledModules)
                            }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(module.title).font(.headline)
                                    Text(module.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: module.icon).foregroundStyle(MacScopeTheme.accent)
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(10)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Text("Permissions are requested only when a selected tool needs them.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Continue", systemImage: "arrow.right") {
                    UtilityFeatureStore.announceChange()
                    finish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 650, minHeight: 620)
        .background(MacScopeTheme.contentBackground)
    }
}

struct FeatureGatedView<Content: View>: View {
    let module: UtilityFeatureModule
    @ViewBuilder let content: () -> Content
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    var body: some View {
        if UtilityFeatureStore.isEnabled(module, stored: disabledModules) {
            content()
        } else {
            ContentUnavailableView(
                "Feature not installed",
                systemImage: module.icon,
                description: Text("Install \(module.title) from MacScope Settings › Features.")
            )
            .frame(minWidth: 420, minHeight: 320)
            .background(MacScopeTheme.contentBackground)
        }
    }
}
