import AppKit
import Carbon
import SwiftUI

enum RadialMenuProfile: String, CaseIterable, Identifiable {
    case work = "Work"
    case media = "Media"
    case system = "System"
    var id: String { rawValue }

    var defaultActions: [RadialMenuAction] {
        switch self {
        case .work: [.commandBar, .appSwitcher, .clipboard, .utilities, .quickPanel, .keepAwake, .lockScreen, .screenshot]
        case .media: [.screenshot, .recording, .mediaControls, .microphoneMute, .quickPanel, .utilities, .commandBar, .keepAwake]
        case .system: [.quickPanel, .audioMute, .microphoneMute, .keepAwake, .lockScreen, .storage, .utilities, .commandBar]
        }
    }
}

enum RadialMenuAction: String, CaseIterable, Identifiable, Codable {
    case customItem = "App, File or Link"
    case keyCombo = "Keyboard Shortcut"
    case sessionShelf = "Session Shelf"
    case commandBar = "Command Bar"
    case quickPanel = "Quick Panel"
    case appSwitcher = "App Switcher"
    case screenshot = "Screenshot"
    case recording = "Recording"
    case mediaControls = "Media Controls"
    case mediaPlayPause = "Play / Pause"
    case mediaPrevious = "Previous Track"
    case mediaNext = "Next Track"
    case volumeDown = "Volume Down"
    case volumeUp = "Volume Up"
    case submenuBack = "Back"
    case audioMute = "Mute Audio"
    case microphoneMute = "Mute Microphones"
    case keepAwake = "Keep Awake"
    case lockScreen = "Lock Screen"
    case clipboard = "Clipboard"
    case storage = "Storage"
    case utilities = "Utilities"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .customItem: "arrow.up.forward.app"
        case .keyCombo: "keyboard"
        case .sessionShelf: "tray.full"
        case .commandBar: "command"
        case .quickPanel: "bolt.fill"
        case .appSwitcher: "square.stack.3d.up.fill"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .mediaControls: "play.square.stack"
        case .mediaPlayPause: "playpause.fill"
        case .mediaPrevious: "backward.end.fill"
        case .mediaNext: "forward.end.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .volumeUp: "speaker.wave.3.fill"
        case .submenuBack: "arrow.uturn.backward.circle"
        case .audioMute: "speaker.slash"
        case .microphoneMute: "mic.slash"
        case .keepAwake: "cup.and.saucer"
        case .lockScreen: "lock.fill"
        case .clipboard: "doc.on.clipboard"
        case .storage: "internaldrive"
        case .utilities: "wrench.and.screwdriver"
        }
    }
}

struct RadialMenuTarget: Codable, Equatable {
    let url: URL
    let title: String
    var iconData: Data?

    init(url: URL, title: String, iconData: Data? = nil) {
        self.url = url
        self.title = title
        self.iconData = iconData
    }
}

enum RadialMenuTheme: String, CaseIterable, Identifiable, Codable {
    case accent = "Accent"
    case cyan = "Cyan"
    case purple = "Purple"
    case orange = "Orange"
    case green = "Green"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .accent: MacScopeTheme.accent
        case .cyan: .cyan
        case .purple: .purple
        case .orange: .orange
        case .green: .green
        }
    }
}

enum RadialMenuConfigurationStore {
    static func targetKey(profile: RadialMenuProfile, index: Int) -> String {
        "\(profile.rawValue):\(index)"
    }

    static func target(profile: RadialMenuProfile, index: Int, json: String) -> RadialMenuTarget? {
        decodeTargets(json)[targetKey(profile: profile, index: index)]
    }

    static func replacingTarget(
        profile: RadialMenuProfile,
        index: Int,
        target: RadialMenuTarget?,
        json: String
    ) -> String {
        var targets = decodeTargets(json)
        targets[targetKey(profile: profile, index: index)] = target
        return encode(targets, fallback: json)
    }

    static func shortcut(profile: RadialMenuProfile, index: Int, json: String) -> GlobalShortcutConfiguration {
        decodeShortcuts(json)[targetKey(profile: profile, index: index)]
            ?? .init(enabled: true, keyCode: UInt32(kVK_ANSI_C), keyLabel: "C", modifier: .controlOption)
    }

    static func replacingShortcut(
        profile: RadialMenuProfile,
        index: Int,
        shortcut: GlobalShortcutConfiguration,
        json: String
    ) -> String {
        var shortcuts = decodeShortcuts(json)
        shortcuts[targetKey(profile: profile, index: index)] = shortcut
        return encode(shortcuts, fallback: json)
    }

    static func theme(profile: RadialMenuProfile, json: String) -> RadialMenuTheme {
        guard let data = json.data(using: .utf8),
              let themes = try? JSONDecoder().decode([String: RadialMenuTheme].self, from: data) else { return .accent }
        return themes[profile.rawValue] ?? .accent
    }

    static func replacingTheme(profile: RadialMenuProfile, theme: RadialMenuTheme, json: String) -> String {
        var themes: [String: RadialMenuTheme] = [:]
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: RadialMenuTheme].self, from: data) { themes = decoded }
        themes[profile.rawValue] = theme
        return encode(themes, fallback: json)
    }

    static func actions(profile: RadialMenuProfile, json: String) -> [RadialMenuAction] {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONDecoder().decode([String: [RadialMenuAction]].self, from: data),
              let stored = dictionary[profile.rawValue], !stored.isEmpty else {
            return profile.defaultActions
        }
        return Array((stored + profile.defaultActions).prefix(8))
    }

    static func replacing(
        profile: RadialMenuProfile,
        actions: [RadialMenuAction],
        json: String
    ) -> String {
        var dictionary: [String: [RadialMenuAction]] = [:]
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: [RadialMenuAction]].self, from: data) {
            dictionary = decoded
        }
        dictionary[profile.rawValue] = Array(actions.prefix(8))
        guard let data = try? JSONEncoder().encode(dictionary),
              let encoded = String(data: data, encoding: .utf8) else { return json }
        return encoded
    }

    private static func decodeTargets(_ json: String) -> [String: RadialMenuTarget] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: RadialMenuTarget].self, from: data)) ?? [:]
    }

    private static func decodeShortcuts(_ json: String) -> [String: GlobalShortcutConfiguration] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: GlobalShortcutConfiguration].self, from: data)) ?? [:]
    }

    private static func encode<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return fallback }
        return encoded
    }
}

struct RadialMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let model: AppModel
    @AppStorage("radialMenuActiveProfile") private var activeProfileRaw = RadialMenuProfile.work.rawValue
    @AppStorage("radialMenuConfigurations") private var configurationJSON = ""
    @AppStorage("radialMenuTargets") private var targetsJSON = ""
    @AppStorage("radialMenuThemes") private var themesJSON = ""
    @AppStorage("radialMenuKeyShortcuts") private var keyShortcutsJSON = ""
    @State private var submenu: RadialSubmenu?
    @State private var hoveredIndex: Int?

    private var profile: RadialMenuProfile {
        RadialMenuProfile(rawValue: activeProfileRaw) ?? .work
    }

    private var actions: [RadialMenuAction] {
        RadialMenuConfigurationStore.actions(profile: profile, json: configurationJSON)
    }

    private var displayedActions: [RadialMenuAction] {
        switch submenu {
        case .media:
            [.mediaPrevious, .mediaPlayPause, .mediaNext, .volumeDown, .audioMute, .volumeUp, .screenshot, .submenuBack]
        case nil:
            actions
        }
    }

    private var theme: RadialMenuTheme {
        RadialMenuConfigurationStore.theme(profile: profile, json: themesJSON)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay { Circle().stroke(.separator.opacity(0.7), lineWidth: 1) }
                .shadow(color: .black.opacity(0.28), radius: 24, y: 8)

            ForEach(Array(displayedActions.enumerated()), id: \.offset) { index, action in
                radialButton(action, index: index, count: displayedActions.count)
            }

            VStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2).foregroundStyle(theme.color)
                if submenu == nil {
                    Picker("Profile", selection: $activeProfileRaw) {
                        ForEach(RadialMenuProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 108)
                } else {
                    Text("Media")
                        .font(.callout.weight(.semibold))
                }
                Text("⌃⌥Space").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: Circle())

            RadialWindowConfigurator()
                .frame(width: 0, height: 0)
        }
        .padding(14)
        .frame(width: 430, height: 430)
        .background(Color.clear)
        .onExitCommand { dismissWindow(id: "radial-menu") }
        .onReceive(NotificationCenter.default.publisher(for: .radialShortcutReleased)) { _ in
            guard let hoveredIndex, displayedActions.indices.contains(hoveredIndex) else {
                dismissWindow(id: "radial-menu")
                return
            }
            run(displayedActions[hoveredIndex], index: hoveredIndex)
        }
    }

    private func radialButton(_ action: RadialMenuAction, index: Int, count: Int) -> some View {
        let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(count, 1))
        let radius = 142.0
        return Button {
            run(action, index: index)
        } label: {
            VStack(spacing: 5) {
                radialIcon(action, index: index)
                Text(radialTitle(action, index: index))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 78, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.color.opacity(0.32), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredIndex = index }
            else if hoveredIndex == index { hoveredIndex = nil }
        }
        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    @ViewBuilder
    private func radialIcon(_ action: RadialMenuAction, index: Int) -> some View {
        if action == .customItem,
           let target = RadialMenuConfigurationStore.target(profile: profile, index: index, json: targetsJSON),
           let customIcon = target.iconData.flatMap(NSImage.init(data:))
                ?? (target.url.isFileURL ? NSWorkspace.shared.icon(forFile: target.url.path) : nil) {
            Image(nsImage: customIcon)
                .resizable().scaledToFit().frame(width: 24, height: 24)
        } else {
            Image(systemName: action.icon).font(.title3).foregroundStyle(theme.color)
        }
    }

    private func radialTitle(_ action: RadialMenuAction, index: Int) -> String {
        if action == .keyCombo {
            return RadialMenuConfigurationStore.shortcut(
                profile: profile, index: index, json: keyShortcutsJSON
            ).displayLabel
        }
        guard action == .customItem, submenu == nil else { return action.rawValue }
        return RadialMenuConfigurationStore.target(profile: profile, index: index, json: targetsJSON)?.title
            ?? "Choose Item"
    }

    private func run(_ action: RadialMenuAction, index: Int) {
        if let module = action.featureModule, !UtilityFeatureStore.isEnabled(module) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            dismissWindow(id: "radial-menu")
            return
        }
        switch action {
        case .customItem:
            if let target = RadialMenuConfigurationStore.target(profile: profile, index: index, json: targetsJSON) {
                NSWorkspace.shared.open(target.url)
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        case .keyCombo:
            let shortcut = RadialMenuConfigurationStore.shortcut(
                profile: profile, index: index, json: keyShortcutsJSON
            )
            Self.postKey(shortcut)
        case .sessionShelf:
            openWindow(id: "session-shelf")
        case .commandBar:
            model.commandBar.captureOrigin()
            openWindow(id: "command-bar")
        case .quickPanel:
            openWindow(id: "dock-preview")
        case .appSwitcher:
            openWindow(id: "app-switcher")
        case .screenshot:
            model.screenshots.capture(.selection, copyToClipboard: true)
        case .recording:
            model.selectedUtilityTab = .capture
            model.selectedSection = .utilities
            openWindow(id: "main")
        case .mediaControls:
            submenu = .media
            return
        case .mediaPlayPause:
            Self.postMediaKey(16)
        case .mediaPrevious:
            Self.postMediaKey(18)
        case .mediaNext:
            Self.postMediaKey(17)
        case .volumeDown:
            Self.postMediaKey(1)
        case .volumeUp:
            Self.postMediaKey(0)
        case .submenuBack:
            submenu = nil
            return
        case .audioMute:
            model.audioMixer.toggleSystemMute()
        case .microphoneMute:
            model.audioMixer.toggleInputMute()
        case .keepAwake:
            model.keepAwake.isActive
                ? model.keepAwake.stop()
                : model.keepAwake.start(duration: nil, includesDisplay: false)
        case .lockScreen:
            let executable = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["-suspend"]
                try? process.run()
            }
        case .clipboard:
            model.selectedUtilityTab = .clipboard
            model.selectedSection = .utilities
            openWindow(id: "main")
        case .storage:
            model.selectedSection = .storage
            openWindow(id: "main")
        case .utilities:
            model.selectedSection = .utilities
            openWindow(id: "main")
        }
        if action != .lockScreen { NSApp.activate(ignoringOtherApps: true) }
        dismissWindow(id: "radial-menu")
    }

    private static func postMediaKey(_ key: Int) {
        for keyDown in [true, false] {
            let keyState = keyDown ? 0xA : 0xB
            let data1 = (key << 16) | (keyState << 8)
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ shortcut: GlobalShortcutConfiguration) {
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: keyDown
            ) else { continue }
            event.flags = shortcut.modifier.cgEventFlags
            event.post(tap: .cghidEventTap)
        }
    }
}

private enum RadialSubmenu {
    case media
}

private struct RadialWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = CGPoint(
            x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height)
        )
        window.setFrameOrigin(origin)
        window.makeKeyAndOrderFront(nil)
    }
}
