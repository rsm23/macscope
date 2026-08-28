import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreServices
import Foundation
import Observation
import Security
import UserNotifications

enum MacScopePermissionID: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case microphone
    case camera
    case notifications
    case automation
    case fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .notifications: "Notifications"
        case .automation: "Automation"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    var icon: String {
        switch self {
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard.badge.eye"
        case .screenRecording: "rectangle.inset.filled.badge.record"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        case .notifications: "bell.badge.fill"
        case .automation: "gearshape.2.fill"
        case .fullDiskAccess: "externaldrive.badge.checkmark"
        }
    }

    var utilitySummary: String {
        switch self {
        case .accessibility:
            "Window layouts, edge snapping, move/resize, app switching, and global paste."
        case .inputMonitoring:
            "Edge snapping, modifier dragging, keyboard utilities, mouse utilities, and global shortcuts."
        case .screenRecording:
            "Screenshots, scrolling capture, screen recording, OCR, live window previews, and per-app audio."
        case .microphone:
            "Optional microphone audio in screen recordings."
        case .camera:
            "The floating local camera preview."
        case .notifications:
            "High-usage alerts and background application-update results."
        case .automation:
            "Finder and System Events quick actions, including appearance and Trash controls."
        case .fullDiskAccess:
            "Deep application-leftover discovery and protected storage inspection."
        }
    }

    var settingsURL: URL? {
        let address = switch self {
        case .accessibility:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .notifications:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .automation:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .fullDiskAccess:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        }
        return URL(string: address)
    }

    var supportsDirectRequest: Bool {
        self != .fullDiskAccess
    }
}

enum MacScopePermissionStatus: Equatable, Sendable {
    case allowed
    case denied
    case notAllowed
    case notDetermined
    case restricted
    case needsReview(String)
    case checking

    var title: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Blocked"
        case .notAllowed: "Not allowed"
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .needsReview: "Review needed"
        case .checking: "Checking…"
        }
    }

    var isAllowed: Bool {
        self == .allowed
    }

    var actionLabel: String {
        switch self {
        case .notAllowed, .notDetermined: "Request Access"
        case .allowed: "Review…"
        case .denied, .restricted, .needsReview: "Open Settings"
        case .checking: "Checking…"
        }
    }

    var note: String? {
        if case .needsReview(let note) = self { return note }
        return nil
    }
}

struct MacScopePermissionItem: Identifiable, Equatable, Sendable {
    let id: MacScopePermissionID
    var status: MacScopePermissionStatus

    var title: String { id.title }
    var icon: String { id.icon }
    var utilitySummary: String { id.utilitySummary }
}

@MainActor
@Observable
final class PermissionCenter {
    typealias AccessRequester = @MainActor (MacScopePermissionID) async throws -> Bool
    typealias SettingsOpener = @MainActor (MacScopePermissionID) -> Bool
    typealias AfterRequest = @MainActor () async -> Void

    private(set) var permissions = MacScopePermissionID.allCases.map {
        MacScopePermissionItem(id: $0, status: .checking)
    }
    private(set) var isRefreshing = false
    private(set) var requesting: Set<MacScopePermissionID> = []
    private(set) var lastCheckedAt: Date?
    private(set) var message: String?
    private let accessRequester: AccessRequester
    private let settingsOpener: SettingsOpener
    private let afterRequest: AfterRequest?

    init(
        permissions: [MacScopePermissionItem]? = nil,
        accessRequester: @escaping AccessRequester = PermissionCenter.requestSystemAccess,
        settingsOpener: @escaping SettingsOpener = PermissionCenter.openSystemSettings,
        afterRequest: AfterRequest? = nil
    ) {
        if let permissions { self.permissions = permissions }
        self.accessRequester = accessRequester
        self.settingsOpener = settingsOpener
        self.afterRequest = afterRequest
    }

    var allowedCount: Int {
        permissions.count(where: { $0.status.isAllowed })
    }

    var buildIdentityWarning: String? {
        Self.currentBuildIdentityWarning()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let automationStatus = await Task.detached(priority: .utility) {
            Self.automationStatus(askUserIfNeeded: false)
        }.value
        let fullDiskStatus = await Task.detached(priority: .utility) {
            Self.fullDiskAccessStatus()
        }.value

        permissions = MacScopePermissionID.allCases.map { id in
            MacScopePermissionItem(
                id: id,
                status: Self.currentStatus(
                    for: id,
                    notificationStatus: notificationSettings.authorizationStatus,
                    automationStatus: automationStatus,
                    fullDiskStatus: fullDiskStatus
                )
            )
        }
        lastCheckedAt = Date()
        isRefreshing = false
    }

    func request(_ id: MacScopePermissionID) async {
        guard !requesting.contains(id) else { return }
        requesting.insert(id)
        defer { requesting.remove(id) }
        message = nil

        let current = permissions.first(where: { $0.id == id })?.status
        if (current != .notDetermined && current != .notAllowed) || !id.supportsDirectRequest {
            openSettings(for: id)
            return
        }

        do {
            let granted = try await accessRequester(id)
            if !granted {
                openSettings(for: id)
                if message == nil {
                    message = "macOS did not grant \(id.title). Enable the current MacScope entry in System Settings, then return here."
                }
            }
        } catch {
            message = error.localizedDescription
            openSettings(for: id)
        }

        if let afterRequest {
            await afterRequest()
        } else {
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        }
    }

    func openSettings(for id: MacScopePermissionID) {
        guard id.settingsURL != nil else {
            message = "The matching System Settings pane is unavailable."
            return
        }
        guard settingsOpener(id) else {
            message = "System Settings could not open the \(id.title) pane."
            return
        }
        message = "\(id.title) settings opened. Enable the current MacScope entry, then return here."
    }

    func isRequesting(_ id: MacScopePermissionID) -> Bool {
        requesting.contains(id)
    }

    nonisolated static func currentStatus(
        for id: MacScopePermissionID,
        notificationStatus: UNAuthorizationStatus,
        automationStatus: MacScopePermissionStatus,
        fullDiskStatus: MacScopePermissionStatus
    ) -> MacScopePermissionStatus {
        switch id {
        case .accessibility:
            AXIsProcessTrusted() ? .allowed : .denied
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .allowed : .notAllowed
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .allowed : .notAllowed
        case .microphone:
            captureStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            captureStatus(AVCaptureDevice.authorizationStatus(for: .video))
        case .notifications:
            notificationPermissionStatus(notificationStatus)
        case .automation:
            automationStatus
        case .fullDiskAccess:
            fullDiskStatus
        }
    }

    nonisolated static func captureStatus(_ status: AVAuthorizationStatus) -> MacScopePermissionStatus {
        switch status {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .needsReview("macOS returned an unknown authorization state.")
        }
    }

    nonisolated static func notificationPermissionStatus(
        _ status: UNAuthorizationStatus
    ) -> MacScopePermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .needsReview("macOS returned an unknown authorization state.")
        }
    }

    private static func requestSystemAccess(_ id: MacScopePermissionID) async throws -> Bool {
        switch id {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .notifications:
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        case .automation:
            return await Task.detached(priority: .userInitiated) {
                Self.automationStatus(askUserIfNeeded: true).isAllowed
            }.value
        case .fullDiskAccess:
            return false
        }
    }

    private static func openSystemSettings(_ id: MacScopePermissionID) -> Bool {
        if let url = id.settingsURL, NSWorkspace.shared.open(url) { return true }
        guard let privacyURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ) else { return false }
        return NSWorkspace.shared.open(privacyURL)
    }

    private nonisolated static func currentBuildIdentityWarning() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        guard teamIdentifier?.isEmpty != false else { return nil }
        return "This development build is ad-hoc signed. macOS may treat every rebuild as a new app and invalidate privacy permissions. Use a Developer ID-signed build for persistent authorization."
    }

    private nonisolated static func automationStatus(
        askUserIfNeeded: Bool
    ) -> MacScopePermissionStatus {
        let targets = ["com.apple.finder", "com.apple.systemevents"]
        let results = targets.map {
            automationStatus(targetBundleIdentifier: $0, askUserIfNeeded: askUserIfNeeded)
        }
        if results.allSatisfy({ $0 == noErr }) { return .allowed }
        if results.contains(OSStatus(errAEEventNotPermitted)) { return .denied }
        if results.contains(OSStatus(errAEEventWouldRequireUserConsent)) { return .notDetermined }
        if results.contains(OSStatus(procNotFound)) {
            return .needsReview("Automation is granted separately for Finder and System Events; a target is not currently running.")
        }
        let failures = results.filter { $0 != noErr }
        return .needsReview("Automation status could not be verified (OSStatus \(failures.first ?? -1)).")
    }

    private nonisolated static func automationStatus(
        targetBundleIdentifier: String,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        guard let data = targetBundleIdentifier.data(using: .utf8) else { return OSStatus(paramErr) }
        var target = AEAddressDesc()
        let createStatus = data.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bytes.baseAddress,
                data.count,
                &target
            )
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    private nonisolated static func fullDiskAccessStatus() -> MacScopePermissionStatus {
        let protectedFiles = [
            "Library/Safari/History.db",
            "Library/Messages/chat.db"
        ].map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0) }

        for url in protectedFiles where FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.close()
                return .allowed
            } catch {
                let code = (error as NSError).code
                if code == NSFileReadNoPermissionError || code == Int(EACCES) || code == Int(EPERM) {
                    return .denied
                }
            }
        }
        return .needsReview("macOS has no public Full Disk Access status API; review the current app entry in System Settings.")
    }
}
