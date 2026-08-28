import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacScopeCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class KeyboardDebounceService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    var intervalMilliseconds: Double {
        didSet {
            intervalMilliseconds = min(max(intervalMilliseconds, 20), 250)
            UserDefaults.standard.set(intervalMilliseconds, forKey: "utility.keyboardDebounceInterval")
            engine?.intervalNanoseconds = UInt64(intervalMilliseconds * 1_000_000)
        }
    }

    private var engine: KeyboardDebounceEngine?

    init() {
        let saved = UserDefaults.standard.double(forKey: "utility.keyboardDebounceInterval")
        intervalMilliseconds = saved == 0 ? 55 : saved
    }

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.keyboardDebounceEnabled") {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            UserDefaults.standard.set(false, forKey: "utility.keyboardDebounceEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Keyboard debounce needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        let engine = KeyboardDebounceEngine(
            intervalNanoseconds: UInt64(intervalMilliseconds * 1_000_000)
        )
        guard engine.start() else {
            errorMessage = "The keyboard event filter could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.keyboardDebounceEnabled")
    }
}

private final class KeyboardDebounceEngine: @unchecked Sendable {
    var intervalNanoseconds: UInt64
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastKeyCode: Int64?
    private var lastTimestamp: UInt64 = 0

    init(intervalNanoseconds: UInt64) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardDebounceCallback,
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
        lastKeyCode = nil
        lastTimestamp = 0
    }

    func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let timestamp = event.timestamp
        defer {
            lastKeyCode = keyCode
            lastTimestamp = timestamp
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           lastKeyCode == keyCode,
           timestamp >= lastTimestamp,
           timestamp - lastTimestamp < intervalNanoseconds {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

private func keyboardDebounceCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardDebounceEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .filter(type: type, event: event)
}

@MainActor
@Observable
final class ScrollDirectionService {
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    var invertVertical = false {
        didSet { update() }
    }
    var invertHorizontal = false {
        didSet { update() }
    }
    private var engine: ScrollDirectionEngine?
    private var isRestoring = false

    func restorePreference() {
        isRestoring = true
        invertVertical = UserDefaults.standard.bool(forKey: "utility.invertMouseVertical")
        invertHorizontal = UserDefaults.standard.bool(forKey: "utility.invertMouseHorizontal")
        isRestoring = false
        update()
    }

    private func update() {
        guard !isRestoring else { return }
        UserDefaults.standard.set(invertVertical, forKey: "utility.invertMouseVertical")
        UserDefaults.standard.set(invertHorizontal, forKey: "utility.invertMouseHorizontal")
        if !invertVertical && !invertHorizontal {
            engine?.stop()
            engine = nil
            isRunning = false
            errorMessage = nil
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Independent mouse scroll direction needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        if engine == nil {
            let engine = ScrollDirectionEngine()
            guard engine.start() else {
                errorMessage = "The mouse scroll event filter could not start."
                return
            }
            self.engine = engine
        }
        engine?.invertVertical = invertVertical
        engine?.invertHorizontal = invertHorizontal
        isRunning = true
        errorMessage = nil
    }
}

private final class ScrollDirectionEngine: @unchecked Sendable {
    var invertVertical = false
    var invertHorizontal = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollDirectionCallback,
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

    func transform(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        if invertVertical { invert(axis: 1, event: event) }
        if invertHorizontal { invert(axis: 2, event: event) }
        return Unmanaged.passUnretained(event)
    }

    private func invert(axis: Int, event: CGEvent) {
        let integerField: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let pointField: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixedField: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        event.setIntegerValueField(integerField, value: -event.getIntegerValueField(integerField))
        event.setIntegerValueField(pointField, value: -event.getIntegerValueField(pointField))
        event.setDoubleValueField(fixedField, value: -event.getDoubleValueField(fixedField))
    }
}

private func scrollDirectionCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ScrollDirectionEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .transform(type: type, event: event)
}

struct MouseButtonShortcut: Identifiable, Codable, Hashable {
    let id: UUID
    let buttonNumber: Int64
    let keyCode: Int64
    let modifierRawValue: UInt64

    var label: String {
        "Button \(buttonNumber + 1) → \(Self.modifierLabel(modifierRawValue))\(Self.keyLabel(keyCode))"
    }

    private static func modifierLabel(_ raw: UInt64) -> String {
        let flags = CGEventFlags(rawValue: raw)
        return [
            flags.contains(.maskControl) ? "⌃" : "",
            flags.contains(.maskAlternate) ? "⌥" : "",
            flags.contains(.maskShift) ? "⇧" : "",
            flags.contains(.maskCommand) ? "⌘" : "",
        ].joined()
    }

    private static func keyLabel(_ code: Int64) -> String {
        let names: [Int64: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "Key \(code)"
    }
}

struct MouseExcludedApplication: Identifiable, Codable, Hashable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

@MainActor
@Observable
final class MouseSideButtonService {
    private(set) var isEnabled = false
    private(set) var isRecording = false
    private(set) var recordingStatus: String?
    private(set) var errorMessage: String?
    private(set) var shortcuts: [MouseButtonShortcut] = []
    private(set) var excludedApplications: [MouseExcludedApplication] = []
    private var engine: MouseSideButtonEngine?
    private var recorder: MouseShortcutRecorderEngine?
    private var recordedButton: Int64?
    private let shortcutsKey = "utility.mouseButtonShortcuts"
    private let exclusionsKey = "utility.mouseButtonExcludedApplications"

    init() {
        if let data = UserDefaults.standard.data(forKey: shortcutsKey),
           let decoded = try? JSONDecoder().decode([MouseButtonShortcut].self, from: data) {
            shortcuts = decoded
        }
        if let data = UserDefaults.standard.data(forKey: exclusionsKey),
           let decoded = try? JSONDecoder().decode([MouseExcludedApplication].self, from: data) {
            excludedApplications = decoded
        }
    }

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.mouseSideButtonsEnabled") {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            UserDefaults.standard.set(false, forKey: "utility.mouseSideButtonsEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Mouse button shortcuts need Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        let shortcutMap = shortcuts.reduce(into: [Int64: MouseButtonShortcut]()) { result, shortcut in
            result[shortcut.buttonNumber] = shortcut
        }
        let engine = MouseSideButtonEngine(
            shortcuts: shortcutMap,
            excludedBundleIdentifiers: Set(excludedApplications.map(\.bundleIdentifier))
        )
        guard engine.start() else {
            errorMessage = "The mouse-button event filter could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.mouseSideButtonsEnabled")
    }

    func startRecording() {
        guard !isRecording else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Recording a mouse shortcut needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        engine?.stop()
        engine = nil
        recordedButton = nil
        let recorder = MouseShortcutRecorderEngine(
            buttonHandler: { [weak self] button in
                Task { @MainActor in self?.recordButton(button) }
            },
            keyHandler: { [weak self] keyCode, flags in
                Task { @MainActor in self?.recordKey(keyCode, flags: flags) }
            }
        )
        guard recorder.start() else {
            errorMessage = "The mouse-shortcut recorder could not start."
            if isEnabled { setEnabled(true) }
            return
        }
        self.recorder = recorder
        isRecording = true
        recordingStatus = "Press the extra mouse button you want to map."
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        recordedButton = nil
        recordingStatus = nil
        if isEnabled { setEnabled(true) }
    }

    func removeShortcut(_ shortcut: MouseButtonShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        persist()
        restartIfNeeded()
    }

    func chooseExcludedApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps to Leave Alone"
        panel.prompt = "Exclude"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if !excludedApplications.contains(where: { $0.bundleIdentifier == identifier }) {
                excludedApplications.append(.init(bundleIdentifier: identifier, name: name))
            }
        }
        excludedApplications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        restartIfNeeded()
    }

    func removeExcludedApplication(_ app: MouseExcludedApplication) {
        excludedApplications.removeAll { $0.id == app.id }
        persist()
        restartIfNeeded()
    }

    private func recordButton(_ button: Int64) {
        recordedButton = button
        recordingStatus = "Button \(button + 1) captured. Press the keyboard shortcut it should send."
    }

    private func recordKey(_ keyCode: Int64, flags: CGEventFlags) {
        guard let recordedButton else { return }
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        shortcuts.removeAll { $0.buttonNumber == recordedButton }
        shortcuts.append(.init(
            id: UUID(),
            buttonNumber: recordedButton,
            keyCode: keyCode,
            modifierRawValue: relevant.rawValue
        ))
        shortcuts.sort { $0.buttonNumber < $1.buttonNumber }
        recorder?.stop()
        recorder = nil
        isRecording = false
        self.recordedButton = nil
        recordingStatus = "Saved \(shortcuts.last(where: { $0.buttonNumber == recordedButton })?.label ?? "mouse shortcut")."
        persist()
        if !isEnabled { isEnabled = true }
        setEnabled(true)
    }

    private func restartIfNeeded() {
        guard isEnabled else { return }
        engine?.stop()
        engine = nil
        setEnabled(true)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: shortcutsKey)
        }
        if let data = try? JSONEncoder().encode(excludedApplications) {
            UserDefaults.standard.set(data, forKey: exclusionsKey)
        }
    }
}

private final class MouseSideButtonEngine: @unchecked Sendable {
    let shortcuts: [Int64: MouseButtonShortcut]
    let excludedBundleIdentifiers: Set<String>
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(shortcuts: [Int64: MouseButtonShortcut], excludedBundleIdentifiers: Set<String>) {
        self.shortcuts = shortcuts
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseSideButtonCallback,
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
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        if let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIdentifiers.contains(identifier) {
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let mapping: MouseButtonShortcut
        if let custom = shortcuts[button] {
            mapping = custom
        } else if button == 3 {
            mapping = .init(id: UUID(), buttonNumber: 3, keyCode: 33, modifierRawValue: CGEventFlags.maskCommand.rawValue)
        } else if button == 4 {
            mapping = .init(id: UUID(), buttonNumber: 4, keyCode: 30, modifierRawValue: CGEventFlags.maskCommand.rawValue)
        } else {
            return Unmanaged.passUnretained(event)
        }
        for keyDown in [true, false] {
            if let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(mapping.keyCode), keyDown: keyDown) {
                key.flags = CGEventFlags(rawValue: mapping.modifierRawValue)
                key.post(tap: .cghidEventTap)
            }
        }
        return nil
    }
}

private final class MouseShortcutRecorderEngine: @unchecked Sendable {
    private let buttonHandler: @Sendable (Int64) -> Void
    private let keyHandler: @Sendable (Int64, CGEventFlags) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buttonCaptured = false

    init(
        buttonHandler: @escaping @Sendable (Int64) -> Void,
        keyHandler: @escaping @Sendable (Int64, CGEventFlags) -> Void
    ) {
        self.buttonHandler = buttonHandler
        self.keyHandler = keyHandler
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mouseShortcutRecorderCallback,
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
        if type == .otherMouseDown, !buttonCaptured {
            buttonCaptured = true
            buttonHandler(event.getIntegerValueField(.mouseEventButtonNumber))
        } else if type == .keyDown, buttonCaptured {
            keyHandler(event.getIntegerValueField(.keyboardEventKeycode), event.flags)
        }
        return Unmanaged.passUnretained(event)
    }
}

private func mouseSideButtonCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseSideButtonEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

private func mouseShortcutRecorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseShortcutRecorderEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class FocusFollowsMouseService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    var delayMilliseconds: Double {
        didSet {
            delayMilliseconds = min(max(delayMilliseconds, 100), 1_000)
            UserDefaults.standard.set(delayMilliseconds, forKey: "utility.focusFollowsMouseDelay")
            engine?.delayMilliseconds = delayMilliseconds
        }
    }
    private var engine: FocusFollowsMouseEngine?

    init() {
        let saved = UserDefaults.standard.double(forKey: "utility.focusFollowsMouseDelay")
        delayMilliseconds = saved == 0 ? 300 : saved
    }

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.focusFollowsMouseEnabled") {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            errorMessage = nil
            UserDefaults.standard.set(false, forKey: "utility.focusFollowsMouseEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Focus follows mouse needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        let engine = FocusFollowsMouseEngine(delayMilliseconds: delayMilliseconds)
        guard engine.start() else {
            errorMessage = "The pointer focus monitor could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.focusFollowsMouseEnabled")
    }
}

private final class FocusFollowsMouseEngine: @unchecked Sendable {
    var delayMilliseconds: Double
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation: UInt64 = 0
    private var lastFocusedPID: pid_t?

    init(delayMilliseconds: Double) {
        self.delayMilliseconds = delayMilliseconds
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: focusFollowsMouseCallback,
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
        generation &+= 1
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        lastFocusedPID = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
        generation &+= 1
        let token = generation
        let location = event.location
        DispatchQueue.main.asyncAfter(deadline: .now() + delayMilliseconds / 1_000) { [weak self] in
            guard let self, self.generation == token, self.tap != nil else { return }
            self.focusWindow(at: location)
        }
        return Unmanaged.passUnretained(event)
    }

    private func focusWindow(at point: CGPoint) {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              pid != lastFocusedPID,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return }
        lastFocusedPID = pid
        app.activate(options: [])
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue {
            AXUIElementPerformAction(unsafeDowncast(windowValue, to: AXUIElement.self), kAXRaiseAction as CFString)
        }
    }
}

private func focusFollowsMouseCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<FocusFollowsMouseEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class PlainTextPasteService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    private var engine: PlainTextPasteEngine?

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.plainTextPasteEnabled") {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            errorMessage = nil
            UserDefaults.standard.set(false, forKey: "utility.plainTextPasteEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Global plain-text paste needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        let engine = PlainTextPasteEngine()
        guard engine.start() else {
            errorMessage = "The plain-text paste shortcut could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.plainTextPasteEnabled")
    }
}

private final class PlainTextPasteEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: plainTextPasteCallback,
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
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 9 else {
            return Unmanaged.passUnretained(event)
        }
        let required: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        let relevant = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        guard relevant == required else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { Self.pastePlainText() }
        return nil
    }

    private static func pastePlainText() {
        let pasteboard = NSPasteboard.general
        guard let string = pasteboard.string(forType: .string) else { return }
        let snapshot = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                if let data = item.data(forType: type) { values[type] = data }
            }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        let plainChangeCount = pasteboard.changeCount

        for isDown in [true, false] {
            guard let paste = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: isDown) else { continue }
            paste.flags = .maskCommand
            paste.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.changeCount == plainChangeCount else { return }
            let items = snapshot.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }
}

private func plainTextPasteCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<PlainTextPasteEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

final class TextExpansionEngine: @unchecked Sendable {
    var replacements: [String: String]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = ""
    private let eventTag: Int64 = 0x4D_53_54_58

    init(replacements: [String: String]) {
        self.replacements = replacements
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: textExpansionCallback,
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
        buffer = ""
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != eventTag else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
            buffer = ""
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 {
            if !buffer.isEmpty { buffer.removeLast() }
            return Unmanaged.passUnretained(event)
        }
        if [36, 48, 53, 123, 124, 125, 126].contains(keyCode) {
            buffer = ""
            return Unmanaged.passUnretained(event)
        }
        var units = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return Unmanaged.passUnretained(event) }
        let typed = String(utf16CodeUnits: units, count: length)
        guard typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            buffer = ""
            return Unmanaged.passUnretained(event)
        }
        buffer.append(typed)
        if buffer.count > 96 { buffer.removeFirst(buffer.count - 96) }
        guard let match = replacements.keys.sorted(by: { $0.count > $1.count }).first(where: buffer.hasSuffix),
              let template = replacements[match] else {
            return Unmanaged.passUnretained(event)
        }

        buffer = ""
        let deleteCount = max(match.count - typed.count, 0)
        for _ in 0..<deleteCount { postKey(code: 51) }
        postText(resolveVariables(template))
        return nil
    }

    private func resolveVariables(_ template: String) -> String {
        UtilitySupport.expandedSnippetTemplate(
            template,
            clipboard: NSPasteboard.general.string(forType: .string) ?? ""
        )
    }

    private func postKey(code: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postText(_ text: String) {
        var units = Array(text.utf16)
        guard !units.isEmpty else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
    }
}

private func textExpansionCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TextExpansionEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class SuperKeyService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    private var engine: SuperKeyEngine?

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.superKeyEnabled") {
            setEnabled(true, requestPermission: false)
        }
    }

    func setEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            errorMessage = nil
            UserDefaults.standard.set(false, forKey: "utility.superKeyEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Super key needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = SuperKeyEngine()
        guard engine.start() else {
            errorMessage = "The Super key keyboard filter could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.superKeyEnabled")
    }
}

private final class SuperKeyEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isHeld = false
    private var wasUsed = false
    private let rightOptionKeyCode: Int64 = 61
    private let tag: Int64 = 0x4D_53_48_59

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: superKeyCallback,
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
        isHeld = false
        wasUsed = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != tag else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == rightOptionKeyCode {
            if event.flags.contains(.maskAlternate) {
                isHeld = true
                wasUsed = false
            } else {
                if isHeld, !wasUsed { postEscape() }
                isHeld = false
                wasUsed = false
            }
            return nil
        }
        guard isHeld, type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        wasUsed = true
        event.flags.formUnion([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return Unmanaged.passUnretained(event)
    }

    private func postEscape() {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.post(tap: .cghidEventTap)
        }
    }
}

private func superKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SuperKeyEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class SmoothScrollingService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    var intensity: Double {
        didSet {
            intensity = min(max(intensity, 0.5), 2)
            UserDefaults.standard.set(intensity, forKey: "utility.smoothScrollIntensity")
            engine?.intensity = intensity
        }
    }
    private var engine: SmoothScrollingEngine?

    init() {
        let saved = UserDefaults.standard.double(forKey: "utility.smoothScrollIntensity")
        intensity = saved == 0 ? 1 : saved
    }

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.smoothScrollingEnabled") {
            setEnabled(true, requestPermission: false)
        }
    }

    func setEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            errorMessage = nil
            UserDefaults.standard.set(false, forKey: "utility.smoothScrollingEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Smooth scrolling needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = SmoothScrollingEngine(intensity: intensity)
        guard engine.start() else {
            errorMessage = "The smooth scrolling event filter could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.smoothScrollingEnabled")
    }
}

private final class SmoothScrollingEngine: @unchecked Sendable {
    var intensity: Double
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let tag: Int64 = 0x4D_53_53_43

    init(intensity: Double) { self.intensity = intensity }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: smoothScrollingCallback,
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
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != tag,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let fixedVertical = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedHorizontal = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let vertical = abs(fixedVertical) > 0.001
            ? fixedVertical
            : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) * 10)
        let horizontal = abs(fixedHorizontal) > 0.001
            ? fixedHorizontal
            : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) * 10)
        let location = event.location
        let flags = event.flags
        let factors = [0.34, 0.25, 0.17, 0.11, 0.07, 0.04, 0.02]
        for (index, factor) in factors.enumerated() {
            let delay = Double(index) * 0.012
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.tap != nil,
                      let smoothed = CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .pixel,
                        wheelCount: 2,
                        wheel1: Int32((vertical * factor * self.intensity).rounded()),
                        wheel2: Int32((horizontal * factor * self.intensity).rounded()),
                        wheel3: 0
                      ) else { return }
                smoothed.location = location
                smoothed.flags = flags
                smoothed.setIntegerValueField(.eventSourceUserData, value: self.tag)
                smoothed.post(tap: .cghidEventTap)
            }
        }
        return nil
    }
}

private func smoothScrollingCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<SmoothScrollingEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

@MainActor
@Observable
final class FinderShortcutService {
    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    private var engine: FinderShortcutEngine?

    func restorePreference() {
        if UserDefaults.standard.bool(forKey: "utility.finderShortcutsEnabled") {
            setEnabled(true, requestPermission: false)
        }
    }

    func setEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            engine?.stop()
            engine = nil
            isEnabled = false
            errorMessage = nil
            UserDefaults.standard.set(false, forKey: "utility.finderShortcutsEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Finder shortcuts need Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = FinderShortcutEngine()
        guard engine.start() else {
            errorMessage = "The Finder keyboard shortcut filter could not start."
            return
        }
        self.engine = engine
        isEnabled = true
        errorMessage = nil
        UserDefaults.standard.set(true, forKey: "utility.finderShortcutsEnabled")
    }
}

private final class FinderShortcutEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hasPendingCut = false
    private let tag: Int64 = 0x4D_53_46_53

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: finderShortcutCallback,
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
        hasPendingCut = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != tag,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        if keyCode == 7, modifiers == .maskCommand {
            postKey(code: 8, flags: .maskCommand)
            hasPendingCut = true
            return nil
        }
        if keyCode == 9, modifiers == .maskCommand, hasPendingCut {
            postKey(code: 9, flags: [.maskCommand, .maskAlternate])
            hasPendingCut = false
            return nil
        }
        if keyCode == 9, modifiers == .maskCommand, pasteboardContainsStandaloneImage() {
            DispatchQueue.main.async { [weak self] in self?.pasteImageAsPNG() }
            return nil
        }
        if keyCode == 120, modifiers.isEmpty {
            postKey(code: 36, flags: [])
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func pasteboardContainsStandaloneImage() -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.types?.contains(.fileURL) != true else { return false }
        return NSImage(pasteboard: pasteboard) != nil
    }

    private func pasteImageAsPNG() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.types?.contains(.fileURL) != true,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-Finder-Paste", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = Self.availablePNGURL(in: directory)
            try png.write(to: destination, options: .atomic)
            pasteboard.clearContents()
            guard pasteboard.writeObjects([destination as NSURL]) else { return }
            let replacementChangeCount = pasteboard.changeCount
            postKey(code: 9, flags: .maskCommand)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let currentPasteboard = NSPasteboard.general
                guard currentPasteboard.changeCount == replacementChangeCount else { return }
                let restoredImage = NSPasteboardItem()
                restoredImage.setData(png, forType: .png)
                currentPasteboard.clearContents()
                currentPasteboard.writeObjects([restoredImage])
            }
        } catch {
            return
        }
    }

    private static func availablePNGURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Pasted Image \(formatter.string(from: Date()))"
        var destination = directory.appendingPathComponent("\(stem).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem) \(suffix).png")
            suffix += 1
        }
        return destination
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.post(tap: .cghidEventTap)
        }
    }
}

private func finderShortcutCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<FinderShortcutEngine>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}
