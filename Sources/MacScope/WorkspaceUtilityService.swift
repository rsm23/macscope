import AppKit
import ApplicationServices
import MacScopeCore
import Observation

struct WorkspaceApplication: Identifiable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    let isActive: Bool
    let isHidden: Bool
}

struct InstalledWorkspaceApplication: Identifiable {
    let bundleIdentifier: String
    let name: String
    let url: URL

    var id: String { bundleIdentifier }
}

private final class EdgeSnapEngine: @unchecked Sendable {
    private weak var owner: WorkspaceUtilityService?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDragUpdate: CFAbsoluteTime = 0

    init(owner: WorkspaceUtilityService) {
        self.owner = owner
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: edgeSnapEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDragged {
            let modifiers = event.flags
            if modifiers.contains(.maskControl), modifiers.contains(.maskAlternate) {
                Task { @MainActor [weak owner] in owner?.cancelEdgeSnap() }
                return Unmanaged.passUnretained(event)
            }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastDragUpdate >= 1.0 / 45.0 else { return Unmanaged.passUnretained(event) }
            lastDragUpdate = now
            Task { @MainActor [weak owner] in
                owner?.updateEdgeSnap(at: NSEvent.mouseLocation)
            }
        } else if type == .leftMouseUp {
            Task { @MainActor [weak owner] in owner?.commitEdgeSnap() }
        }
        return Unmanaged.passUnretained(event)
    }
}

private enum ModifierWindowDragMode: Sendable {
    case move
    case resize
}

private final class ModifierWindowDragEngine: @unchecked Sendable {
    private weak var owner: WorkspaceUtilityService?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activeMode: ModifierWindowDragMode?

    init(owner: WorkspaceUtilityService) {
        self.owner = owner
    }

    func start() -> Bool {
        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | CGEventMask(1 << type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: modifierWindowDragEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        activeMode = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let isDown = type == .leftMouseDown || type == .rightMouseDown
        let isDrag = type == .leftMouseDragged || type == .rightMouseDragged
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        if isDown {
            let flags = event.flags
            guard flags.contains(.maskControl), flags.contains(.maskAlternate) else {
                return Unmanaged.passUnretained(event)
            }
            let mode: ModifierWindowDragMode = type == .rightMouseDown || flags.contains(.maskShift)
                ? .resize
                : .move
            activeMode = mode
            let location = event.location
            Task { @MainActor [weak owner] in
                owner?.beginModifierWindowDrag(mode: mode, at: location)
            }
            return nil
        }
        if isDrag, activeMode != nil {
            let location = event.location
            Task { @MainActor [weak owner] in owner?.updateModifierWindowDrag(at: location) }
            return nil
        }
        if isUp, activeMode != nil {
            activeMode = nil
            Task { @MainActor [weak owner] in owner?.endModifierWindowDrag() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

private func modifierWindowDragEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ModifierWindowDragEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

private final class GreenButtonOverrideEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var savedFrames: [CFHashCode: UtilitySupport.WindowFrame] = [:]

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: greenButtonOverrideEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        savedFrames.removeAll()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .leftMouseDown,
              let window = windowWhoseGreenButtonContains(event.location),
              let current = Self.readFrame(window) else {
            return Unmanaged.passUnretained(event)
        }
        let key = CFHash(window)
        let target: UtilitySupport.WindowFrame
        if let saved = savedFrames.removeValue(forKey: key) {
            target = saved
        } else {
            savedFrames[key] = current
            guard let screen = Self.screen(containing: current) else {
                savedFrames.removeValue(forKey: key)
                return Unmanaged.passUnretained(event)
            }
            let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
            let visible = screen.visibleFrame
            target = UtilitySupport.WindowFrame(
                x: visible.minX,
                y: desktopTop - visible.maxY,
                width: visible.width,
                height: visible.height
            )
        }
        Self.apply(target, to: window)
        return nil
    }

    private func windowWhoseGreenButtonContains(_ point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue else { return nil }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        for attribute in [kAXFullScreenButtonAttribute, kAXZoomButtonAttribute] {
            var buttonValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, attribute as CFString, &buttonValue) == .success,
               let buttonValue,
               CFEqual(element, buttonValue) {
                return window
            }
        }
        return nil
    }

    private static func readFrame(_ window: AXUIElement) -> UtilitySupport.WindowFrame? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return .init(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    private static func screen(containing frame: UtilitySupport.WindowFrame) -> NSScreen? {
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let center = CGPoint(
            x: frame.x + frame.width / 2,
            y: desktopTop - (frame.y + frame.height / 2)
        )
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    private static func apply(_ frame: UtilitySupport.WindowFrame, to window: AXUIElement) {
        var position = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

private func greenButtonOverrideEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<GreenButtonOverrideEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

private func edgeSnapEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EdgeSnapEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class WorkspaceUtilityService {
    private(set) var applications: [WorkspaceApplication] = []
    private(set) var installedApplications: [InstalledWorkspaceApplication] = []
    private(set) var frontmostApplication = "No active app"
    private(set) var statusMessage: String?
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var edgeSnapEnabled = false
    private(set) var edgeSnapError: String?
    private(set) var modifierWindowDragEnabled = false
    private(set) var modifierWindowDragError: String?
    private(set) var greenButtonOverrideEnabled = false
    private(set) var greenButtonOverrideError: String?
    private(set) var quitOnCloseBundleIdentifiers: Set<String> = []
    private var frameHistory: [pid_t: [UtilitySupport.WindowFrame]] = [:]
    private var quitMonitor: Timer?
    private var previousWindowCounts: [String: Int] = [:]
    private let quitRulesKey = "utility.quitOnCloseBundleIdentifiers"
    private let edgeSnapKey = "utility.edgeSnapEnabled"
    private let modifierWindowDragKey = "utility.modifierWindowDragEnabled"
    private let greenButtonOverrideKey = "utility.greenButtonOverrideEnabled"
    private var edgeSnapEngine: EdgeSnapEngine?
    private var edgePreviewPanel: NSPanel?
    private var pendingEdgePlacement: UtilitySupport.WindowPlacement?
    private weak var pendingEdgeScreen: NSScreen?
    private var modifierWindowDragEngine: ModifierWindowDragEngine?
    private var modifierWindowDragSession: ModifierWindowDragSession?
    private var greenButtonOverrideEngine: GreenButtonOverrideEngine?
    private var installedApplicationsRefreshedAt: Date?

    private struct ModifierWindowDragSession {
        let window: AXUIElement
        let applicationName: String
        let mode: ModifierWindowDragMode
        let startPointer: CGPoint
        let startFrame: UtilitySupport.WindowFrame
    }

    init() {
        quitOnCloseBundleIdentifiers = Set(
            UserDefaults.standard.stringArray(forKey: quitRulesKey) ?? []
        )
        updateQuitMonitor()
        if UserDefaults.standard.bool(forKey: edgeSnapKey) {
            setEdgeSnapEnabled(true, requestPermission: false)
        }
        if UserDefaults.standard.bool(forKey: modifierWindowDragKey) {
            setModifierWindowDragEnabled(true, requestPermission: false)
        }
        if UserDefaults.standard.bool(forKey: greenButtonOverrideKey) {
            setGreenButtonOverrideEnabled(true, requestPermission: false)
        }
        refreshInstalledApplications(force: true)
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        applications = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != currentPID
            }
            .map { app in
                WorkspaceApplication(
                    id: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "Application",
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: "App")!,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        frontmostApplication = NSWorkspace.shared.frontmostApplication?.localizedName ?? "No active app"
    }

    func refreshInstalledApplications(force: Bool = false) {
        if !force,
           let installedApplicationsRefreshedAt,
           Date().timeIntervalSince(installedApplicationsRefreshedAt) < 60 {
            return
        }
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        ]
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        var discovered: [String: InstalledWorkspaceApplication] = [:]
        for root in roots {
            guard let children = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundleIdentifier != currentBundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                discovered[bundleIdentifier] = InstalledWorkspaceApplication(
                    bundleIdentifier: bundleIdentifier,
                    name: name,
                    url: url
                )
            }
        }
        installedApplications = discovered.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        installedApplicationsRefreshedAt = Date()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        statusMessage = accessibilityTrusted
            ? "Accessibility access is ready."
            : "Grant access in System Settings, then return and press Refresh."
    }

    func arrange(_ placement: UtilitySupport.WindowPlacement) {
        refresh()
        guard accessibilityTrusted else {
            statusMessage = "Accessibility permission is required to resize another app's window."
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            statusMessage = "Activate the window you want to arrange, then use this control from the menu-bar preview."
            return
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success, let focusedValue else {
            statusMessage = "\(app.localizedName ?? "The active app") does not expose a resizable window."
            return
        }
        let window = unsafeDowncast(focusedValue, to: AXUIElement.self)
        guard let screen = NSScreen.main else {
            statusMessage = "No display is available."
            return
        }
        arrange(placement, window: window, app: app, screen: screen)
    }

    private func arrange(
        _ placement: UtilitySupport.WindowPlacement,
        window: AXUIElement,
        app: NSRunningApplication,
        screen: NSScreen
    ) {
        let visible = screen.visibleFrame
        let desktopTop = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        let available = UtilitySupport.WindowFrame(
            x: visible.minX,
            y: desktopTop - visible.maxY,
            width: visible.width,
            height: visible.height
        )
        let frame = UtilitySupport.windowFrame(for: placement, in: available)
        if let current = Self.readFrame(window) {
            frameHistory[app.processIdentifier, default: []].append(current)
            if frameHistory[app.processIdentifier, default: []].count > 20 {
                frameHistory[app.processIdentifier]?.removeFirst()
            }
        }
        apply(frame, to: window, applicationName: app.localizedName)
    }

    func setEdgeSnapEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            edgeSnapEngine?.stop()
            edgeSnapEngine = nil
            hideEdgePreview()
            edgeSnapEnabled = false
            edgeSnapError = nil
            UserDefaults.standard.set(false, forKey: edgeSnapKey)
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            edgeSnapError = "Edge snapping needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = EdgeSnapEngine(owner: self)
        guard engine.start() else {
            edgeSnapError = "The edge-snap pointer monitor could not start."
            return
        }
        edgeSnapEngine = engine
        edgeSnapEnabled = true
        edgeSnapError = nil
        UserDefaults.standard.set(true, forKey: edgeSnapKey)
    }

    fileprivate func updateEdgeSnap(at point: CGPoint) {
        guard edgeSnapEnabled,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            hideEdgePreview()
            return
        }
        let frame = screen.frame
        let threshold: CGFloat = 26
        let left = point.x <= frame.minX + threshold
        let right = point.x >= frame.maxX - threshold
        let top = point.y >= frame.maxY - threshold
        let bottom = point.y <= frame.minY + threshold
        let placement: UtilitySupport.WindowPlacement?
        switch (left, right, top, bottom) {
        case (true, _, true, _): placement = .topLeft
        case (_, true, true, _): placement = .topRight
        case (true, _, _, true): placement = .bottomLeft
        case (_, true, _, true): placement = .bottomRight
        case (true, _, _, _): placement = .leftHalf
        case (_, true, _, _): placement = .rightHalf
        case (_, _, true, _): placement = .maximize
        case (_, _, _, true): placement = .bottomHalf
        default: placement = nil
        }
        guard let placement else {
            hideEdgePreview()
            return
        }
        pendingEdgePlacement = placement
        pendingEdgeScreen = screen
        showEdgePreview(placement, on: screen)
    }

    fileprivate func commitEdgeSnap() {
        defer { hideEdgePreview() }
        guard let placement = pendingEdgePlacement,
              let screen = pendingEdgeScreen,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = Self.focusedWindow(pid: app.processIdentifier) else { return }
        arrange(placement, window: window, app: app, screen: screen)
    }

    fileprivate func cancelEdgeSnap() {
        hideEdgePreview()
    }

    func setModifierWindowDragEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            modifierWindowDragEngine?.stop()
            modifierWindowDragEngine = nil
            modifierWindowDragSession = nil
            modifierWindowDragEnabled = false
            modifierWindowDragError = nil
            UserDefaults.standard.set(false, forKey: modifierWindowDragKey)
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            modifierWindowDragError = "Modifier dragging needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = ModifierWindowDragEngine(owner: self)
        guard engine.start() else {
            modifierWindowDragError = "The modifier-drag pointer monitor could not start."
            return
        }
        modifierWindowDragEngine = engine
        modifierWindowDragEnabled = true
        modifierWindowDragError = nil
        UserDefaults.standard.set(true, forKey: modifierWindowDragKey)
    }

    func setGreenButtonOverrideEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            greenButtonOverrideEngine?.stop()
            greenButtonOverrideEngine = nil
            greenButtonOverrideEnabled = false
            greenButtonOverrideError = nil
            UserDefaults.standard.set(false, forKey: greenButtonOverrideKey)
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            greenButtonOverrideError = "Green-button maximize needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = GreenButtonOverrideEngine()
        guard engine.start() else {
            greenButtonOverrideError = "The green-button override could not start."
            return
        }
        greenButtonOverrideEngine = engine
        greenButtonOverrideEnabled = true
        greenButtonOverrideError = nil
        UserDefaults.standard.set(true, forKey: greenButtonOverrideKey)
    }

    fileprivate func beginModifierWindowDrag(mode: ModifierWindowDragMode, at point: CGPoint) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = Self.focusedWindow(pid: app.processIdentifier),
              let frame = Self.readFrame(window) else {
            modifierWindowDragSession = nil
            statusMessage = "The active app does not expose a movable window."
            return
        }
        frameHistory[app.processIdentifier, default: []].append(frame)
        if frameHistory[app.processIdentifier, default: []].count > 20 {
            frameHistory[app.processIdentifier]?.removeFirst()
        }
        modifierWindowDragSession = ModifierWindowDragSession(
            window: window,
            applicationName: app.localizedName ?? "the active window",
            mode: mode,
            startPointer: point,
            startFrame: frame
        )
    }

    fileprivate func updateModifierWindowDrag(at point: CGPoint) {
        guard let session = modifierWindowDragSession else { return }
        let deltaX = point.x - session.startPointer.x
        let deltaY = point.y - session.startPointer.y
        let frame: UtilitySupport.WindowFrame
        switch session.mode {
        case .move:
            frame = UtilitySupport.WindowFrame(
                x: session.startFrame.x + deltaX,
                y: session.startFrame.y + deltaY,
                width: session.startFrame.width,
                height: session.startFrame.height
            )
        case .resize:
            frame = UtilitySupport.WindowFrame(
                x: session.startFrame.x,
                y: session.startFrame.y,
                width: max(240, session.startFrame.width + deltaX),
                height: max(160, session.startFrame.height + deltaY)
            )
        }
        Self.applyFrameWithoutStatus(frame, to: session.window)
    }

    fileprivate func endModifierWindowDrag() {
        guard let session = modifierWindowDragSession else { return }
        modifierWindowDragSession = nil
        statusMessage = session.mode == .move
            ? "Moved \(session.applicationName)."
            : "Resized \(session.applicationName)."
    }

    private func showEdgePreview(_ placement: UtilitySupport.WindowPlacement, on screen: NSScreen) {
        let target = Self.previewRect(for: placement, in: screen.visibleFrame).insetBy(dx: 5, dy: 5)
        let panel = edgePreviewPanel ?? {
            let panel = NSPanel(
                contentRect: target,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let content = NSView(frame: NSRect(origin: .zero, size: target.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            content.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            content.layer?.borderWidth = 2
            content.layer?.cornerRadius = 12
            panel.contentView = content
            edgePreviewPanel = panel
            return panel
        }()
        panel.setFrame(target, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: target.size)
        panel.orderFrontRegardless()
    }

    private func hideEdgePreview() {
        edgePreviewPanel?.orderOut(nil)
        pendingEdgePlacement = nil
        pendingEdgeScreen = nil
    }

    private static func previewRect(
        for placement: UtilitySupport.WindowPlacement,
        in available: CGRect
    ) -> CGRect {
        switch placement {
        case .leftHalf: CGRect(x: available.minX, y: available.minY, width: available.width / 2, height: available.height)
        case .rightHalf: CGRect(x: available.midX, y: available.minY, width: available.width / 2, height: available.height)
        case .topHalf: CGRect(x: available.minX, y: available.midY, width: available.width, height: available.height / 2)
        case .bottomHalf: CGRect(x: available.minX, y: available.minY, width: available.width, height: available.height / 2)
        case .topLeft: CGRect(x: available.minX, y: available.midY, width: available.width / 2, height: available.height / 2)
        case .topRight: CGRect(x: available.midX, y: available.midY, width: available.width / 2, height: available.height / 2)
        case .bottomLeft: CGRect(x: available.minX, y: available.minY, width: available.width / 2, height: available.height / 2)
        case .bottomRight: CGRect(x: available.midX, y: available.minY, width: available.width / 2, height: available.height / 2)
        case .maximize: available
        case .centered: available.insetBy(dx: available.width * 0.1, dy: available.height * 0.1)
        case .leftThird: CGRect(x: available.minX, y: available.minY, width: available.width / 3, height: available.height)
        case .centerThird: CGRect(x: available.minX + available.width / 3, y: available.minY, width: available.width / 3, height: available.height)
        case .rightThird: CGRect(x: available.minX + available.width * 2 / 3, y: available.minY, width: available.width / 3, height: available.height)
        }
    }

    func restorePreviousLayout() {
        refresh()
        guard accessibilityTrusted else {
            statusMessage = "Accessibility permission is required to restore another app's window."
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              var history = frameHistory[app.processIdentifier],
              let frame = history.popLast() else {
            statusMessage = "No previous MacScope layout is available for the active app."
            return
        }
        frameHistory[app.processIdentifier] = history
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success, let focusedValue else {
            statusMessage = "The active app does not expose a restorable window."
            return
        }
        apply(frame, to: unsafeDowncast(focusedValue, to: AXUIElement.self), applicationName: app.localizedName)
    }

    func moveActiveWindowToAdjacentDisplay(offset: Int) {
        refresh()
        guard accessibilityTrusted else {
            statusMessage = "Accessibility permission is required to move another app's window."
            return
        }
        let screens = NSScreen.screens.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY < $1.frame.minY
        }
        guard screens.count > 1,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = Self.focusedWindow(pid: app.processIdentifier),
              let current = Self.readFrame(window) else {
            statusMessage = screens.count > 1
                ? "The active app does not expose a movable window."
                : "Connect another display before moving a window between displays."
            return
        }
        let desktopTop = screens.map(\.frame.maxY).max() ?? 0
        let currentCenter = CGPoint(
            x: current.x + current.width / 2,
            y: desktopTop - (current.y + current.height / 2)
        )
        let currentIndex = screens.firstIndex(where: { $0.frame.contains(currentCenter) }) ?? 0
        let targetIndex = (currentIndex + offset % screens.count + screens.count) % screens.count
        let target = screens[targetIndex].visibleFrame
        let width = min(current.width, target.width)
        let height = min(current.height, target.height)
        let targetNSY = target.midY - height / 2
        let destination = UtilitySupport.WindowFrame(
            x: target.midX - width / 2,
            y: desktopTop - (targetNSY + height),
            width: width,
            height: height
        )
        frameHistory[app.processIdentifier, default: []].append(current)
        apply(destination, to: window, applicationName: app.localizedName)
    }

    private func apply(
        _ frame: UtilitySupport.WindowFrame,
        to window: AXUIElement,
        applicationName: String?
    ) {
        var position = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            statusMessage = "The target window geometry could not be created."
            return
        }
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if positionResult == .success, sizeResult == .success {
            statusMessage = "Arranged \(applicationName ?? "the active window")."
        } else {
            statusMessage = "The active app refused the requested window layout."
        }
    }

    private static func applyFrameWithoutStatus(_ frame: UtilitySupport.WindowFrame, to window: AXUIElement) {
        var position = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    private static func readFrame(_ window: AXUIElement) -> UtilitySupport.WindowFrame? {
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionReference
        ) == .success,
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeReference
        ) == .success,
        let positionReference, let sizeReference else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionReference, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeReference, to: AXValue.self), .cgSize, &size) else { return nil }
        return UtilitySupport.WindowFrame(
            x: position.x, y: position.y, width: size.width, height: size.height
        )
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXFocusedWindowAttribute as CFString, &value
        ) == .success, let value else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func activate(_ item: WorkspaceApplication) {
        guard let app = application(pid: item.id) else { return }
        app.activate(options: [.activateAllWindows])
        refresh()
    }

    func launch(bundleIdentifier: String) -> Bool {
        refreshInstalledApplications(force: true)
        guard let item = installedApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            statusMessage = "The requested application is no longer installed."
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.statusMessage = "Could not open \(item.name): \(error.localizedDescription)"
                } else {
                    self?.statusMessage = "Opened \(item.name)."
                    self?.refresh()
                }
            }
        }
        statusMessage = "Opening \(item.name)…"
        return true
    }

    func quit(_ item: WorkspaceApplication) -> Bool {
        guard let app = application(pid: item.id), !app.isTerminated else {
            statusMessage = "\(item.name) is no longer running."
            return false
        }
        guard app.terminate() else {
            statusMessage = "\(item.name) did not accept the quit request."
            return false
        }
        statusMessage = "Asked \(item.name) to quit."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
        return true
    }

    func toggleHidden(_ item: WorkspaceApplication) {
        guard let app = application(pid: item.id) else { return }
        if app.isHidden { app.unhide() } else { app.hide() }
        refresh()
    }

    func setQuitOnClose(_ enabled: Bool, for item: WorkspaceApplication) {
        guard let bundleIdentifier = item.bundleIdentifier else {
            statusMessage = "This application does not expose a stable bundle identifier."
            return
        }
        if enabled {
            guard AXIsProcessTrusted() else {
                statusMessage = "Quit on close needs Accessibility permission to count another app's windows."
                return
            }
            quitOnCloseBundleIdentifiers.insert(bundleIdentifier)
            previousWindowCounts[bundleIdentifier] = Self.windowCount(pid: item.id) ?? 0
            statusMessage = "\(item.name) will quit after its last window closes."
        } else {
            quitOnCloseBundleIdentifiers.remove(bundleIdentifier)
            previousWindowCounts.removeValue(forKey: bundleIdentifier)
            statusMessage = "Quit on close disabled for \(item.name)."
        }
        UserDefaults.standard.set(Array(quitOnCloseBundleIdentifiers).sorted(), forKey: quitRulesKey)
        updateQuitMonitor()
    }

    func quitsOnClose(_ item: WorkspaceApplication) -> Bool {
        item.bundleIdentifier.map(quitOnCloseBundleIdentifiers.contains) ?? false
    }

    private func updateQuitMonitor() {
        quitMonitor?.invalidate()
        quitMonitor = nil
        guard !quitOnCloseBundleIdentifiers.isEmpty else { return }
        quitMonitor = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkQuitOnCloseRules() }
        }
    }

    private func checkQuitOnCloseRules() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundleIdentifier = app.bundleIdentifier,
                  quitOnCloseBundleIdentifiers.contains(bundleIdentifier) else { continue }
            guard let count = Self.windowCount(pid: app.processIdentifier) else { continue }
            let previous = previousWindowCounts[bundleIdentifier] ?? count
            previousWindowCounts[bundleIdentifier] = count
            if previous > 0, count == 0 {
                if app.terminate() {
                    statusMessage = "Quit \(app.localizedName ?? bundleIdentifier) after its last window closed."
                }
            }
        }
    }

    private static func windowCount(pid: pid_t) -> Int? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.count
    }

    private func application(pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}
