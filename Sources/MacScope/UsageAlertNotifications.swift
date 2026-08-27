import AppKit
import Foundation
import MacScopeCore
import SwiftUI
@preconcurrency import UserNotifications

enum UsageAlertPreferences {
    enum Key {
        static let enabled = "usageAlerts.enabled"
        static let systemCPUEnabled = "usageAlerts.systemCPU.enabled"
        static let systemCPUThreshold = "usageAlerts.systemCPU.threshold"
        static let systemRAMEnabled = "usageAlerts.systemRAM.enabled"
        static let systemRAMThreshold = "usageAlerts.systemRAM.threshold"
        static let systemPowerEnabled = "usageAlerts.systemPower.enabled"
        static let systemPowerThreshold = "usageAlerts.systemPower.threshold"
        static let processCPUEnabled = "usageAlerts.processCPU.enabled"
        static let processCPUThreshold = "usageAlerts.processCPU.threshold"
        static let processMemoryEnabled = "usageAlerts.processMemory.enabled"
        static let processMemoryThreshold = "usageAlerts.processMemory.threshold"
        static let sustainedSeconds = "usageAlerts.sustainedSeconds"
        static let cooldownMinutes = "usageAlerts.cooldownMinutes"
    }

    static func configuration(from defaults: UserDefaults = .standard) -> UsageAlertConfiguration {
        let systemCPU = number(defaults, Key.systemCPUThreshold, fallback: 90, limitedTo: 1...100)
        let systemRAM = number(defaults, Key.systemRAMThreshold, fallback: 90, limitedTo: 1...100)
        let systemPower = number(defaults, Key.systemPowerThreshold, fallback: 60, limitedTo: 1...500)
        let processCPU = number(defaults, Key.processCPUThreshold, fallback: 100, limitedTo: 1...10_000)
        let processMemory = number(defaults, Key.processMemoryThreshold, fallback: 4, limitedTo: 0.05...1_024)
        let sustained = number(defaults, Key.sustainedSeconds, fallback: 10, limitedTo: 1...300)
        let cooldown = number(defaults, Key.cooldownMinutes, fallback: 5, limitedTo: 1...1_440)

        return UsageAlertConfiguration(
            enabled: boolean(defaults, Key.enabled, fallback: false),
            rules: [
                UsageAlertRule(
                    metric: .systemCPUPercent,
                    threshold: systemCPU,
                    rearmThreshold: systemCPU * 0.9,
                    isEnabled: boolean(defaults, Key.systemCPUEnabled, fallback: true)
                ),
                UsageAlertRule(
                    metric: .systemRAMPercent,
                    threshold: systemRAM,
                    rearmThreshold: systemRAM * 0.9,
                    isEnabled: boolean(defaults, Key.systemRAMEnabled, fallback: true)
                ),
                UsageAlertRule(
                    metric: .systemPowerWatts,
                    threshold: systemPower,
                    rearmThreshold: systemPower * 0.85,
                    isEnabled: boolean(defaults, Key.systemPowerEnabled, fallback: true)
                ),
                UsageAlertRule(
                    metric: .processGroupCPUPercent,
                    threshold: processCPU,
                    rearmThreshold: processCPU * 0.85,
                    isEnabled: boolean(defaults, Key.processCPUEnabled, fallback: true)
                ),
                UsageAlertRule(
                    metric: .processGroupMemoryGiB,
                    threshold: processMemory,
                    rearmThreshold: processMemory * 0.85,
                    isEnabled: boolean(defaults, Key.processMemoryEnabled, fallback: true)
                )
            ],
            sustainedDuration: .seconds(sustained),
            cooldown: .seconds(cooldown * 60)
        )
    }

    private static func boolean(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func number(
        _ defaults: UserDefaults,
        _ key: String,
        fallback: Double,
        limitedTo range: ClosedRange<Double>
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

@MainActor
final class UsageAlertNotificationController {
    private let center: UNUserNotificationCenter
    private let delegate: UsageAlertNotificationDelegate

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        let delegate = UsageAlertNotificationDelegate()
        self.delegate = delegate
        center.delegate = delegate
    }

    func deliver(_ event: UsageAlertEvent) {
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.message
            content.sound = .default
            content.threadIdentifier = "MacScope usage alerts"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}

private final class UsageAlertNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

struct UsageAlertsSettingsView: View {
    let model: AppModel

    @AppStorage(UsageAlertPreferences.Key.enabled) private var alertsEnabled = false
    @AppStorage(UsageAlertPreferences.Key.systemCPUEnabled) private var systemCPUEnabled = true
    @AppStorage(UsageAlertPreferences.Key.systemCPUThreshold) private var systemCPUThreshold = 90.0
    @AppStorage(UsageAlertPreferences.Key.systemRAMEnabled) private var systemRAMEnabled = true
    @AppStorage(UsageAlertPreferences.Key.systemRAMThreshold) private var systemRAMThreshold = 90.0
    @AppStorage(UsageAlertPreferences.Key.systemPowerEnabled) private var systemPowerEnabled = true
    @AppStorage(UsageAlertPreferences.Key.systemPowerThreshold) private var systemPowerThreshold = 60.0
    @AppStorage(UsageAlertPreferences.Key.processCPUEnabled) private var processCPUEnabled = true
    @AppStorage(UsageAlertPreferences.Key.processCPUThreshold) private var processCPUThreshold = 100.0
    @AppStorage(UsageAlertPreferences.Key.processMemoryEnabled) private var processMemoryEnabled = true
    @AppStorage(UsageAlertPreferences.Key.processMemoryThreshold) private var processMemoryThreshold = 4.0
    @AppStorage(UsageAlertPreferences.Key.sustainedSeconds) private var sustainedSeconds = 10.0
    @AppStorage(UsageAlertPreferences.Key.cooldownMinutes) private var cooldownMinutes = 5.0

    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var permissionError: String?

    var body: some View {
        SettingsPage(
            title: "Usage alerts",
            subtitle: "Notify you only after high usage remains above a threshold.",
            icon: "bell.badge.fill"
        ) {
            SettingsSection(title: "Notifications") {
                notificationPermissionRow
            }

            SettingsSection(title: "Monitoring") {
                SettingsToggleRow(
                    title: "High-usage alerts",
                    detail: "Waits for sustained usage, then applies a cooldown so a busy app cannot spam notifications.",
                    icon: "waveform.path.ecg.rectangle",
                    isOn: $alertsEnabled
                )
            }

            SettingsSection(title: "System thresholds") {
                VStack(alignment: .leading, spacing: 0) {
                    AlertThresholdRow(
                        title: "CPU usage",
                        detail: "Whole-system utilization",
                        icon: "cpu",
                        isEnabled: $systemCPUEnabled,
                        value: $systemCPUThreshold,
                        range: 10...100,
                        step: 1,
                        unit: "%"
                    )
                    SettingsDivider()
                    AlertThresholdRow(
                        title: "Memory usage",
                        detail: "Used physical memory",
                        icon: "memorychip",
                        isEnabled: $systemRAMEnabled,
                        value: $systemRAMThreshold,
                        range: 10...100,
                        step: 1,
                        unit: "%"
                    )
                    SettingsDivider()
                    AlertThresholdRow(
                        title: "System power",
                        detail: "Measured total system load",
                        icon: "bolt.fill",
                        isEnabled: $systemPowerEnabled,
                        value: $systemPowerThreshold,
                        range: 5...200,
                        step: 1,
                        unit: "W"
                    )
                }
            }

            SettingsSection(title: "Applications & process groups") {
                VStack(alignment: .leading, spacing: 0) {
                    AlertThresholdRow(
                        title: "CPU usage",
                        detail: "Parent plus child processes",
                        icon: "square.stack.3d.up",
                        isEnabled: $processCPUEnabled,
                        value: $processCPUThreshold,
                        range: 25...1_600,
                        step: 5,
                        unit: "%"
                    )
                    SettingsDivider()
                    AlertThresholdRow(
                        title: "Memory usage",
                        detail: "Parent plus child processes",
                        icon: "rectangle.stack.badge.person.crop",
                        isEnabled: $processMemoryEnabled,
                        value: $processMemoryThreshold,
                        range: 0.25...128,
                        step: 0.25,
                        unit: "GiB",
                        fractionDigits: 2
                    )
                    SettingsDivider()
                    Label("Per-process wattage is unavailable on macOS. Power alerts use measured total system power and are never attributed to an app.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "Timing") {
                VStack(alignment: .leading, spacing: 0) {
                    TimingSliderRow(
                        title: "Sustained for",
                        value: $sustainedSeconds,
                        range: 1...120,
                        unit: "seconds"
                    )
                    SettingsDivider()
                    TimingSliderRow(
                        title: "Cooldown",
                        value: $cooldownMinutes,
                        range: 1...60,
                        unit: "minutes"
                    )
                }
            }
        }
        .task {
            await refreshAuthorizationStatus()
            model.refreshUsageAlertConfiguration()
        }
        .onChange(of: settingsToken) { _, _ in
            model.refreshUsageAlertConfiguration()
        }
        .onChange(of: alertsEnabled) { _, enabled in
            guard enabled, authorizationStatus == .notDetermined else { return }
            Task { await requestAuthorization() }
        }
    }

    private var settingsToken: String {
        [
            String(alertsEnabled), String(systemCPUEnabled), String(systemCPUThreshold),
            String(systemRAMEnabled), String(systemRAMThreshold), String(systemPowerEnabled),
            String(systemPowerThreshold), String(processCPUEnabled), String(processCPUThreshold),
            String(processMemoryEnabled), String(processMemoryThreshold), String(sustainedSeconds),
            String(cooldownMinutes)
        ].joined(separator: "|")
    }

    private var notificationPermissionRow: some View {
        HStack(spacing: 14) {
            Image(systemName: permissionIcon)
                .font(.title2)
                .foregroundStyle(permissionColor)
                .frame(width: 38, height: 38)
                .background(permissionColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Notifications")
                    .font(.headline)
                Text(permissionDescription)
                    .font(.caption)
                    .foregroundStyle(permissionError == nil ? .secondary : Color.red)
            }

            Spacer()

            if authorizationStatus == .notDetermined {
                Button("Allow Notifications…") {
                    Task { await requestAuthorization() }
                }
                .macScopeGlassButton(prominent: true)
            } else if authorizationStatus == .authorized || authorizationStatus == .provisional {
                Button("Send Test Alert") {
                    Task { await sendTestAlert() }
                }
                .macScopeGlassButton()
            } else if authorizationStatus == .denied {
                Button("Open Notification Settings") {
                    openNotificationSettings()
                }
                .macScopeGlassButton()
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionDescription: String {
        if let permissionError { return permissionError }
        return switch authorizationStatus {
        case .authorized: "Allowed — banners, Notification Center, and sounds are available."
        case .provisional: "Quiet notifications are allowed."
        case .denied: "Blocked in System Settings. Alert rules can run, but banners cannot be delivered."
        case .notDetermined: "Choose Allow Notifications to receive high-usage alerts."
        case nil: "Checking notification permission…"
        @unknown default: "Notification permission status is unavailable."
        }
    }

    private var permissionIcon: String {
        switch authorizationStatus {
        case .authorized, .provisional: "bell.badge.fill"
        case .denied: "bell.slash.fill"
        default: "bell.badge"
        }
    }

    private var permissionColor: Color {
        switch authorizationStatus {
        case .authorized, .provisional: .green
        case .denied: .red
        default: MacScopeTheme.accent
        }
    }

    @MainActor
    private func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @MainActor
    private func requestAuthorization() async {
        permissionError = nil
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
        } catch {
            permissionError = error.localizedDescription
        }
    }

    @MainActor
    private func sendTestAlert() async {
        permissionError = nil
        let content = UNMutableNotificationContent()
        content.title = "MacScope alerts are ready"
        content.body = "You’ll be notified when an enabled threshold remains high for the selected duration."
        content.sound = .default
        content.threadIdentifier = "MacScope usage alerts"
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        } catch {
            permissionError = error.localizedDescription
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AlertThresholdRow: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var isEnabled: Bool
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var fractionDigits = 0

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: title, detail: detail, icon: icon)
                .frame(width: 205, alignment: .leading)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(detail)

            CleanSteppedSlider(value: $value, in: range, step: step)
                .disabled(!isEnabled)
                .accessibilityLabel("\(title) threshold")

            TextField("Threshold", value: $value, format: .number.precision(.fractionLength(fractionDigits)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fractionDigits == 0 ? 54 : 66)
                .disabled(!isEnabled)
                .accessibilityLabel("\(title) threshold")
            Text(unit)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TimingSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 110, alignment: .leading)
            CleanSteppedSlider(value: $value, in: range, step: 1)
                .accessibilityLabel(title)
            Text("\(Int(value)) \(unit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SwiftUI's stepped Slider currently exposes AppKit's dense tick strip on
/// macOS, which appears as a second line below the track. Keep the native
/// continuous appearance and quantize the binding instead.
private struct CleanSteppedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        Slider(value: quantizedValue, in: range)
    }

    private var quantizedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { candidate in
                let clamped = min(max(candidate, range.lowerBound), range.upperBound)
                guard step.isFinite, step > 0 else {
                    value = clamped
                    return
                }
                let stepsFromMinimum = ((clamped - range.lowerBound) / step).rounded()
                value = min(
                    max(range.lowerBound + stepsFromMinimum * step, range.lowerBound),
                    range.upperBound
                )
            }
        )
    }
}
