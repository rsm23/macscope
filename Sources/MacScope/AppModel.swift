import Foundation
import MacScopeCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var snapshot = SystemSnapshot()
    /// Startup definitions have their own observation surface because the main
    /// system snapshot changes every sampling tick while launchd discovery runs
    /// only once per minute (or on demand).
    var startupItems: [StartupItem] = []
    var history: [SystemSnapshot] = []
    var isRunning = false
    var lastError: String?
    var selectedSection: AppSection? = .overview
    var selectedUtilityTab = UtilityTab.sound
    var processSearch = ""
    var startupSearch = ""
    var menuBarPresentation = MenuBarPresentation()
    let audioMixer = AudioMixerService()
    let musicBlocker = MusicAutoLaunchBlocker()
    let workspace = WorkspaceUtilityService()
    let snippetShelf = SnippetShelfService()
    let clipboard = ClipboardHistoryService()
    let maintenance = MaintenanceUtilityService()
    let screenshots = ScreenshotService()
    let keepAwake = KeepAwakeService()
    let quickToggles = QuickToggleService()
    let commandBar = CommandBarService()
    let screenOCR = ScreenOCRService()
    let colorPicker = ColorPickerService()
    let screenRecorder = ScreenRecordingService()
    let cameraPreview = CameraPreviewService()
    let keyboardDebounce = KeyboardDebounceService()
    let scrollDirection = ScrollDirectionService()
    let mouseSideButtons = MouseSideButtonService()
    let focusFollowsMouse = FocusFollowsMouseService()
    let superKey = SuperKeyService()
    let smoothScrolling = SmoothScrollingService()
    let plainTextPaste = PlainTextPasteService()
    let finderShortcuts = FinderShortcutService()
    let scratchpad = ScratchpadService()
    let media = MediaUtilityService()
    let displayControl = DisplayControlService()
    let cleaningMode = CleaningModeService()
    @ObservationIgnored private lazy var mcpUtilityController = MacScopeMCPUtilityController(model: self)

    private let engine: TelemetryEngine
    private let alertNotifications: UsageAlertNotificationController
    private var streamTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var appliedStartupRevision: UInt64?
    private var lastMenuBarPresentationAt: Date?
    private var didStartAutomatically = false

    init(
        engine: TelemetryEngine = TelemetryEngine(),
        alertNotifications: UsageAlertNotificationController = UsageAlertNotificationController()
    ) {
        self.engine = engine
        self.alertNotifications = alertNotifications
        if UtilityFeatureStore.isEnabled(.clipboard) { clipboard.restorePreference() }
        // MCP utility requests must work for a menu-bar-only launch even when the
        // main window is restored closed and its SwiftUI task never appears.
        mcpUtilityController.start()
    }

    func start() {
        guard streamTask == nil else { return }
        isRunning = true
        streamTask = Task { [weak self, engine] in
            await engine.setProcessHistoryEnabled(UserDefaults.standard.bool(forKey: "processHistoryEnabled"))
            await engine.setUsageAlertConfiguration(UsageAlertPreferences.configuration())
            let alertStream = await engine.alertStream()
            let stream = await engine.stream()
            self?.alertTask = Task { [weak self] in
                for await alert in alertStream {
                    guard !Task.isCancelled else { return }
                    self?.alertNotifications.deliver(alert)
                }
            }
            await engine.start()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                if let revision = snapshot.startupRevision {
                    if self?.appliedStartupRevision != revision {
                        self?.startupItems = snapshot.startupItems
                        self?.appliedStartupRevision = revision
                    }
                } else if self?.startupItems != snapshot.startupItems {
                    // Compatibility path for manually constructed or older
                    // decoded snapshots that predate the collector revision.
                    self?.startupItems = snapshot.startupItems
                }
                self?.snapshot = snapshot
                self?.reconcileSelectedSection(with: snapshot)
                // Charts never consume the heavy process/startup/socket
                // collections. Keeping them in every in-memory history sample
                // caused large arrays to be retained and released on the main
                // actor while the process table was being scrolled.
                self?.history.append(snapshot.chartHistorySample)
                if let count = self?.history.count, count > 180 {
                    self?.history.removeFirst(count - 180)
                }
                self?.refreshMenuBarPresentation(with: snapshot)
            }
        }
    }

    func startAutomaticallyIfNeeded() {
        guard !didStartAutomatically else { return }
        didStartAutomatically = true
        if UtilityFeatureStore.isEnabled(.capture) { screenshots.refresh() }
        start()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        alertTask?.cancel()
        alertTask = nil
        isRunning = false
        Task { await engine.stop() }
    }

    func setProfile(_ profile: SamplingProfile) {
        Task { await engine.setProfile(profile) }
    }

    func setProcessHistoryEnabled(_ enabled: Bool) {
        Task { await engine.setProcessHistoryEnabled(enabled) }
    }

    func refreshUsageAlertConfiguration() {
        let configuration = UsageAlertPreferences.configuration()
        Task { await engine.setUsageAlertConfiguration(configuration) }
    }

    func refreshStartup() {
        Task { await engine.refreshStartup() }
    }

    private func refreshMenuBarPresentation(with snapshot: SystemSnapshot) {
        if let lastMenuBarPresentationAt,
           snapshot.timestamp >= lastMenuBarPresentationAt,
           snapshot.timestamp.timeIntervalSince(lastMenuBarPresentationAt) < 1 {
            return
        }
        menuBarPresentation = MenuBarPresentation(snapshot: snapshot, history: history)
        lastMenuBarPresentationAt = snapshot.timestamp
    }

    private func reconcileSelectedSection(with snapshot: SystemSnapshot) {
        let capabilities = snapshot.acceleratorCapabilities
        switch selectedSection {
        case .gpu where !capabilities.gpuTelemetryAvailable,
             .npu where !capabilities.aneTelemetryAvailable:
            selectedSection = .overview
        default:
            break
        }
    }

    var filteredProcesses: [ProcessSnapshot] {
        guard !processSearch.isEmpty else { return snapshot.processes }
        return snapshot.processes.filter {
            $0.name.localizedCaseInsensitiveContains(processSearch)
                || String($0.pid).contains(processSearch)
                || String($0.parentPID).contains(processSearch)
                || String($0.userID).contains(processSearch)
                || $0.state.localizedCaseInsensitiveContains(processSearch)
                || ($0.executablePath?.localizedCaseInsensitiveContains(processSearch) ?? false)
        }
    }

    var availableSections: [AppSection] {
        let capabilities = snapshot.acceleratorCapabilities
        return AppSection.allCases.filter { section in
            switch section {
            case .gpu:
                return capabilities.gpuTelemetryAvailable
            case .npu:
                return capabilities.aneTelemetryAvailable
            default:
                return true
            }
        }
    }
}

private extension SystemSnapshot {
    var chartHistorySample: SystemSnapshot {
        SystemSnapshot(
            timestamp: timestamp,
            cpuUsage: cpuUsage,
            cpuUser: cpuUser,
            cpuSystem: cpuSystem,
            loadAverages: loadAverages,
            cores: cores,
            memory: memory,
            battery: battery,
            networks: networks,
            disks: disks,
            inventory: inventory,
            deep: deep,
            metrics: metrics
        )
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cpu = "CPU"
    case gpu = "GPU"
    case npu = "NPU / ANE"
    case memory = "Memory"
    case thermals = "Thermals"
    case power = "Power & Battery"
    case network = "Network"
    case storage = "Storage & SMART"
    case processes = "Processes"
    case startup = "Startup"
    case utilities = "Utilities"
    case features = "macOS Features"
    case hardware = "Hardware"
    case raw = "Raw Data"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .npu: "brain.head.profile"
        case .memory: "memorychip"
        case .thermals: "thermometer.medium"
        case .power: "bolt"
        case .network: "network"
        case .storage: "internaldrive"
        case .processes: "list.bullet.rectangle"
        case .startup: "power"
        case .utilities: "wrench.and.screwdriver"
        case .features: "switch.2"
        case .hardware: "desktopcomputer"
        case .raw: "chevron.left.forwardslash.chevron.right"
        }
    }
}
