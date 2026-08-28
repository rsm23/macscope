import AppKit
import ApplicationServices
import MacScopeCore
import Observation

struct CommandBarEmoji: Identifiable, Hashable {
    let symbol: String
    let name: String
    let keywords: String

    var id: String { symbol }

    func matches(_ query: String) -> Bool {
        let haystack = "\(name) \(keywords) \(symbol)"
        return haystack.localizedCaseInsensitiveContains(query)
    }
}

struct CommandBarScript: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let url: URL
}

struct CommandBarFileResult: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path(percentEncoded: false) }
}

struct CommandBarMenuCommand: Identifiable {
    let id: String
    let title: String
    let path: String
    let shortcut: String?
    let element: AXUIElement
}

@MainActor
@Observable
final class CommandBarService {
    private(set) var originApplicationName: String?
    private(set) var selectedText: String?
    private(set) var statusMessage: String?
    private(set) var searchFolders: [URL] = []
    private(set) var scripts: [CommandBarScript] = []
    private(set) var fileResults: [CommandBarFileResult] = []
    private(set) var isSearchingFiles = false
    private(set) var latestScriptOutput: String?
    private(set) var appAliases: [String: String] = [:]
    private(set) var pinnedAppIdentifiers: Set<String> = []
    private(set) var menuCommands: [CommandBarMenuCommand] = []

    private var originPID: pid_t?
    private var fileSearchTask: Task<Void, Never>?
    private let searchFoldersKey = "commandBar.searchFolders"
    private let scriptsKey = "commandBar.scripts"
    private let appAliasesKey = "commandBar.appAliases"
    private let pinnedAppsKey = "commandBar.pinnedApps"

    init() {
        loadConfiguration()
    }

    nonisolated static func matchesSearch(_ query: String, title: String, subtitle: String) -> Bool {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        let searchableText = "\(title) \(subtitle)"
        return tokens.allSatisfy { searchableText.localizedCaseInsensitiveContains($0) }
    }

    static let emojiCatalog: [CommandBarEmoji] = [
        .init(symbol: "😀", name: "grinning face", keywords: "smile happy"),
        .init(symbol: "😃", name: "smiling face", keywords: "smile happy joy"),
        .init(symbol: "😂", name: "face with tears of joy", keywords: "laugh funny cry"),
        .init(symbol: "🤣", name: "rolling on the floor laughing", keywords: "laugh rofl funny"),
        .init(symbol: "😊", name: "smiling face with smiling eyes", keywords: "happy blush"),
        .init(symbol: "😍", name: "heart eyes", keywords: "love face"),
        .init(symbol: "🥰", name: "smiling face with hearts", keywords: "love affection"),
        .init(symbol: "😎", name: "sunglasses face", keywords: "cool sun"),
        .init(symbol: "🤔", name: "thinking face", keywords: "question consider"),
        .init(symbol: "🫡", name: "saluting face", keywords: "respect yes"),
        .init(symbol: "😢", name: "crying face", keywords: "sad tear"),
        .init(symbol: "😭", name: "loudly crying face", keywords: "sad tears"),
        .init(symbol: "😡", name: "angry face", keywords: "mad rage"),
        .init(symbol: "🤯", name: "exploding head", keywords: "mind blown shocked"),
        .init(symbol: "🥳", name: "partying face", keywords: "celebrate birthday"),
        .init(symbol: "🤖", name: "robot", keywords: "bot ai machine"),
        .init(symbol: "👋", name: "waving hand", keywords: "hello goodbye hi"),
        .init(symbol: "👍", name: "thumbs up", keywords: "yes approve good"),
        .init(symbol: "👎", name: "thumbs down", keywords: "no disapprove bad"),
        .init(symbol: "👏", name: "clapping hands", keywords: "applause congrats"),
        .init(symbol: "🙌", name: "raising hands", keywords: "hooray celebrate"),
        .init(symbol: "🙏", name: "folded hands", keywords: "please thanks pray"),
        .init(symbol: "🤝", name: "handshake", keywords: "agreement deal"),
        .init(symbol: "💪", name: "flexed biceps", keywords: "strong strength"),
        .init(symbol: "🤞", name: "crossed fingers", keywords: "luck hope"),
        .init(symbol: "👌", name: "ok hand", keywords: "okay perfect"),
        .init(symbol: "❤️", name: "red heart", keywords: "love favorite"),
        .init(symbol: "🧡", name: "orange heart", keywords: "love"),
        .init(symbol: "💛", name: "yellow heart", keywords: "love"),
        .init(symbol: "💚", name: "green heart", keywords: "love"),
        .init(symbol: "💙", name: "blue heart", keywords: "love"),
        .init(symbol: "💜", name: "purple heart", keywords: "love"),
        .init(symbol: "💔", name: "broken heart", keywords: "sad love"),
        .init(symbol: "🔥", name: "fire", keywords: "hot lit flame"),
        .init(symbol: "✨", name: "sparkles", keywords: "shine magic new"),
        .init(symbol: "⭐️", name: "star", keywords: "favorite rating"),
        .init(symbol: "🎉", name: "party popper", keywords: "celebrate congrats"),
        .init(symbol: "🎂", name: "birthday cake", keywords: "birthday celebration"),
        .init(symbol: "🎁", name: "gift", keywords: "present birthday"),
        .init(symbol: "✅", name: "check mark", keywords: "done yes complete"),
        .init(symbol: "❌", name: "cross mark", keywords: "no error cancel"),
        .init(symbol: "⚠️", name: "warning", keywords: "alert caution"),
        .init(symbol: "ℹ️", name: "information", keywords: "info help"),
        .init(symbol: "💡", name: "light bulb", keywords: "idea tip"),
        .init(symbol: "🚀", name: "rocket", keywords: "launch fast ship"),
        .init(symbol: "🐛", name: "bug", keywords: "insect debug issue"),
        .init(symbol: "🔧", name: "wrench", keywords: "tool fix settings"),
        .init(symbol: "⚙️", name: "gear", keywords: "settings configuration"),
        .init(symbol: "🔒", name: "locked", keywords: "security private"),
        .init(symbol: "🔓", name: "unlocked", keywords: "security open"),
        .init(symbol: "📌", name: "pushpin", keywords: "pin save"),
        .init(symbol: "📎", name: "paperclip", keywords: "attachment file"),
        .init(symbol: "📁", name: "folder", keywords: "directory files"),
        .init(symbol: "📄", name: "document", keywords: "file page"),
        .init(symbol: "📷", name: "camera", keywords: "photo screenshot"),
        .init(symbol: "🎥", name: "movie camera", keywords: "video record"),
        .init(symbol: "🎵", name: "musical note", keywords: "music sound audio"),
        .init(symbol: "🔊", name: "speaker high volume", keywords: "audio sound loud"),
        .init(symbol: "🔇", name: "muted speaker", keywords: "audio sound mute"),
        .init(symbol: "💻", name: "laptop", keywords: "computer mac code"),
        .init(symbol: "📱", name: "mobile phone", keywords: "iphone device"),
        .init(symbol: "⌨️", name: "keyboard", keywords: "type input"),
        .init(symbol: "🖱️", name: "computer mouse", keywords: "pointer input"),
        .init(symbol: "🌐", name: "globe", keywords: "web internet world"),
        .init(symbol: "🔗", name: "link", keywords: "url chain"),
        .init(symbol: "📧", name: "email", keywords: "mail message"),
        .init(symbol: "💬", name: "speech balloon", keywords: "chat message"),
        .init(symbol: "📅", name: "calendar", keywords: "date schedule"),
        .init(symbol: "⏰", name: "alarm clock", keywords: "time reminder"),
        .init(symbol: "🔍", name: "magnifying glass", keywords: "search find"),
        .init(symbol: "📈", name: "chart increasing", keywords: "growth metrics"),
        .init(symbol: "📉", name: "chart decreasing", keywords: "decline metrics"),
        .init(symbol: "💯", name: "hundred points", keywords: "perfect score"),
        .init(symbol: "🟢", name: "green circle", keywords: "online success"),
        .init(symbol: "🟡", name: "yellow circle", keywords: "warning pending"),
        .init(symbol: "🔴", name: "red circle", keywords: "offline error"),
        .init(symbol: "➡️", name: "right arrow", keywords: "next forward"),
        .init(symbol: "⬅️", name: "left arrow", keywords: "back previous"),
        .init(symbol: "⬆️", name: "up arrow", keywords: "up increase"),
        .init(symbol: "⬇️", name: "down arrow", keywords: "down decrease")
    ]

    func captureOrigin() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        originPID = application.processIdentifier
        originApplicationName = application.localizedName
        selectedText = Self.readSelectedText(pid: application.processIdentifier)
        menuCommands = Self.readMenuCommands(pid: application.processIdentifier)
        statusMessage = nil
    }

    func perform(_ command: CommandBarMenuCommand) {
        guard AXIsProcessTrusted() else {
            statusMessage = "Accessibility permission is required to run another app's menu command."
            return
        }
        if let originPID,
           let application = NSRunningApplication(processIdentifier: originPID),
           !application.isTerminated {
            application.activate(options: [.activateAllWindows])
        }
        let result = AXUIElementPerformAction(command.element, kAXPressAction as CFString)
        statusMessage = result == .success
            ? "Ran \(command.path)."
            : "The app did not accept \(command.title) (Accessibility error \(result.rawValue))."
    }

    func insertAtOrigin(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard AXIsProcessTrusted(),
              let originPID,
              let application = NSRunningApplication(processIdentifier: originPID),
              !application.isTerminated else {
            statusMessage = "Copied to the clipboard. Accessibility permission is needed to insert at the previous cursor."
            return
        }

        application.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: isDown) else { continue }
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        }
        statusMessage = "Inserted into \(application.localizedName ?? "the previous app")."
    }

    func chooseSearchFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Command Bar Search Folders"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !searchFolders.contains(url) {
            searchFolders.append(url.standardizedFileURL)
        }
        searchFolders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        persistConfiguration()
        statusMessage = "Command Bar searches \(searchFolders.count) chosen folder\(searchFolders.count == 1 ? "" : "s") with Spotlight."
    }

    func removeSearchFolder(_ url: URL) {
        searchFolders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        fileResults.removeAll { $0.url.path.hasPrefix(url.path + "/") }
        persistConfiguration()
    }

    func chooseScripts() {
        let panel = NSOpenPanel()
        panel.title = "Add Local Scripts"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !scripts.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            scripts.append(CommandBarScript(
                id: UUID(),
                name: url.deletingPathExtension().lastPathComponent,
                url: url.standardizedFileURL
            ))
        }
        scripts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistConfiguration()
        statusMessage = "Added \(scripts.count) explicit local script\(scripts.count == 1 ? "" : "s")."
    }

    func removeScript(_ script: CommandBarScript) {
        scripts.removeAll { $0.id == script.id }
        persistConfiguration()
    }

    func searchFiles(matching rawQuery: String) {
        fileSearchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !searchFolders.isEmpty else {
            fileResults = []
            isSearchingFiles = false
            return
        }
        isSearchingFiles = true
        fileSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            var found: [URL] = []
            let escapedQuery = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
            let predicate = "kMDItemFSName == '*\(escapedQuery)*'cd"
            for folder in searchFolders {
                guard !Task.isCancelled else { return }
                let result = await CommandRunner.run(
                    executable: "/usr/bin/mdfind",
                    arguments: ["-onlyin", folder.path, predicate],
                    timeout: 8
                )
                guard result.exitCode == 0 else { continue }
                for path in result.stdout.split(separator: "\n").map(String.init) {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    if !found.contains(url) { found.append(url) }
                    if found.count >= 30 { break }
                }
                if found.count >= 30 { break }
            }
            guard !Task.isCancelled else { return }
            fileResults = found.map(CommandBarFileResult.init(url:))
            isSearchingFiles = false
        }
    }

    func run(_ script: CommandBarScript) {
        latestScriptOutput = nil
        statusMessage = "Running \(script.name)…"
        Task {
            let isExecutable = FileManager.default.isExecutableFile(atPath: script.url.path)
            let executable = isExecutable ? script.url.path : "/bin/zsh"
            let arguments = isExecutable ? [] : [script.url.path]
            let result = await CommandRunner.run(executable: executable, arguments: arguments, timeout: 30)
            let output = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            latestScriptOutput = output.isEmpty ? "(No output)" : String(output.prefix(12_000))
            statusMessage = result.exitCode == 0
                ? "\(script.name) finished."
                : "\(script.name) exited with status \(result.exitCode)."
        }
    }

    func copyLatestScriptOutput() {
        guard let latestScriptOutput else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestScriptOutput, forType: .string)
        statusMessage = "Script output copied."
    }

    func alias(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        return appAliases[bundleIdentifier]
    }

    func isPinned(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(pinnedAppIdentifiers.contains) ?? false
    }

    func editAlias(bundleIdentifier: String?, applicationName: String) {
        guard let bundleIdentifier else {
            statusMessage = "This application has no stable bundle identifier for an alias."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Command Bar alias"
        alert.informativeText = "Enter an alternate name for \(applicationName), or leave it empty to remove the alias."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: appAliases[bundleIdentifier] ?? "")
        field.placeholderString = "Alternate name"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let alias = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if alias.isEmpty {
            appAliases.removeValue(forKey: bundleIdentifier)
            statusMessage = "Removed the Command Bar alias for \(applicationName)."
        } else {
            appAliases[bundleIdentifier] = String(alias.prefix(64))
            statusMessage = "\(applicationName) also answers to “\(String(alias.prefix(64)))”."
        }
        persistConfiguration()
    }

    func togglePinned(bundleIdentifier: String?, applicationName: String) {
        guard let bundleIdentifier else {
            statusMessage = "This application has no stable identifier to pin."
            return
        }
        if pinnedAppIdentifiers.remove(bundleIdentifier) != nil {
            statusMessage = "Unpinned \(applicationName)."
        } else {
            pinnedAppIdentifiers.insert(bundleIdentifier)
            statusMessage = "Pinned \(applicationName) in the Command Bar."
        }
        persistConfiguration()
    }

    private static func readSelectedText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success, let selected = selectedValue as? String else { return nil }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2_000))
    }

    private static func readMenuCommands(pid: pid_t) -> [CommandBarMenuCommand] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success, let menuBarValue else { return [] }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        var commands: [CommandBarMenuCommand] = []
        collectMenuCommands(from: menuBar, path: [], depth: 0, into: &commands)
        return Array(commands.prefix(400))
    }

    private static func collectMenuCommands(
        from element: AXUIElement,
        path: [String],
        depth: Int,
        into commands: inout [CommandBarMenuCommand]
    ) {
        guard depth < 8, commands.count < 400 else { return }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else { return }
        for child in children where commands.count < 400 {
            let title = axString(child, attribute: kAXTitleAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextPath = title.isEmpty ? path : path + [title]
            let role = axString(child, attribute: kAXRoleAttribute)
            let enabled = axBoolean(child, attribute: kAXEnabledAttribute) ?? true
            if role == kAXMenuItemRole, enabled, !title.isEmpty {
                var actionNames: CFArray?
                let hasPressAction = AXUIElementCopyActionNames(child, &actionNames) == .success
                    && ((actionNames as? [String])?.contains(kAXPressAction) ?? false)
                if hasPressAction {
                    let pathString = nextPath.joined(separator: " › ")
                    commands.append(.init(
                        id: "\(CFHash(child)):\(pathString)",
                        title: title,
                        path: pathString,
                        shortcut: menuShortcut(child),
                        element: child
                    ))
                }
            }
            collectMenuCommands(from: child, path: nextPath, depth: depth + 1, into: &commands)
        }
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func axBoolean(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func menuShortcut(_ element: AXUIElement) -> String? {
        let character = axString(element, attribute: kAXMenuItemCmdCharAttribute)
        guard !character.isEmpty else { return nil }
        var modifiersValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdModifiersAttribute as CFString,
            &modifiersValue
        )
        let modifiers = (modifiersValue as? NSNumber)?.intValue ?? 0
        var result = ""
        if modifiers & (1 << 3) != 0 { result += "⌃" }
        if modifiers & (1 << 2) != 0 { result += "⌥" }
        if modifiers & (1 << 1) != 0 { result += "⇧" }
        if modifiers & (1 << 0) == 0 { result += "⌘" }
        return result + character.uppercased()
    }

    private func loadConfiguration() {
        let defaults = UserDefaults.standard
        appAliases = defaults.dictionary(forKey: appAliasesKey) as? [String: String] ?? [:]
        pinnedAppIdentifiers = Set(defaults.stringArray(forKey: pinnedAppsKey) ?? [])
        searchFolders = (defaults.array(forKey: searchFoldersKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let data = defaults.data(forKey: scriptsKey),
              let saved = try? JSONDecoder().decode([CommandBarScript].self, from: data) else { return }
        scripts = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func persistConfiguration() {
        UserDefaults.standard.set(searchFolders.map(\.path), forKey: searchFoldersKey)
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: scriptsKey)
        }
        UserDefaults.standard.set(appAliases, forKey: appAliasesKey)
        UserDefaults.standard.set(Array(pinnedAppIdentifiers).sorted(), forKey: pinnedAppsKey)
    }
}
