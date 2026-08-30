import Carbon
import MacScopeCore
import SwiftUI

private let macScopeHotKeySignature: OSType = 0x4D_53_43_50 // MSCP

private func macScopeHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == macScopeHotKeySignature else { return status }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    Task { @MainActor in
        if kind == UInt32(kEventHotKeyReleased) { manager.invokeRelease(identifier.id) }
        else { manager.invoke(identifier.id) }
    }
    return noErr
}

@MainActor
private final class GlobalHotKeyManager {
    private var eventHandler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    var handlers: [UInt32: () -> Void] = [:]
    var releaseHandlers: [UInt32: () -> Void] = [:]

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            macScopeHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void,
        releaseAction: (() -> Void)? = nil
    ) {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: macScopeHotKeySignature, id: id)
        guard RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        ) == noErr, let reference else { return }
        references.append(reference)
        handlers[id] = action
        releaseHandlers[id] = releaseAction
    }

    func invoke(_ id: UInt32) { handlers[id]?() }
    func invokeRelease(_ id: UInt32) { releaseHandlers[id]?() }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        handlers.removeAll()
        releaseHandlers.removeAll()
    }

}

@MainActor
final class MacScopeApplicationDelegate: NSObject, NSApplicationDelegate {
    var showMainWindow: (() -> Void)?
    var showDockPreview: (() -> Void)?
    var showCommandBar: (() -> Void)?
    var showAppSwitcher: (() -> Void)?
    var showRadialMenu: (() -> Void)?
    var showSessionShelf: (() -> Void)?
    var showShelfDropZone: (() -> Void)?
    var hideShelfDropZoneIfEmpty: (() -> Void)?
    var captureShelfDestination: (() -> Void)?
    var captureSelection: (() -> Void)?
    var captureFullScreen: (() -> Void)?
    var copyLatestCapture: (() -> Void)?
    var cycleFrontAppWindow: (() -> Void)?
    private var globalHotKeys: GlobalHotKeyManager?
    private var shelfEdgeMonitor: Any?
    private var shelfEdgeEnteredAt: Date?
    private var lastShelfEdgeTrigger = Date.distantPast
    private var lastShelfDropZoneReveal = Date.distantPast
    private var shortcutObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildGlobalHotKeys()
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: GlobalShortcutStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuildGlobalHotKeys() } }
        shelfEdgeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp]
        ) { [weak self] event in self?.handleShelfEvent(event) }
    }

    private func rebuildGlobalHotKeys() {
        globalHotKeys?.unregisterAll()
        let manager = globalHotKeys ?? GlobalHotKeyManager()
        let actions: [(GlobalShortcutAction, () -> Void, (() -> Void)?)] = [
            (.commandBar, { [weak self] in self?.showCommandBar?() }, nil),
            (.appSwitcher, { [weak self] in self?.showAppSwitcher?() }, nil),
            (.quickPanel, { [weak self] in self?.showDockPreview?() }, nil),
            (
                .radialMenu,
                { [weak self] in self?.showRadialMenu?() },
                { NotificationCenter.default.post(name: .radialShortcutReleased, object: nil) }
            ),
            (.sessionShelf, { [weak self] in self?.showSessionShelf?() }, nil),
            (.selectionScreenshot, { [weak self] in self?.captureSelection?() }, nil),
            (.fullScreenScreenshot, { [weak self] in self?.captureFullScreen?() }, nil),
            (.copyLatestScreenshot, { [weak self] in self?.copyLatestCapture?() }, nil),
            (.cycleFrontAppWindow, { [weak self] in self?.cycleFrontAppWindow?() }, nil)
        ]
        let conflicts = GlobalShortcutStore.conflicts()
        for (index, pair) in actions.enumerated() where !conflicts.contains(pair.0) {
            guard pair.0.isInstalled else { continue }
            let configuration = GlobalShortcutStore.configuration(for: pair.0)
            guard configuration.enabled else { continue }
            manager.register(
                id: UInt32(index + 1),
                keyCode: configuration.keyCode,
                modifiers: configuration.modifier.carbonValue,
                action: pair.1,
                releaseAction: pair.2
            )
        }
        globalHotKeys = manager
    }

    private func handleShelfEvent(_ event: NSEvent) {
        captureShelfDestination?()
        checkShelfDropZone(event)
        checkShelfEdge()
    }

    private func checkShelfDropZone(_ event: NSEvent) {
        let defaults = UserDefaults.standard
        let preferenceKey = "workspace.shelfTopDropZoneEnabled"
        let enabled = defaults.object(forKey: preferenceKey) == nil || defaults.bool(forKey: preferenceKey)
        guard enabled else { return }

        if event.type == .leftMouseUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.hideShelfDropZoneIfEmpty?()
            }
            return
        }
        guard event.type == .leftMouseDragged else { return }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // Never infer file content from the source application. That previously made
        // every drag from Finder reveal the shelf, including text and sidebar drags.
        let hasFileURLs = ShelfDragContent.containsSupportedFiles(in: pasteboard)
        guard ShelfDropZoneGeometry.shouldReveal(
            location: location,
            screenFrame: screen.frame,
            hasFileURLs: hasFileURLs
        ) else {
            hideShelfDropZoneIfEmpty?()
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastShelfDropZoneReveal) >= 0.4 else { return }
        lastShelfDropZoneReveal = now
        showShelfDropZone?()
    }

    private func checkShelfEdge() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "workspace.shelfEdgeEnabled") else {
            shelfEdgeEnteredAt = nil
            return
        }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        let edge = ShelfScreenEdge(rawValue: defaults.string(forKey: "workspace.shelfScreenEdge") ?? "") ?? .left
        let threshold: CGFloat = 4
        let frame = screen.frame
        let isAtEdge: Bool
        switch edge {
        case .left: isAtEdge = location.x <= frame.minX + threshold
        case .right: isAtEdge = location.x >= frame.maxX - threshold
        case .top: isAtEdge = location.y >= frame.maxY - threshold
        }
        guard isAtEdge else {
            shelfEdgeEnteredAt = nil
            return
        }
        let now = Date()
        if shelfEdgeEnteredAt == nil { shelfEdgeEnteredAt = now }
        guard now.timeIntervalSince(shelfEdgeEnteredAt ?? now) >= 0.55,
              now.timeIntervalSince(lastShelfEdgeTrigger) >= 2 else { return }
        lastShelfEdgeTrigger = now
        shelfEdgeEnteredAt = nil
        showSessionShelf?()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow?()
        return false
    }
}

@main
struct MacScopeApp: App {
    @NSApplicationDelegateAdaptor(MacScopeApplicationDelegate.self) private var appDelegate
    @State private var model = AppModel(automaticallyStarts: true)
    @AppStorage("appAppearance") private var appAppearance = MacScopeAppearance.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        MacScopeAppearance(rawValue: appAppearance)?.colorScheme
    }

    var body: some Scene {
        Window("MacScope", id: "main") {
            AppShell(model: model)
                .frame(minWidth: 1_050, minHeight: 700)
                .tint(MacScopeTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                .task { model.startAutomaticallyIfNeeded() }
                .onAppear { ApplicationPresenceController.shared.mainWindowWillOpen() }
                .onDisappear { ApplicationPresenceController.shared.mainWindowDidClose() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            MacScopeToolCommands()
            CommandMenu("Monitor") {
                Button(model.isRunning ? "Pause Sampling" : "Resume Sampling") {
                    model.isRunning ? model.stop() : model.start()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Command Bar", id: "command-bar") {
            CommandBarView(model: model)
                .tint(MacScopeTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 500)

        Window("App & Window Switcher", id: "app-switcher") {
            FeatureGatedView(module: .windows) { AppSwitcherView() }
                .tint(MacScopeTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 560)

        Window("Radial Menu", id: "radial-menu") {
            RadialMenuView(model: model)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 430, height: 430)

        Window("Session Shelf", id: "session-shelf") {
            FeatureGatedView(module: .clipboard) {
                ShelfOverlayView(service: model.snippetShelf)
            }
                .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 390)

        Window("Shelf Drop Zone", id: "shelf-drop-zone") {
            FeatureGatedView(module: .clipboard) {
                ShelfDropZoneView(service: model.snippetShelf)
            }
            .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 82)

        Window("MacScope Preview", id: "dock-preview") {
            ScrollView {
                MenuBarPanel(model: model)
            }
            .background(MacScopeTheme.contentBackground)
            .tint(MacScopeTheme.accent)
            .preferredColorScheme(preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 420, height: 620)

        MenuBarExtra {
            MenuBarPanel(model: model)
                .preferredColorScheme(preferredColorScheme)
        } label: {
            MenuBarStatusLabel(presentation: model.menuBarPresentation)
                .background(DockPreviewBridge(delegate: appDelegate, model: model))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .equatable()
                .preferredColorScheme(preferredColorScheme)
        }
    }
}

private struct DockPreviewBridge: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let delegate: MacScopeApplicationDelegate
    let model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                delegate.showMainWindow = {
                    ApplicationPresenceController.shared.mainWindowWillOpen()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showDockPreview = {
                    openWindow(id: "dock-preview")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showCommandBar = {
                    model.commandBar.captureOrigin()
                    openWindow(id: "command-bar")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showAppSwitcher = {
                    openWindow(id: "app-switcher")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showRadialMenu = {
                    openWindow(id: "radial-menu")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showSessionShelf = {
                    openWindow(id: "session-shelf")
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.showShelfDropZone = {
                    openWindow(id: "shelf-drop-zone")
                }
                delegate.hideShelfDropZoneIfEmpty = {
                    guard model.snippetShelf.shelfItems.isEmpty else { return }
                    dismissWindow(id: "shelf-drop-zone")
                }
                delegate.captureShelfDestination = {
                    model.snippetShelf.captureFrontmostFinderDestination()
                }
                delegate.captureSelection = {
                    model.screenshots.capture(.selection, copyToClipboard: true)
                }
                delegate.captureFullScreen = {
                    model.screenshots.capture(.fullScreen, copyToClipboard: true)
                }
                delegate.copyLatestCapture = {
                    model.screenshots.copyLatest()
                }
                delegate.cycleFrontAppWindow = {
                    WindowSwitcherService.cycleFrontmostApplicationWindow()
                }
            }
    }
}

struct AppShell: View {
    @Bindable var model: AppModel
    @AppStorage("featureHub.didCompleteSetup") private var didCompleteFeatureSetup = false
    @State private var showsFeatureSetup = false

    var body: some View {
        NavigationSplitView {
            List(model.availableSections, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("MacScope")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) {
                SamplingStatus(model: model)
                    .padding(10)
                    .background(.bar)
            }
        } detail: {
            SectionContent(section: model.selectedSection ?? .overview, model: model)
        }
        .onAppear {
            guard !didCompleteFeatureSetup else { return }
            if UserDefaults.standard.object(forKey: "samplingProfile") != nil {
                didCompleteFeatureSetup = true
            } else {
                showsFeatureSetup = true
            }
        }
        .sheet(isPresented: $showsFeatureSetup) {
            FeatureOnboardingView {
                didCompleteFeatureSetup = true
                showsFeatureSetup = false
            }
            .interactiveDismissDisabled()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct SamplingStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isRunning ? "Live" : "Paused").font(.caption.weight(.medium))
                Text(model.snapshot.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
