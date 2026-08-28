import AppKit
import MacScopeCore
import SwiftUI

private struct CommandBarApplicationItem: Identifiable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let icon: NSImage
    let alias: String?
    let isPinned: Bool

    var id: String { bundleIdentifier ?? "pid:\(pid)" }
    var displayName: String { alias ?? name }
}

private enum CommandBarFeedbackKind: String, Identifiable {
    case bug
    case feature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: "Report a bug"
        case .feature: "Suggest a feature"
        }
    }

    var subtitle: String {
        switch self {
        case .bug: "Review a diagnostic draft before opening it in Mail"
        case .feature: "Review an idea draft before opening it in Mail"
        }
    }

    var subject: String {
        switch self {
        case .bug: "MacScope bug report"
        case .feature: "MacScope feature suggestion"
        }
    }

    var prompt: String {
        switch self {
        case .bug: "What happened, and what did you expect instead?"
        case .feature: "What would you like MacScope to do?"
        }
    }

    var icon: String {
        switch self {
        case .bug: "ladybug"
        case .feature: "lightbulb"
        }
    }
}

private enum CommandBarItem: Identifiable {
    case section(AppSection)
    case utility(UtilityTab)
    case application(CommandBarApplicationItem)
    case window(SwitchableWindow)
    case menuCommand(CommandBarMenuCommand)
    case screenshot(ScreenshotMode)
    case recentCapture(ScreenshotRecord)
    case toggleOutputMute
    case cycleOutput
    case toggleMicrophone
    case toggleKeepAwake
    case appSwitcher
    case systemSettings(String, String, String)
    case web(URL)
    case calculation(String, Double)
    case conversion(String, UtilitySupport.UnitConversionResult)
    case answer(String, String, String)
    case snippet(SavedSnippet)
    case clipboard(ClipboardHistoryEntry, Bool)
    case emoji(CommandBarEmoji)
    case selectedText(String, URL, Bool)
    case file(CommandBarFileResult)
    case script(CommandBarScript)
    case feedback(CommandBarFeedbackKind)

    var id: String {
        switch self {
        case .section(let section): "section:\(section.rawValue)"
        case .utility(let tab): "utility:\(tab.rawValue)"
        case .application(let app): "app:\(app.id)"
        case .window(let window): "window:\(window.id)"
        case .menuCommand(let command): "menu:\(command.id)"
        case .screenshot(let mode): "shot:\(mode.rawValue)"
        case .recentCapture(let record): "capture:\(record.url.path)"
        case .toggleOutputMute: "audio:output"
        case .cycleOutput: "audio:cycle-output"
        case .toggleMicrophone: "audio:input"
        case .toggleKeepAwake: "power:awake"
        case .appSwitcher: "workspace:switcher"
        case .systemSettings(let id, _, _): "settings:\(id)"
        case .web(let url): "web:\(url.absoluteString)"
        case .calculation(let expression, _): "calculation:\(expression)"
        case .conversion(let expression, _): "conversion:\(expression)"
        case .answer(let title, _, _): "answer:\(title)"
        case .snippet(let snippet): "snippet:\(snippet.id.uuidString)"
        case .clipboard(let entry, let pinned): "clipboard:\(pinned ? "pinned" : "session"):\(entry.id.uuidString)"
        case .emoji(let emoji): "emoji:\(emoji.symbol)"
        case .selectedText(_, let url, let opensDirectly): "selected:\(opensDirectly ? "open" : "search"):\(url.absoluteString)"
        case .file(let result): "file:\(result.url.path)"
        case .script(let script): "script:\(script.id.uuidString)"
        case .feedback(let kind): "feedback:\(kind.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .section(let section): section.rawValue
        case .utility(let tab): tab == .notes ? "Scratchpads & Notes" : "Utilities · \(tab.rawValue)"
        case .application(let app): app.isPinned ? "★  \(app.displayName)" : app.displayName
        case .window(let window): window.title
        case .menuCommand(let command): command.title
        case .screenshot(let mode): "Capture \(mode.rawValue.lowercased()) screenshot"
        case .recentCapture(let record): "Recent capture · \(record.url.lastPathComponent)"
        case .toggleOutputMute: "Toggle system audio mute"
        case .cycleOutput: "Cycle audio output"
        case .toggleMicrophone: "Toggle all microphones"
        case .toggleKeepAwake: "Toggle Keep Awake"
        case .appSwitcher: "App & Window Switcher"
        case .systemSettings(_, let name, _): name
        case .web(let url): "Open \(url.absoluteString)"
        case .calculation(let expression, let result):
            "\(expression) = \(result.formatted(.number.precision(.fractionLength(0...8))))"
        case .conversion(let expression, let result):
            "\(expression) = \(result.value.formatted(.number.precision(.fractionLength(0...8)))) \(result.unit)"
        case .answer(let title, _, _): title
        case .snippet(let snippet): snippet.title
        case .clipboard(let entry, _): entry.summary
        case .emoji(let emoji): "\(emoji.symbol)  \(emoji.name.capitalized)"
        case .selectedText(let text, _, let opensDirectly):
            opensDirectly ? "Open selected link" : "Search for “\(Self.preview(text))”"
        case .file(let result): result.name
        case .script(let script): script.name
        case .feedback(let kind): kind.title
        }
    }

    var subtitle: String {
        switch self {
        case .section: "Open MacScope section"
        case .utility: "Open exact Utilities tool"
        case .application(let app):
            [app.alias.map { "\(app.name) · alias \($0)" }, app.bundleIdentifier]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .window(let window): "Switch to \(window.ownerName) window"
        case .menuCommand(let command): [command.path, command.shortcut].compactMap { $0 }.joined(separator: " · ")
        case .screenshot: "Capture and copy to clipboard"
        case .recentCapture(let record): "Copy PNG · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))"
        case .toggleOutputMute, .cycleOutput, .toggleMicrophone: "Audio action"
        case .toggleKeepAwake: "Power action"
        case .appSwitcher: "Search running apps and exact windows"
        case .systemSettings: "Open System Settings"
        case .web: "Open web address"
        case .calculation: "Copy calculation result"
        case .conversion: "Copy conversion result"
        case .answer(_, let value, _): value
        case .snippet(let snippet): snippetCommandSubtitle(snippet)
        case .clipboard(_, let pinned): pinned ? "Restore pinned clipboard favorite" : "Restore clipboard history item"
        case .emoji: "Insert emoji at the previous cursor"
        case .selectedText(_, _, let opensDirectly):
            opensDirectly ? "Open the URL selected in the previous app" : "Search text selected in the previous app"
        case .file(let result): result.folder
        case .script(let script): "Run local script · \(script.url.path(percentEncoded: false))"
        case .feedback(let kind): kind.subtitle
        }
    }

    var icon: String {
        switch self {
        case .section(let section): section.icon
        case .utility(let tab): tab.icon
        case .application: "app"
        case .window: "macwindow"
        case .menuCommand: "menubar.rectangle"
        case .screenshot: "camera.viewfinder"
        case .recentCapture: "photo"
        case .toggleOutputMute: "speaker.slash"
        case .cycleOutput: "airplayaudio"
        case .toggleMicrophone: "mic.slash"
        case .toggleKeepAwake: "cup.and.saucer"
        case .appSwitcher: "square.stack.3d.up.fill"
        case .systemSettings: "gearshape"
        case .web: "safari"
        case .calculation: "function"
        case .conversion: "arrow.left.arrow.right"
        case .answer(_, _, let icon): icon
        case .snippet: "text.badge.plus"
        case .clipboard(_, let pinned): pinned ? "pin.fill" : "doc.on.clipboard"
        case .emoji: "face.smiling"
        case .selectedText(_, _, let opensDirectly): opensDirectly ? "link" : "text.magnifyingglass"
        case .file: "doc.text.magnifyingglass"
        case .script: "terminal"
        case .feedback(let kind): kind.icon
        }
    }

    private static func preview(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 64 ? String(singleLine.prefix(64)) + "…" : singleLine
    }
}

private func snippetCommandSubtitle(_ snippet: SavedSnippet) -> String {
    let details = [snippet.folder, snippet.trigger.map { "trigger \($0)" }]
        .compactMap { $0 }
        .joined(separator: " · ")
    return details.isEmpty ? "Copy text snippet" : "Copy snippet · \(details)"
}

struct CommandBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let model: AppModel
    @State private var query = ""
    @State private var windowSwitcher = WindowSwitcherService()
    @State private var feedbackKind: CommandBarFeedbackKind?
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""
    @FocusState private var searchFocused: Bool

    private var items: [CommandBarItem] {
        var values: [CommandBarItem] = [
            .toggleOutputMute, .cycleOutput, .toggleMicrophone
        ]
        if UtilityFeatureStore.isEnabled(.capture, stored: disabledModules) {
            values += [.screenshot(.selection), .screenshot(.fullScreen)]
        }
        if UtilityFeatureStore.isEnabled(.power, stored: disabledModules) { values.append(.toggleKeepAwake) }
        if UtilityFeatureStore.isEnabled(.windows, stored: disabledModules) { values.append(.appSwitcher) }
        values += model.availableSections.map(CommandBarItem.section)
        if UtilityFeatureStore.isEnabled(.capture, stored: disabledModules) {
            values += model.screenshots.captures.prefix(20).map(CommandBarItem.recentCapture)
        }
        values += UtilityTab.enabled(from: disabledModules).map(CommandBarItem.utility)
        let applications: [CommandBarApplicationItem] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            let name = app.localizedName ?? app.bundleIdentifier ?? "Application"
            return CommandBarApplicationItem(
                pid: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                alias: model.commandBar.alias(for: app.bundleIdentifier),
                isPinned: model.commandBar.isPinned(bundleIdentifier: app.bundleIdentifier)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        values += applications.map(CommandBarItem.application)
        if UtilityFeatureStore.isEnabled(.windows, stored: disabledModules) {
            values += windowSwitcher.windows.map(CommandBarItem.window)
        }
        values += model.commandBar.menuCommands.map(CommandBarItem.menuCommand)
        if UtilityFeatureStore.isEnabled(.clipboard, stored: disabledModules) {
            values += model.snippetShelf.snippets.map(CommandBarItem.snippet)
            values += model.clipboard.pinnedEntries.map { .clipboard($0, true) }
            values += model.clipboard.entries.prefix(20).map { .clipboard($0, false) }
        }
        values += model.commandBar.scripts.map(CommandBarItem.script)
        values += model.commandBar.fileResults.map(CommandBarItem.file)
        values += [
            .feedback(.bug),
            .feedback(.feature)
        ]
        values += [
            .systemSettings("general", "General", "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"),
            .systemSettings("display", "Displays", "x-apple.systempreferences:com.apple.Displays-Settings.extension"),
            .systemSettings("sound", "Sound", "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
            .systemSettings("network", "Network", "x-apple.systempreferences:com.apple.Network-Settings.extension"),
            .systemSettings("bluetooth", "Bluetooth", "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension"),
            .systemSettings("privacy", "Privacy & Security", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
            .systemSettings("keyboard", "Keyboard", "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
            .systemSettings("accessibility", "Accessibility", "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"),
            .systemSettings("battery", "Battery", "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let emojis = CommandBarService.emojiCatalog
                .filter { $0.matches(trimmed) }
                .prefix(12)
                .map(CommandBarItem.emoji)
            values.insert(contentsOf: emojis, at: 0)
        } else if let selected = model.commandBar.selectedText,
                  let action = selectedTextAction(selected) {
            values.insert(action, at: 0)
        }
        if let result = UtilitySupport.arithmeticResult(trimmed), !trimmed.isEmpty {
            values.insert(.calculation(trimmed, result), at: 0)
        }
        if let result = UtilitySupport.unitConversion(trimmed), !trimmed.isEmpty {
            values.insert(.conversion(trimmed, result), at: 0)
        }
        if let result = UtilitySupport.dateCalculation(trimmed), !trimmed.isEmpty {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            values.insert(.answer("Date · \(trimmed)", formatter.string(from: result.date), "calendar"), at: 0)
        }
        if let answer = macAnswer(for: trimmed) { values.insert(answer, at: 0) }
        if let url = normalizedURL(trimmed) { values.insert(.web(url), at: 0) }
        guard !trimmed.isEmpty else { return Array(values.prefix(18)) }
        return values.filter {
            CommandBarService.matchesSearch(trimmed, title: $0.title, subtitle: $0.subtitle)
        }.prefix(30).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command").font(.title2).foregroundStyle(MacScopeTheme.accent)
                TextField("Run an action, open an app or enter a web address", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { if let first = items.first { run(first) } }
                Text("↩").foregroundStyle(.tertiary)
                commandBarConfigurationMenu
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        Button { run(item) } label: {
                            HStack(spacing: 12) {
                                if case .application(let app) = item {
                                    Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(MacScopeTheme.accent)
                                        .frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.callout.weight(.medium))
                                    Text(item.subtitle).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        .contextMenu {
                            if case .application(let app) = item {
                                appContextMenu(app)
                            }
                        }
                    }
                    if items.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .padding(10)
            }

            if model.commandBar.isSearchingFiles
                || model.commandBar.statusMessage != nil
                || model.commandBar.latestScriptOutput != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if model.commandBar.isSearchingFiles {
                            ProgressView().controlSize(.small)
                            Text("Searching chosen folders with Spotlight…")
                        } else if let message = model.commandBar.statusMessage {
                            Text(message)
                        }
                        Spacer()
                        if model.commandBar.latestScriptOutput != nil {
                            Button("Copy Output", systemImage: "doc.on.doc") {
                                model.commandBar.copyLatestScriptOutput()
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let output = model.commandBar.latestScriptOutput {
                        ScrollView {
                            Text(output)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 620, minHeight: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusSearchField() }
        .onAppear { windowSwitcher.refresh() }
        .onChange(of: query) { _, newValue in
            model.commandBar.searchFiles(matching: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == "command-bar" else { return }
            focusSearchField()
        }
        .onExitCommand { dismissWindow(id: "command-bar") }
        .sheet(item: $feedbackKind) { kind in
            CommandBarFeedbackComposer(
                kind: kind,
                technicalDetails: feedbackTechnicalDetails
            )
        }
    }

    private func focusSearchField() {
        // Window scenes may be created before their window becomes key. Toggling the
        // focus state on the next run-loop turn reliably focuses both first show and reopen.
        searchFocused = false
        DispatchQueue.main.async { searchFocused = true }
    }

    private func run(_ item: CommandBarItem) {
        switch item {
        case .section(let section):
            model.selectedSection = section
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        case .utility(let tab):
            model.selectedUtilityTab = tab
            model.selectedSection = .utilities
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        case .application(let app):
            NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        case .window(let window):
            windowSwitcher.activate(window)
        case .menuCommand(let command):
            model.commandBar.perform(command)
        case .screenshot(let mode):
            model.screenshots.capture(mode, copyToClipboard: true)
        case .recentCapture(let record):
            model.screenshots.copy(record.url)
        case .toggleOutputMute:
            model.audioMixer.toggleSystemMute()
        case .cycleOutput:
            model.audioMixer.cycleOutput()
        case .toggleMicrophone:
            model.audioMixer.toggleInputMute()
        case .toggleKeepAwake:
            model.keepAwake.isActive ? model.keepAwake.stop() : model.keepAwake.start(duration: nil, includesDisplay: false)
        case .appSwitcher:
            openWindow(id: "app-switcher")
            NSApp.activate(ignoringOtherApps: true)
        case .systemSettings(_, _, let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .calculation(_, let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                result.formatted(.number.precision(.fractionLength(0...8))),
                forType: .string
            )
        case .conversion(_, let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "\(result.value.formatted(.number.precision(.fractionLength(0...8)))) \(result.unit)",
                forType: .string
            )
        case .answer(_, let value, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .snippet(let snippet):
            let expanded = UtilitySupport.expandedSnippetTemplate(
                snippet.text,
                clipboard: NSPasteboard.general.string(forType: .string) ?? ""
            )
            model.commandBar.insertAtOrigin(expanded)
        case .clipboard(let entry, _):
            if !entry.text.isEmpty {
                model.commandBar.insertAtOrigin(entry.text)
            } else {
                model.clipboard.copy(entry)
            }
        case .emoji(let emoji):
            model.commandBar.insertAtOrigin(emoji.symbol)
        case .selectedText(_, let url, _):
            NSWorkspace.shared.open(url)
        case .file(let result):
            NSWorkspace.shared.open(result.url)
        case .script(let script):
            model.commandBar.run(script)
            return
        case .feedback(let kind):
            feedbackKind = kind
            return
        }
        dismissWindow(id: "command-bar")
    }

    @ViewBuilder
    private func appContextMenu(_ app: CommandBarApplicationItem) -> some View {
        Button("Open", systemImage: "arrow.up.forward.app") {
            NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        }
        if let bundleURL = app.bundleURL {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            }
            Button("Restart", systemImage: "arrow.clockwise") { restart(app) }
        }
        Divider()
        Button(app.isPinned ? "Unpin" : "Pin", systemImage: app.isPinned ? "pin.slash" : "pin") {
            model.commandBar.togglePinned(bundleIdentifier: app.bundleIdentifier, applicationName: app.name)
        }
        Button("Set Alias…", systemImage: "textformat") {
            model.commandBar.editAlias(bundleIdentifier: app.bundleIdentifier, applicationName: app.name)
        }
        Divider()
        Button("Quit", systemImage: "xmark.circle") {
            _ = NSRunningApplication(processIdentifier: app.pid)?.terminate()
        }
        Button("Force Quit…", systemImage: "exclamationmark.octagon", role: .destructive) {
            forceQuitAfterConfirmation(app)
        }
    }

    private func restart(_ app: CommandBarApplicationItem) {
        guard let bundleURL = app.bundleURL else { return }
        _ = NSRunningApplication(processIdentifier: app.pid)?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    private func forceQuitAfterConfirmation(_ app: CommandBarApplicationItem) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Force quit \(app.name)?"
        alert.informativeText = "Unsaved changes in this application may be lost."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = NSRunningApplication(processIdentifier: app.pid)?.forceTerminate()
    }

    private var feedbackTechnicalDetails: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let inventory = model.snapshot.inventory
        return [
            "MacScope version: \(version) (\(build))",
            "macOS: \(inventory.osVersion)",
            "Mac: \(inventory.modelName) (\(inventory.modelIdentifier))",
            "Chip: \(inventory.chip)",
            "Architecture: \(inventory.architecture)",
            "Active section: \(model.selectedSection?.rawValue ?? "None")"
        ].joined(separator: "\n")
    }

    private func normalizedURL(_ value: String) -> URL? {
        guard value.contains(".") && !value.contains(" ") else { return nil }
        if let url = URL(string: value), url.scheme == "http" || url.scheme == "https" { return url }
        return URL(string: "https://\(value)")
    }

    private func selectedTextAction(_ text: String) -> CommandBarItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = normalizedURL(trimmed), !trimmed.contains(" ") {
            return .selectedText(trimmed, url, true)
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components?.url else { return nil }
        return .selectedText(trimmed, url, false)
    }

    private func macAnswer(for rawQuery: String) -> CommandBarItem? {
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let snapshot = model.snapshot
        if query.contains("cpu") && (query.contains("usage") || query.contains("load")) {
            return .answer("CPU usage · \(rawQuery)", String(format: "%.1f%%", snapshot.cpuUsage), "cpu")
        }
        if query.contains("memory") || query.contains("ram") {
            let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.memory.used), countStyle: .memory)
            let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.memory.total), countStyle: .memory)
            return .answer("Memory · \(rawQuery)", "\(used) in use of \(total)", "memorychip")
        }
        if query.contains("battery") && snapshot.battery.isPresent {
            let charge = snapshot.battery.chargePercent.map { String(format: "%.0f%%", $0) } ?? "Unknown charge"
            let health = snapshot.battery.healthPercent.map { String(format: " · %.0f%% health", $0) } ?? ""
            return .answer("Battery · \(rawQuery)", charge + health, "battery.75percent")
        }
        if query.contains("disk") && (query.contains("free") || query.contains("space") || query.contains("storage")),
           let disk = snapshot.disks.max(by: { $0.total < $1.total }) {
            let available = ByteCountFormatter.string(fromByteCount: Int64(clamping: disk.available), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: disk.total), countStyle: .file)
            return .answer("Disk space · \(rawQuery)", "\(available) available of \(total)", "internaldrive")
        }
        if query.contains("mac model") || query == "what mac is this" || query == "which mac" {
            return .answer("Mac model · \(rawQuery)", "\(snapshot.inventory.modelName) · \(snapshot.inventory.chip)", "laptopcomputer")
        }
        if query.contains("macos") || query.contains("os version") {
            return .answer("macOS · \(rawQuery)", snapshot.inventory.osVersion, "apple.logo")
        }
        if query.contains("uptime") {
            let totalMinutes = max(Int(snapshot.inventory.uptime / 60), 0)
            let days = totalMinutes / 1_440
            let hours = (totalMinutes % 1_440) / 60
            let minutes = totalMinutes % 60
            return .answer("Uptime · \(rawQuery)", "\(days)d \(hours)h \(minutes)m", "clock")
        }
        return nil
    }

    @ViewBuilder
    private var commandBarConfigurationMenu: some View {
        Menu {
            Button("Add Search Folder…", systemImage: "folder.badge.plus") {
                model.commandBar.chooseSearchFolders()
            }
            if !model.commandBar.searchFolders.isEmpty {
                Menu("Remove Search Folder") {
                    ForEach(model.commandBar.searchFolders, id: \.self) { folder in
                        Button(folder.lastPathComponent) {
                            model.commandBar.removeSearchFolder(folder)
                        }
                    }
                }
            }
            Divider()
            Button("Add Local Script…", systemImage: "terminal.badge.plus") {
                model.commandBar.chooseScripts()
            }
            if !model.commandBar.scripts.isEmpty {
                Menu("Remove Local Script") {
                    ForEach(model.commandBar.scripts) { script in
                        Button(script.name) { model.commandBar.removeScript(script) }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Command Bar search folders and local scripts")
    }
}

private struct CommandBarFeedbackComposer: View {
    @Environment(\.dismiss) private var dismiss
    let kind: CommandBarFeedbackKind
    let technicalDetails: String
    @State private var description = ""
    @State private var includeTechnicalDetails = true
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(kind.title, systemImage: kind.icon)
                .font(.title2.weight(.semibold))

            Text(kind.prompt)
                .foregroundStyle(.secondary)

            TextEditor(text: $description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Add steps, context, or the outcome you want…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            Toggle("Include these technical details", isOn: $includeTechnicalDetails)

            ScrollView {
                Text(technicalDetails)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 115)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .opacity(includeTechnicalDetails ? 1 : 0.45)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Copy Draft", systemImage: "doc.on.doc") { copyDraft() }
                Button("Open Mail Draft", systemImage: "envelope") { openMailDraft() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 470)
        .background(MacScopeTheme.contentBackground)
    }

    private var reportBody: String {
        var sections = [description.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeTechnicalDetails {
            sections.append("Technical details\n\(technicalDetails)")
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportBody, forType: .string)
        statusMessage = "Draft copied. Nothing was sent."
    }

    private func openMailDraft() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: kind.subject),
            URLQueryItem(name: "body", value: reportBody)
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            statusMessage = "No mail composer accepted the draft. You can copy it instead."
            return
        }
        dismiss()
    }
}

struct MacScopeToolCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Command Bar…") { openWindow(id: "command-bar") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Quick Panel…") { openWindow(id: "dock-preview") }
                .keyboardShortcut("v", modifiers: [.command, .control])
            Button("App & Window Switcher…") { openWindow(id: "app-switcher") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Radial Menu…") { openWindow(id: "radial-menu") }
                .keyboardShortcut(.space, modifiers: [.control, .option])
            Button("Session Shelf…") { openWindow(id: "session-shelf") }
                .keyboardShortcut("s", modifiers: [.control, .option])
        }
    }
}
