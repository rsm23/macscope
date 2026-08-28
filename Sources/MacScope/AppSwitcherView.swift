import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit
import SwiftUI

struct SwitchableWindow: Identifiable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleIdentifier: String?
    let title: String
    let icon: NSImage
    let bounds: CGRect
    let isOnScreen: Bool
}

@MainActor
@Observable
final class WindowSwitcherService {
    private(set) var windows: [SwitchableWindow] = []
    private(set) var statusMessage: String?
    private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    private(set) var isLoadingThumbnails = false

    func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let descriptions = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        windows = descriptions.compactMap { description -> SwitchableWindow? in
            guard let layer = description[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = description[kCGWindowNumber as String] as? UInt32,
                  let pid = description[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { return nil }
            let owner = description[kCGWindowOwnerName as String] as? String
                ?? app.localizedName
                ?? "Application"
            let title = (description[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = (description[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            guard bounds.width >= 80, bounds.height >= 50 else { return nil }
            return SwitchableWindow(
                id: CGWindowID(number),
                ownerPID: pid,
                ownerName: owner,
                bundleIdentifier: app.bundleIdentifier,
                title: title?.isEmpty == false ? title! : "Main window",
                icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: "App")!,
                bounds: bounds,
                isOnScreen: description[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
        .sorted {
            if $0.ownerName != $1.ownerName {
                return $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        statusMessage = windows.isEmpty ? "No switchable on-screen windows were found." : nil
    }

    func loadThumbnails(excludingBundleIdentifiers exclusions: Set<String> = []) {
        guard !isLoadingThumbnails else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           exclusions.contains(frontmost) {
            statusMessage = "Thumbnail capture is paused while this privacy-excluded app is in front."
            thumbnails.removeAll()
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            statusMessage = "Screen Recording permission is needed for live window thumbnails. Simple window mode remains available."
            return
        }
        isLoadingThumbnails = true
        statusMessage = "Loading window thumbnails…"
        let requested = windows.filter { window in
            guard let identifier = window.bundleIdentifier else { return true }
            return !exclusions.contains(identifier)
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                var loaded: [CGWindowID: NSImage] = [:]
                for item in requested.prefix(40) {
                    guard let source = content.windows.first(where: { $0.windowID == item.id }) else { continue }
                    let scale = min(360 / max(CGFloat(source.frame.width), 1), 1)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(Int(CGFloat(source.frame.width) * scale), 1)
                    configuration.height = max(Int(CGFloat(source.frame.height) * scale), 1)
                    configuration.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: source)
                    if let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    ) {
                        loaded[item.id] = NSImage(cgImage: image, size: .zero)
                    }
                }
                thumbnails = loaded
                statusMessage = loaded.isEmpty
                    ? "No thumbnails were returned; simple window mode is still available."
                    : "Loaded \(loaded.count) window thumbnail\(loaded.count == 1 ? "" : "s")."
            } catch {
                statusMessage = error.localizedDescription
            }
            isLoadingThumbnails = false
        }
    }

    func activate(_ window: SwitchableWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
        app.activate(options: [.activateAllWindows])

        guard AXIsProcessTrusted() else {
            statusMessage = "Activated \(window.ownerName). Accessibility access is needed to raise one exact window."
            return
        }
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let candidates = value as? [AXUIElement] else { return }
        for candidate in candidates {
            var numberValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, "AXWindowNumber" as CFString, &numberValue) == .success,
                  let number = numberValue as? NSNumber,
                  number.uint32Value == window.id else { continue }
            AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, candidate)
            statusMessage = "Opened \(window.ownerName) — \(window.title)."
            return
        }
    }

    static func cycleFrontmostApplicationWindow() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let candidates = windowsValue as? [AXUIElement], candidates.count > 1 else { return }
        var focusedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        let focused: AXUIElement?
        if let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        } else {
            focused = nil
        }
        let current = focused.flatMap { selected in
            candidates.firstIndex { CFEqual($0, selected) }
        } ?? -1
        let next = candidates[(current + 1) % candidates.count]
        app.activate(options: [.activateAllWindows])
        AXUIElementPerformAction(next, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, next)
    }
}

struct AppSwitcherView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var workspace = WorkspaceUtilityService()
    @State private var windows = WindowSwitcherService()
    @State private var query = ""
    @State private var mode = SwitcherMode.applications
    @AppStorage("workspace.switcherThumbnailSize") private var thumbnailSize = SwitcherThumbnailSize.medium.rawValue
    @AppStorage("workspace.switcherHiddenApps") private var hiddenAppsRaw = ""
    @AppStorage("workspace.switcherWindowOnlyApps") private var windowOnlyAppsRaw = ""
    @AppStorage("workspace.switcherThumbnailPrivacyApps") private var thumbnailPrivacyAppsRaw = ""
    @AppStorage("workspace.switcherShowsHints") private var showsHints = true
    @FocusState private var searchFocused: Bool

    private var selectedThumbnailSize: SwitcherThumbnailSize {
        SwitcherThumbnailSize(rawValue: thumbnailSize) ?? .medium
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: selectedThumbnailSize.cardWidth), spacing: 10)]
    }

    private var hiddenAppIdentifiers: Set<String> { decodedSet(hiddenAppsRaw) }
    private var windowOnlyAppIdentifiers: Set<String> { decodedSet(windowOnlyAppsRaw) }
    private var thumbnailPrivacyAppIdentifiers: Set<String> { decodedSet(thumbnailPrivacyAppsRaw) }

    private var filteredApplications: [WorkspaceApplication] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = workspace.applications.filter { app in
            guard let identifier = app.bundleIdentifier else { return true }
            return !hiddenAppIdentifiers.contains(identifier)
                && !windowOnlyAppIdentifiers.contains(identifier)
        }
        guard !term.isEmpty else { return visible }
        return visible.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private var filteredWindows: [SwitchableWindow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = windows.windows.filter { window in
            guard let identifier = window.bundleIdentifier else { return true }
            return !hiddenAppIdentifiers.contains(identifier)
        }
        guard !term.isEmpty else { return visible }
        return visible.filter {
            $0.ownerName.localizedCaseInsensitiveContains(term)
                || $0.title.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundStyle(MacScopeTheme.accent)
                TextField("Find an app or window", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { activateFirstMatch() }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .macScopeGlassButton()
                if mode == .windows {
                    Button(windows.isLoadingThumbnails ? "Loading…" : "Load Thumbnails", systemImage: "rectangle.on.rectangle") {
                        windows.loadThumbnails(excludingBundleIdentifiers: thumbnailPrivacyAppIdentifiers)
                    }
                    .disabled(windows.isLoadingThumbnails)
                    .macScopeGlassButton(prominent: windows.thumbnails.isEmpty)
                }
                switcherConfigurationMenu
            }
            .padding(16)

            Divider()

            Picker("Switcher mode", selection: $mode) {
                ForEach(SwitcherMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    if mode == .applications {
                        ForEach(filteredApplications) { app in
                            Button {
                                workspace.activate(app)
                                dismissWindow(id: "app-switcher")
                            } label: {
                                switcherCard(icon: app.icon, thumbnail: nil, title: app.name, subtitle: app.isActive ? "Active" : app.isHidden ? "Hidden" : "Running")
                            }
                            .buttonStyle(.plain)
                            .contextMenu { switcherAppRules(app.bundleIdentifier, name: app.name) }
                        }
                    } else {
                        ForEach(filteredWindows) { window in
                            Button {
                                windows.activate(window)
                                dismissWindow(id: "app-switcher")
                            } label: {
                                switcherCard(
                                    icon: window.icon,
                                    thumbnail: windows.thumbnails[window.id],
                                    title: window.title,
                                    subtitle: "\(window.ownerName) · \(window.isOnScreen ? "Visible" : "Minimized/off-screen") · \(Int(window.bounds.width))×\(Int(window.bounds.height))"
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { switcherAppRules(window.bundleIdentifier, name: window.ownerName) }
                        }
                    }
                }
                .padding(16)
            }

            if let message = windows.statusMessage ?? workspace.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            if showsHints {
                Text("Type to filter · Return opens the first match · Escape closes · right-click a card for per-app rules")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .background(MacScopeTheme.contentBackground)
        .onAppear {
            refresh()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == "app-switcher" else { return }
            searchFocused = false
            DispatchQueue.main.async { searchFocused = true }
        }
        .onExitCommand { dismissWindow(id: "app-switcher") }
    }

    private func refresh() {
        workspace.refresh()
        windows.refresh()
    }

    private func activateFirstMatch() {
        if mode == .applications, let app = filteredApplications.first {
            workspace.activate(app)
            dismissWindow(id: "app-switcher")
        } else if mode == .windows, let window = filteredWindows.first {
            windows.activate(window)
            dismissWindow(id: "app-switcher")
        }
    }

    private func switcherCard(icon: NSImage, thumbnail: NSImage?, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: selectedThumbnailSize.previewHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(1).font(.callout.weight(.semibold))
                    Text(subtitle).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func switcherAppRules(_ bundleIdentifier: String?, name: String) -> some View {
        if let bundleIdentifier {
            let isWindowOnly = windowOnlyAppIdentifiers.contains(bundleIdentifier)
            Button(
                isWindowOnly ? "Show \(name) as an App" : "Keep \(name) Window-Only",
                systemImage: isWindowOnly ? "app" : "macwindow"
            ) {
                setMembership(bundleIdentifier, in: &windowOnlyAppsRaw, included: !isWindowOnly)
            }
            Button("Hide \(name) from Switcher", systemImage: "eye.slash") {
                setMembership(bundleIdentifier, in: &hiddenAppsRaw, included: true)
            }
            let isPrivate = thumbnailPrivacyAppIdentifiers.contains(bundleIdentifier)
            Button(
                isPrivate ? "Allow Thumbnail Capture" : "Pause Thumbnail Capture",
                systemImage: isPrivate ? "rectangle.on.rectangle" : "hand.raised"
            ) {
                setMembership(bundleIdentifier, in: &thumbnailPrivacyAppsRaw, included: !isPrivate)
            }
        }
    }

    private var switcherConfigurationMenu: some View {
        Menu {
            Picker("Thumbnail size", selection: $thumbnailSize) {
                ForEach(SwitcherThumbnailSize.allCases) { size in
                    Text(size.rawValue).tag(size.rawValue)
                }
            }
            Toggle("Show shortcut hints", isOn: $showsHints)
            if !hiddenAppIdentifiers.isEmpty {
                Divider()
                Menu("Restore hidden app") {
                    ForEach(Array(hiddenAppIdentifiers).sorted(), id: \.self) { identifier in
                        Button(identifier) { setMembership(identifier, in: &hiddenAppsRaw, included: false) }
                    }
                    Button("Restore All") { hiddenAppsRaw = "" }
                }
            }
            if !windowOnlyAppIdentifiers.isEmpty {
                Menu("Window-only apps") {
                    ForEach(Array(windowOnlyAppIdentifiers).sorted(), id: \.self) { identifier in
                        Button(identifier) { setMembership(identifier, in: &windowOnlyAppsRaw, included: false) }
                    }
                    Button("Clear All") { windowOnlyAppsRaw = "" }
                }
            }
            if !thumbnailPrivacyAppIdentifiers.isEmpty {
                Menu("Thumbnail privacy exclusions") {
                    ForEach(Array(thumbnailPrivacyAppIdentifiers).sorted(), id: \.self) { identifier in
                        Button(identifier) { setMembership(identifier, in: &thumbnailPrivacyAppsRaw, included: false) }
                    }
                    Button("Clear All") { thumbnailPrivacyAppsRaw = "" }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switcher appearance and per-app rules")
    }

    private func decodedSet(_ rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: "|").map(String.init).filter { !$0.isEmpty })
    }

    private func setMembership(_ value: String, in rawValue: inout String, included: Bool) {
        var values = decodedSet(rawValue)
        if included { values.insert(value) } else { values.remove(value) }
        rawValue = values.sorted().joined(separator: "|")
    }
}

private enum SwitcherMode: String, CaseIterable, Identifiable {
    case applications = "Applications"
    case windows = "Windows"
    var id: String { rawValue }
}

private enum SwitcherThumbnailSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var id: String { rawValue }
    var cardWidth: CGFloat {
        switch self { case .small: 130; case .medium: 175; case .large: 240 }
    }
    var previewHeight: CGFloat {
        switch self { case .small: 72; case .medium: 106; case .large: 150 }
    }
}
