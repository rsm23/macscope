import CryptoKit
import Foundation

public enum MacScopeMCPUtilityModule: String, Codable, CaseIterable, Sendable {
    case sound
    case capture
    case windows
    case clipboard
    case notes
    case maintenance
    case power
}

public struct MacScopeMCPUtilityActionDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let module: MacScopeMCPUtilityModule
    public let title: String
    public let summary: String
    public let arguments: [String: String]
    public let producesArtifact: Bool
    public let destructive: Bool
    public let requiredPermissions: [String]

    public init(
        id: String,
        module: MacScopeMCPUtilityModule,
        title: String,
        summary: String,
        arguments: [String: String] = [:],
        producesArtifact: Bool = false,
        destructive: Bool = false,
        requiredPermissions: [String] = []
    ) {
        self.id = id
        self.module = module
        self.title = title
        self.summary = summary
        self.arguments = arguments
        self.producesArtifact = producesArtifact
        self.destructive = destructive
        self.requiredPermissions = requiredPermissions
    }
}

public enum MacScopeMCPUtilityCatalog {
    public static let actions: [MacScopeMCPUtilityActionDescriptor] = [
        .init(id: "sound.refresh", module: .sound, title: "Refresh audio state", summary: "Refresh output, input and per-application audio data."),
        .init(id: "sound.set-system-volume", module: .sound, title: "Set system volume", summary: "Set the current output volume from 0 through 1.", arguments: ["value": "Number from 0 through 1."]),
        .init(id: "sound.toggle-system-mute", module: .sound, title: "Toggle system mute", summary: "Toggle mute on the current system output."),
        .init(id: "sound.set-app-volume", module: .sound, title: "Set application volume", summary: "Set one running audio application's relative level from 0 through 2.", arguments: ["pid": "Running process identifier.", "value": "Number from 0 through 2."]),
        .init(id: "sound.toggle-app-mute", module: .sound, title: "Toggle application mute", summary: "Toggle one running audio application's mute state.", arguments: ["pid": "Running process identifier."]),
        .init(id: "sound.set-app-output", module: .sound, title: "Route application output", summary: "Route a running audio application to an output device, or clear its override.", arguments: ["pid": "Running process identifier.", "device_uid": "Output UID from sound state, or null to use the system output."]),
        .init(id: "sound.select-output", module: .sound, title: "Select system output", summary: "Make one listed output device the system default.", arguments: ["device_uid": "Output UID from sound state."]),
        .init(id: "sound.cycle-output", module: .sound, title: "Cycle audio output", summary: "Select the next available output device."),
        .init(id: "sound.select-input", module: .sound, title: "Select system input", summary: "Make one listed input device the system default.", arguments: ["device_uid": "Input UID from sound state."]),
        .init(id: "sound.toggle-input-mute", module: .sound, title: "Toggle input mute", summary: "Mute or restore the current input device."),
        .init(id: "sound.toggle-input-pin", module: .sound, title: "Pin or unpin input", summary: "Pin the current input so MacScope restores it when macOS changes devices."),
        .init(id: "sound.set-headphone-disconnect", module: .sound, title: "Configure disconnect volume", summary: "Enable or disable lowering volume after a headphone disconnect and set the target.", arguments: ["enabled": "Boolean.", "volume": "Optional number from 0 through 1."]),
        .init(id: "sound.set-music-blocker", module: .sound, title: "Configure Music blocker", summary: "Enable or disable asking Apple Music to quit when it auto-launches.", arguments: ["enabled": "Boolean."]),

        .init(id: "capture.screenshot", module: .capture, title: "Capture screenshot", summary: "Capture a full display, window or selection and save it to the configured capture folder.", arguments: ["mode": "full_screen, window or selection.", "copy_to_clipboard": "Optional Boolean.", "delay_seconds": "Optional integer from 0 through 30."], producesArtifact: true, requiredPermissions: ["Screen & System Audio Recording"]),
        .init(id: "capture.scrolling-screenshot", module: .capture, title: "Capture scrolling screenshot", summary: "Automatically capture and stitch the window under the pointer.", arguments: ["steps": "Segment count from 2 through 20.", "overlap_pixels": "Non-negative overlap.", "copy_to_clipboard": "Optional Boolean."], producesArtifact: true, requiredPermissions: ["Screen & System Audio Recording", "Input Monitoring"]),
        .init(id: "capture.recording-start", module: .capture, title: "Start screen recording", summary: "Start recording the chosen source or primary display.", arguments: ["source_id": "Optional source ID from capture state.", "system_audio": "Optional Boolean.", "microphone": "Optional Boolean."], producesArtifact: true, requiredPermissions: ["Screen & System Audio Recording"]),
        .init(id: "capture.recording-load-sources", module: .capture, title: "Load recording sources", summary: "Refresh available displays and windows for recording.", requiredPermissions: ["Screen & System Audio Recording"]),
        .init(id: "capture.recording-pause-resume", module: .capture, title: "Pause or resume recording", summary: "Toggle the current recording pause state."),
        .init(id: "capture.recording-stop", module: .capture, title: "Stop screen recording", summary: "Stop the current recording and finalize its movie artifact.", producesArtifact: true),
        .init(id: "capture.ocr-selection", module: .capture, title: "OCR a screen selection", summary: "Select part of the screen and recognize text and QR codes locally.", requiredPermissions: ["Screen & System Audio Recording"]),
        .init(id: "capture.color-picker", module: .capture, title: "Pick a screen color", summary: "Open the interactive system color sampler."),
        .init(id: "capture.camera-start", module: .capture, title: "Start camera preview", summary: "Start the floating local camera preview.", requiredPermissions: ["Camera"]),
        .init(id: "capture.camera-stop", module: .capture, title: "Stop camera preview", summary: "Stop the local camera preview."),

        .init(id: "windows.arrange", module: .windows, title: "Arrange active window", summary: "Place the active window in a supported layout.", arguments: ["placement": "maximize, center, left_half, right_half, top_half, bottom_half, top_left, top_right, bottom_left, bottom_right, left_third, center_third or right_third."], requiredPermissions: ["Accessibility"]),
        .init(id: "windows.restore", module: .windows, title: "Restore previous layout", summary: "Restore the last recorded active-window frame.", requiredPermissions: ["Accessibility"]),
        .init(id: "windows.move-display", module: .windows, title: "Move active window between displays", summary: "Move the active window to an adjacent display.", arguments: ["offset": "-1 for previous or 1 for next."], requiredPermissions: ["Accessibility"]),
        .init(id: "windows.edge-snap", module: .windows, title: "Configure edge snapping", summary: "Enable or disable edge snapping.", arguments: ["enabled": "Boolean."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.modifier-drag", module: .windows, title: "Configure modifier dragging", summary: "Enable or disable move/resize-anywhere gestures.", arguments: ["enabled": "Boolean."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.green-button-maximize", module: .windows, title: "Configure green-button maximize", summary: "Enable or disable maximize without creating a Space.", arguments: ["enabled": "Boolean."], requiredPermissions: ["Accessibility"]),
        .init(id: "windows.set-input-feature", module: .windows, title: "Configure an input utility", summary: "Enable or disable a keyboard, mouse or Finder input utility.", arguments: ["feature": "keyboard_debounce, focus_follows_mouse, super_key, smooth_scrolling, plain_text_paste or finder_shortcuts.", "enabled": "Boolean."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.set-keyboard-debounce", module: .windows, title: "Configure keyboard debounce", summary: "Set debounce interval and enabled state.", arguments: ["enabled": "Boolean.", "interval_ms": "Number from 20 through 250."], requiredPermissions: ["Input Monitoring"]),
        .init(id: "windows.set-scroll-direction", module: .windows, title: "Configure mouse scroll direction", summary: "Invert vertical and horizontal discrete mouse-wheel axes independently.", arguments: ["vertical": "Boolean.", "horizontal": "Boolean."]),
        .init(id: "windows.set-mouse-side-buttons", module: .windows, title: "Configure mouse side buttons", summary: "Enable or disable configured mouse side-button shortcuts.", arguments: ["enabled": "Boolean."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.set-focus-follows-mouse", module: .windows, title: "Configure focus follows mouse", summary: "Set focus delay and enabled state.", arguments: ["enabled": "Boolean.", "delay_ms": "Number from 100 through 1000."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.set-smooth-scrolling", module: .windows, title: "Configure smooth scrolling", summary: "Set wheel smoothing intensity and enabled state.", arguments: ["enabled": "Boolean.", "intensity": "Number from 0.5 through 2."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "windows.activate-app", module: .windows, title: "Activate application", summary: "Bring a currently listed application to the front.", arguments: ["pid": "PID from windows state."]),
        .init(id: "windows.toggle-hidden-app", module: .windows, title: "Hide or unhide application", summary: "Toggle a currently listed application's hidden state.", arguments: ["pid": "PID from windows state."]),
        .init(id: "windows.set-quit-on-close", module: .windows, title: "Configure quit on close", summary: "Enable or disable quitting a listed application after its last window closes.", arguments: ["pid": "PID from windows state.", "enabled": "Boolean."], requiredPermissions: ["Accessibility"]),

        .init(id: "clipboard.set-monitoring", module: .clipboard, title: "Configure clipboard history", summary: "Enable or disable clipboard history monitoring.", arguments: ["enabled": "Boolean."]),
        .init(id: "clipboard.clear", module: .clipboard, title: "Clear clipboard history", summary: "Clear unpinned clipboard history entries.", destructive: true),
        .init(id: "clipboard.add-snippet", module: .clipboard, title: "Save text snippet", summary: "Create a named snippet with an optional expansion trigger and folder.", arguments: ["title": "Snippet title.", "text": "Snippet content.", "trigger": "Optional trigger.", "folder": "Optional folder."]),
        .init(id: "clipboard.add-shelf-files", module: .clipboard, title: "Park files on the shelf", summary: "Add exact file or folder paths to the session shelf.", arguments: ["paths": "Array of existing absolute paths."]),
        .init(id: "clipboard.move-shelf-files", module: .clipboard, title: "Move shelf files", summary: "Move all parked files and folders to an exact destination directory.", arguments: ["destination": "Existing absolute directory path."], destructive: true),
        .init(id: "clipboard.add-shelf-text", module: .clipboard, title: "Park text on the shelf", summary: "Add text or a URL to the session shelf.", arguments: ["text": "Non-empty text."]),
        .init(id: "clipboard.clean-url", module: .clipboard, title: "Clean clipboard URL", summary: "Remove known tracking parameters from the current clipboard URL."),
        .init(id: "clipboard.set-automatic-url-cleaning", module: .clipboard, title: "Configure automatic URL cleaning", summary: "Enable or disable cleaning tracking parameters whenever a URL is copied.", arguments: ["enabled": "Boolean."]),
        .init(id: "clipboard.schedule-clear", module: .clipboard, title: "Schedule clipboard clear", summary: "Schedule session history clearing, or cancel it.", arguments: ["seconds": "Positive seconds, or null to cancel."]),
        .init(id: "clipboard.set-clear-events", module: .clipboard, title: "Configure clipboard clear events", summary: "Choose whether clipboard history clears on system sleep, display sleep, and screen lock.", arguments: ["system_sleep": "Boolean.", "display_sleep": "Boolean.", "screen_lock": "Boolean."]),
        .init(id: "clipboard.set-text-expansion", module: .clipboard, title: "Configure text expansion", summary: "Enable or disable saved snippet expansion while typing.", arguments: ["enabled": "Boolean."], requiredPermissions: ["Accessibility", "Input Monitoring"]),
        .init(id: "clipboard.delete-snippet", module: .clipboard, title: "Delete saved snippet", summary: "Delete one saved snippet by ID.", arguments: ["id": "Snippet UUID from clipboard state."], destructive: true),
        .init(id: "clipboard.remove-shelf-file", module: .clipboard, title: "Remove shelf file", summary: "Remove one parked file reference without deleting the file.", arguments: ["path": "Exact path from clipboard state."]),
        .init(id: "clipboard.remove-shelf-text", module: .clipboard, title: "Remove shelf text", summary: "Remove one parked text item.", arguments: ["id": "Shelf text UUID from clipboard state."]),

        .init(id: "notes.create", module: .notes, title: "Create scratchpad", summary: "Create a new Markdown scratchpad.", arguments: ["name": "Optional tab name.", "text": "Optional initial Markdown text."]),
        .init(id: "notes.update", module: .notes, title: "Update scratchpad", summary: "Replace one scratchpad's Markdown text.", arguments: ["id": "Scratchpad UUID from notes state.", "text": "New Markdown text."]),
        .init(id: "notes.rename", module: .notes, title: "Rename scratchpad", summary: "Rename one scratchpad.", arguments: ["id": "Scratchpad UUID.", "name": "New name."]),
        .init(id: "notes.clear", module: .notes, title: "Clear scratchpad", summary: "Clear one scratchpad while keeping its tab.", arguments: ["id": "Scratchpad UUID."], destructive: true),
        .init(id: "notes.delete", module: .notes, title: "Delete scratchpad", summary: "Delete one scratchpad tab.", arguments: ["id": "Scratchpad UUID."], destructive: true),
        .init(id: "notes.set-auto-clear", module: .notes, title: "Configure scratchpad auto-clear", summary: "Set the quiet period before all scratchpad text clears.", arguments: ["seconds": "Positive seconds, or null to disable."]),

        .init(id: "maintenance.scan-applications", module: .maintenance, title: "Scan installed applications", summary: "Refresh installed application and leftover-file data."),
        .init(id: "maintenance.scan-downloads", module: .maintenance, title: "Scan large downloads", summary: "Refresh large Downloads candidates."),
        .init(id: "maintenance.scan-cleanup", module: .maintenance, title: "Scan cleanup candidates", summary: "Refresh cache and log cleanup candidates."),
        .init(id: "maintenance.check-updates", module: .maintenance, title: "Check application updates", summary: "Check enabled application update sources."),
        .init(id: "maintenance.check-homebrew", module: .maintenance, title: "Check Homebrew", summary: "Refresh outdated Homebrew packages."),
        .init(id: "maintenance.search-homebrew", module: .maintenance, title: "Search Homebrew", summary: "Search Homebrew formulae and casks.", arguments: ["query": "Search query."]),
        .init(id: "maintenance.move-to-trash", module: .maintenance, title: "Move files to Trash", summary: "Move exact allowlisted candidate paths to recoverable Trash.", arguments: ["paths": "Array of absolute paths returned by maintenance state."], destructive: true),
        .init(id: "maintenance.scan-messaging-downloads", module: .maintenance, title: "Scan messaging downloads", summary: "Refresh metadata-confirmed messaging download candidates."),
        .init(id: "maintenance.set-cleanup-schedule", module: .maintenance, title: "Configure cleanup scanning", summary: "Set the automatic scan interval or turn it off.", arguments: ["hours": "Positive hours, or null to disable."]),
        .init(id: "maintenance.set-update-settings", module: .maintenance, title: "Configure update checks", summary: "Configure background checks and App Store/Homebrew sources.", arguments: ["background": "Boolean.", "app_store": "Boolean.", "homebrew": "Boolean."]),
        .init(id: "maintenance.upgrade-homebrew", module: .maintenance, title: "Upgrade Homebrew item", summary: "Upgrade one exact outdated formula or cask from maintenance state.", arguments: ["id": "Homebrew item ID from maintenance state."]),
        .init(id: "maintenance.set-homebrew-installed", module: .maintenance, title: "Install or remove Homebrew item", summary: "Install or remove one exact current Homebrew search result.", arguments: ["id": "Search item ID from maintenance state.", "installed": "Desired installed state."], destructive: true),
        .init(id: "maintenance.media-load-images", module: .maintenance, title: "Load images", summary: "Load existing local image paths for media operations.", arguments: ["paths": "Array of existing absolute image paths."]),
        .init(id: "maintenance.media-convert-images", module: .maintenance, title: "Convert images", summary: "Convert loaded images beside their sources.", arguments: ["format": "png or jpeg.", "quality": "Number from 0.1 through 1.", "maximum_dimension": "Optional positive pixels.", "watermark": "Optional text."], producesArtifact: true),
        .init(id: "maintenance.media-extract-text", module: .maintenance, title: "Extract text from image", summary: "Run local Vision OCR on the first loaded image."),
        .init(id: "maintenance.media-create-gif", module: .maintenance, title: "Create animated GIF", summary: "Create a GIF from loaded images.", arguments: ["frame_duration": "Seconds from 0.04 through 10."], producesArtifact: true),
        .init(id: "maintenance.media-load-video", module: .maintenance, title: "Load video", summary: "Load an existing local video path for editing.", arguments: ["path": "Existing absolute video path."]),
        .init(id: "maintenance.media-compress-video", module: .maintenance, title: "Compress video", summary: "Create a compressed MP4 from the loaded video.", producesArtifact: true),
        .init(id: "maintenance.media-trim-video", module: .maintenance, title: "Trim video", summary: "Export the selected interval of the loaded video.", arguments: ["start": "Start seconds.", "end": "End seconds."], producesArtifact: true),
        .init(id: "maintenance.media-cut-video", module: .maintenance, title: "Remove video range", summary: "Export the loaded video with one interval removed.", arguments: ["start": "Start seconds.", "end": "End seconds."], producesArtifact: true),
        .init(id: "maintenance.media-crop-video", module: .maintenance, title: "Crop video", summary: "Crop percentages from each edge of the loaded video.", arguments: ["left": "0 through 45.", "right": "0 through 45.", "top": "0 through 45.", "bottom": "0 through 45."], producesArtifact: true),
        .init(id: "maintenance.media-export-video-gif", module: .maintenance, title: "Export video GIF", summary: "Export the loaded video as an animated GIF.", arguments: ["fps": "Frames per second from 2 through 24."], producesArtifact: true),

        .init(id: "power.keep-awake-start", module: .power, title: "Start Keep Awake", summary: "Start a supported power assertion.", arguments: ["duration_seconds": "Optional positive duration; omit for indefinite.", "include_display": "Optional Boolean."]),
        .init(id: "power.keep-awake-stop", module: .power, title: "Stop Keep Awake", summary: "Release the active Keep Awake assertion."),
        .init(id: "power.set-keep-awake-automations", module: .power, title: "Configure Keep Awake automations", summary: "Start Keep Awake automatically on AC power or with an external display.", arguments: ["on_ac_power": "Boolean.", "with_external_display": "Boolean."]),
        .init(id: "power.cleaning-mode-start", module: .power, title: "Start cleaning mode", summary: "Block local keyboard and mouse input for a bounded interval.", arguments: ["duration_seconds": "Duration from 10 through 300."], requiredPermissions: ["Input Monitoring"]),
        .init(id: "power.cleaning-mode-stop", module: .power, title: "Stop cleaning mode", summary: "Stop cleaning mode immediately."),
        .init(id: "power.set-display-brightness", module: .power, title: "Set display brightness", summary: "Set supported hardware brightness for one display.", arguments: ["display_id": "Display identifier from power state.", "value": "Number from 0 through 1."]),
        .init(id: "power.set-software-dimming", module: .power, title: "Set software dimming", summary: "Set reversible software dimming for one display.", arguments: ["display_id": "Display identifier from power state.", "value": "Number from 0 through 1."]),
        .init(id: "power.restore-software-dimming", module: .power, title: "Restore software dimming", summary: "Remove all MacScope software dimming overlays.")
    ]

    public static func action(id: String) -> MacScopeMCPUtilityActionDescriptor? {
        actions.first { $0.id == id }
    }
}

public struct MacScopeMCPUtilityRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case state, run }
    public let id: UUID
    public let kind: Kind
    public let module: MacScopeMCPUtilityModule?
    public let actionID: String?
    public let arguments: [String: MacScopeMCPJSONValue]
    public let serverPID: Int32
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        module: MacScopeMCPUtilityModule? = nil,
        actionID: String? = nil,
        arguments: [String: MacScopeMCPJSONValue] = [:],
        serverPID: Int32
    ) {
        self.id = id
        self.kind = kind
        self.module = module
        self.actionID = actionID
        self.arguments = arguments
        self.serverPID = serverPID
        self.createdAt = Date()
    }
}

public struct MacScopeMCPUtilityResponse: Codable, Sendable {
    public let requestID: UUID
    public let result: MacScopeMCPJSONValue?
    public let error: String?

    public init(requestID: UUID, result: MacScopeMCPJSONValue? = nil, error: String? = nil) {
        self.requestID = requestID
        self.result = result
        self.error = error
    }
}

public enum MacScopeMCPUtilityTransport {
    public static let maximumMessageBytes = 16 * 1_024 * 1_024

    public static func socketURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacScope", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("mcp-utility.sock")
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public enum MacScopeMCPArtifactKind: String, Codable, CaseIterable, Sendable {
    case screenshot
    case recording
}

public struct MacScopeMCPArtifact: Codable, Hashable, Sendable {
    public let id: String
    public let kind: MacScopeMCPArtifactKind
    public let name: String
    public let mimeType: String
    public let byteCount: Int64
    public let modifiedAt: Date
    public let path: String?
}

public struct MacScopeMCPArtifactChunk: Codable, Hashable, Sendable {
    public let artifact: MacScopeMCPArtifact
    public let offset: Int64
    public let byteCount: Int
    public let endOfFile: Bool
    public let base64: String
}

public enum MacScopeMCPArtifactStore {
    public static func list(
        kind: MacScopeMCPArtifactKind? = nil,
        includeSensitive: Bool,
        limit: Int = 100
    ) -> [MacScopeMCPArtifact] {
        Array(scan(includeSensitive: includeSensitive)
            .filter { kind == nil || $0.artifact.kind == kind }
            .sorted { $0.artifact.modifiedAt > $1.artifact.modifiedAt }
            .prefix(min(max(limit, 1), 1_000)))
            .map(\.artifact)
    }

    public static func read(id: String, offset: Int64, length: Int) throws -> MacScopeMCPArtifactChunk {
        guard let match = scan(includeSensitive: true).first(where: { $0.artifact.id == id }) else {
            throw MacScopeMCPError.unknownArtifact(id)
        }
        let boundedOffset = max(offset, 0)
        let boundedLength = min(max(length, 1), 4 * 1_024 * 1_024)
        let handle = try FileHandle(forReadingFrom: match.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(boundedOffset))
        let data = try handle.read(upToCount: boundedLength) ?? Data()
        let end = boundedOffset + Int64(data.count) >= match.artifact.byteCount
        return MacScopeMCPArtifactChunk(
            artifact: match.artifact,
            offset: boundedOffset,
            byteCount: data.count,
            endOfFile: end,
            base64: data.base64EncodedString()
        )
    }

    private struct Match { let artifact: MacScopeMCPArtifact; let url: URL }

    private static func scan(includeSensitive: Bool) -> [Match] {
        roots().flatMap { kind, root in
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let enumerator = FileManager.default.enumerator(
                at: resolvedRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            return (enumerator?.allObjects as? [URL] ?? []).compactMap { candidate -> Match? in
                let url = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard isDescendant(url, of: resolvedRoot), allowedExtension(url, kind: kind) else { return nil }
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                let mime = mimeType(url.pathExtension)
                let path = includeSensitive ? url.path : nil
                return Match(
                    artifact: MacScopeMCPArtifact(
                        id: artifactID(url),
                        kind: kind,
                        name: url.lastPathComponent,
                        mimeType: mime,
                        byteCount: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        path: path
                    ),
                    url: url
                )
            }
        }
    }

    private static func roots() -> [(MacScopeMCPArtifactKind, URL)] {
        let defaults = UserDefaults(suiteName: "local.taskmanager.MacScope")
        let screenshotRoot: URL
        if let path = defaults?.string(forKey: "utility.captureFolder"), !path.isEmpty {
            screenshotRoot = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            screenshotRoot = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacScope Captures", isDirectory: true)
        }
        let recordingRoot = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacScope Recordings", isDirectory: true)
        return [(.screenshot, screenshotRoot), (.recording, recordingRoot)]
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        return components.count > rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }

    private static func allowedExtension(_ url: URL, kind: MacScopeMCPArtifactKind) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .screenshot: return ["png", "jpg", "jpeg", "tiff", "heic"].contains(ext)
        case .recording: return ["mov", "mp4", "m4v", "gif"].contains(ext)
        }
    }

    private static func artifactID(_ url: URL) -> String {
        SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "tiff": "image/tiff"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "mp4", "m4v": "video/mp4"
        default: "video/quicktime"
        }
    }
}
