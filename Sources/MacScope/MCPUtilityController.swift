import AppKit
import Darwin
import Foundation
import MacScopeCore
import MacScopeMCPBridge
import Security

/// Executes MCP utility requests inside the running app so protected macOS APIs
/// are always attributed to the signed MacScope process that owns the user's TCC grants.
@MainActor
final class MacScopeMCPUtilityController: NSObject {
    private unowned let model: AppModel
    private var socketServer: MCPUtilitySocketServer?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        guard socketServer == nil else { return }
        let server = MCPUtilitySocketServer(controller: self)
        do {
            try server.start()
            socketServer = server
        } catch {
            FileHandle.standardError.write(Data("MacScope could not start the MCP utility socket: \(error.localizedDescription)\n".utf8))
        }
    }

    fileprivate func handle(_ data: Data, connectionPID: Int32) -> Data {
        let response: MacScopeMCPUtilityResponse
        do {
            let request = try MacScopeMCPUtilityTransport.decode(MacScopeMCPUtilityRequest.self, from: data)
            guard abs(request.createdAt.timeIntervalSinceNow) < 60 else {
                throw ControllerError.invalidRequest("The utility request has expired.")
            }
            guard request.serverPID == connectionPID else {
                throw ControllerError.invalidRequest("The request PID does not match its authenticated XPC connection.")
            }
            let result: MacScopeMCPJSONValue
            switch request.kind {
            case .state:
                guard let module = request.module else {
                    throw ControllerError.invalidRequest("A utility module is required.")
                }
                result = state(module: module, includeSensitive: request.arguments.optionalBool("include_sensitive") ?? false)
            case .run:
                guard let actionID = request.actionID,
                      MacScopeMCPUtilityCatalog.action(id: actionID) != nil else {
                    throw ControllerError.invalidRequest("The requested action is not in the MacScope utility allowlist.")
                }
                result = try run(actionID, arguments: request.arguments)
            }
            response = .init(requestID: request.id, result: result)
        } catch {
            let requestID = (try? MacScopeMCPUtilityTransport.decode(MacScopeMCPUtilityRequest.self, from: data).id) ?? UUID()
            response = .init(requestID: requestID, error: error.localizedDescription)
        }
        return (try? MacScopeMCPUtilityTransport.encode(response)) ?? Data()
    }

    func remoteRun(
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) throws -> MacScopeMCPJSONValue {
        guard MacScopeMCPUtilityCatalog.action(id: actionID) != nil else {
            throw ControllerError.invalidRequest("The requested action is not in the MacScope utility allowlist.")
        }
        return try run(actionID, arguments: arguments)
    }

    func remoteRunAwaitingCompletion(
        actionID: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) async throws -> MacScopeMCPJSONValue {
        guard MacScopeMCPUtilityCatalog.action(id: actionID) != nil else {
            throw ControllerError.invalidRequest("The requested action is not in the MacScope utility allowlist.")
        }
        if actionID == "capture.screenshot" {
            let mode: ScreenshotMode = switch try arguments.string("mode") {
            case "full_screen": .fullScreen
            case "window": .window
            case "selection": .selection
            default: throw ControllerError.invalidArgument("mode", "Use full_screen, window, or selection.")
            }
            let url = try await model.screenshots.captureAndWait(
                mode,
                copyToClipboard: arguments.optionalBool("copy_to_clipboard") ?? false,
                delay: min(max(arguments.optionalInt("delay_seconds") ?? 0, 0), 30)
            )
            return .object(["accepted": .bool(true), "artifact_name": .string(url.lastPathComponent)])
        }
        return try run(actionID, arguments: arguments)
    }

    func remoteState(
        module: MacScopeMCPUtilityModule,
        includeSensitive: Bool = false
    ) -> MacScopeMCPJSONValue {
        state(module: module, includeSensitive: includeSensitive)
    }

    private func run(
        _ action: String,
        arguments: [String: MacScopeMCPJSONValue]
    ) throws -> MacScopeMCPJSONValue {
        switch action {
        case "sound.refresh":
            model.audioMixer.start(); model.audioMixer.refresh()
        case "sound.set-system-volume":
            model.audioMixer.setSystemVolume(try arguments.number("value", range: 0...1))
        case "sound.toggle-system-mute":
            model.audioMixer.toggleSystemMute()
        case "sound.set-app-volume":
            let app = try audioApp(pid: arguments.int32("pid"))
            model.audioMixer.setVolume(try arguments.number("value", range: 0...2), for: app)
        case "sound.toggle-app-mute":
            model.audioMixer.toggleMute(try audioApp(pid: arguments.int32("pid")))
        case "sound.set-app-output":
            let app = try audioApp(pid: arguments.int32("pid"))
            let device = arguments.optionalString("device_uid").flatMap { uid in model.audioMixer.outputDevices.first { $0.uid == uid } }
            if arguments.optionalString("device_uid") != nil, device == nil { throw ControllerError.invalidArgument("device_uid", "Unknown output device UID.") }
            model.audioMixer.setOutputDevice(device, for: app)
        case "sound.select-output":
            let uid = try arguments.string("device_uid")
            guard let device = model.audioMixer.outputDevices.first(where: { $0.uid == uid }) else { throw ControllerError.invalidArgument("device_uid", "Unknown output device UID.") }
            model.audioMixer.selectOutput(device)
        case "sound.cycle-output":
            model.audioMixer.cycleOutput()
        case "sound.select-input":
            let uid = try arguments.string("device_uid")
            guard let device = model.audioMixer.inputDevices.first(where: { $0.uid == uid }) else { throw ControllerError.invalidArgument("device_uid", "Unknown input device UID.") }
            model.audioMixer.selectInput(device)
        case "sound.toggle-input-mute":
            model.audioMixer.toggleInputMute()
        case "sound.toggle-input-pin":
            model.audioMixer.toggleInputPin()
        case "sound.set-headphone-disconnect":
            if let volume = arguments.optionalNumber("volume") {
                guard (0...1).contains(volume) else { throw ControllerError.invalidArgument("volume", "Use a number from 0 through 1.") }
                model.audioMixer.disconnectVolume = volume
            }
            model.audioMixer.setLowersVolumeAfterHeadphoneDisconnect(try arguments.bool("enabled"))
        case "sound.set-music-blocker":
            model.musicBlocker.setEnabled(try arguments.bool("enabled"))

        case "capture.screenshot":
            let mode: ScreenshotMode = switch try arguments.string("mode") {
            case "full_screen": .fullScreen
            case "window": .window
            case "selection": .selection
            default: throw ControllerError.invalidArgument("mode", "Use full_screen, window, or selection.")
            }
            model.screenshots.capture(
                mode,
                copyToClipboard: arguments.optionalBool("copy_to_clipboard") ?? false,
                delay: min(max(arguments.optionalInt("delay_seconds") ?? 0, 0), 30)
            )
        case "capture.scrolling-screenshot":
            model.screenshots.captureAutomaticScrolling(
                steps: min(max(arguments.optionalInt("steps") ?? 6, 2), 20),
                overlapPixels: max(arguments.optionalInt("overlap_pixels") ?? 120, 0),
                copyToClipboard: arguments.optionalBool("copy_to_clipboard") ?? false
            )
        case "capture.recording-start":
            if let source = arguments.optionalString("source_id") { model.screenRecorder.selectedSourceID = source }
            if let value = arguments.optionalBool("system_audio") { model.screenRecorder.includesSystemAudio = value }
            if let value = arguments.optionalBool("microphone") { model.screenRecorder.includesMicrophone = value }
            model.screenRecorder.start()
        case "capture.recording-load-sources":
            model.screenRecorder.loadSources()
        case "capture.recording-pause-resume":
            model.screenRecorder.togglePause()
        case "capture.recording-stop":
            model.screenRecorder.stop()
        case "capture.ocr-selection":
            model.screenOCR.recognizeSelection()
        case "capture.color-picker":
            model.colorPicker.pick()
        case "capture.camera-start":
            if let id = arguments.optionalString("device_id") { model.cameraPreview.selectDevice(id) }
            model.cameraPreview.start()
        case "capture.camera-stop":
            model.cameraPreview.stop()

        case "windows.arrange":
            guard let placement = UtilitySupport.WindowPlacement(rawValue: try arguments.string("placement").camelCasePlacement) else {
                throw ControllerError.invalidArgument("placement", "Unknown window placement.")
            }
            model.workspace.arrange(placement)
        case "windows.restore":
            model.workspace.restorePreviousLayout()
        case "windows.move-display":
            let offset = arguments.optionalInt("offset") ?? 1
            guard offset == -1 || offset == 1 else { throw ControllerError.invalidArgument("offset", "Use -1 or 1.") }
            model.workspace.moveActiveWindowToAdjacentDisplay(offset: offset)
        case "windows.edge-snap":
            model.workspace.setEdgeSnapEnabled(try arguments.bool("enabled"))
        case "windows.modifier-drag":
            model.workspace.setModifierWindowDragEnabled(try arguments.bool("enabled"))
        case "windows.green-button-maximize":
            model.workspace.setGreenButtonOverrideEnabled(try arguments.bool("enabled"))
        case "windows.set-input-feature":
            try setInputFeature(try arguments.string("feature"), enabled: arguments.bool("enabled"))
        case "windows.set-keyboard-debounce":
            if let interval = arguments.optionalNumber("interval_ms") {
                guard (20...250).contains(interval) else { throw ControllerError.invalidArgument("interval_ms", "Use a number from 20 through 250.") }
                model.keyboardDebounce.intervalMilliseconds = interval
            }
            model.keyboardDebounce.setEnabled(try arguments.bool("enabled"))
        case "windows.set-scroll-direction":
            model.scrollDirection.invertVertical = try arguments.bool("vertical")
            model.scrollDirection.invertHorizontal = try arguments.bool("horizontal")
        case "windows.set-mouse-side-buttons":
            model.mouseSideButtons.setEnabled(try arguments.bool("enabled"))
        case "windows.set-focus-follows-mouse":
            if let delay = arguments.optionalNumber("delay_ms") {
                guard (100...1_000).contains(delay) else { throw ControllerError.invalidArgument("delay_ms", "Use a number from 100 through 1000.") }
                model.focusFollowsMouse.delayMilliseconds = delay
            }
            model.focusFollowsMouse.setEnabled(try arguments.bool("enabled"))
        case "windows.set-smooth-scrolling":
            if let intensity = arguments.optionalNumber("intensity") {
                guard (0.5...2).contains(intensity) else { throw ControllerError.invalidArgument("intensity", "Use a number from 0.5 through 2.") }
                model.smoothScrolling.intensity = intensity
            }
            model.smoothScrolling.setEnabled(try arguments.bool("enabled"))
        case "windows.activate-app":
            model.workspace.activate(try workspaceApp(pid: arguments.int32("pid")))
        case "windows.launch-app":
            guard model.workspace.launch(bundleIdentifier: try arguments.string("bundle_identifier")) else {
                throw ControllerError.invalidArgument("bundle_identifier", "Choose an application returned by current windows state.")
            }
        case "windows.quit-app":
            let item = try workspaceApp(pid: arguments.int32("pid"))
            let expectedBundleIdentifier = try arguments.string("expected_bundle_identifier")
            guard item.bundleIdentifier == expectedBundleIdentifier else {
                throw ControllerError.invalidArgument("expected_bundle_identifier", "The running application changed before the quit request was applied.")
            }
            guard item.bundleIdentifier != "com.apple.finder" else {
                throw ControllerError.invalidRequest("Finder is a protected system application and cannot be quit remotely.")
            }
            guard model.workspace.quit(item) else {
                throw ControllerError.invalidRequest("The application did not accept the quit request.")
            }
        case "windows.toggle-hidden-app":
            model.workspace.toggleHidden(try workspaceApp(pid: arguments.int32("pid")))
        case "windows.set-quit-on-close":
            model.workspace.setQuitOnClose(try arguments.bool("enabled"), for: try workspaceApp(pid: arguments.int32("pid")))

        case "clipboard.set-monitoring":
            model.clipboard.setEnabled(try arguments.bool("enabled"))
        case "clipboard.clear":
            model.clipboard.clear()
        case "clipboard.add-snippet":
            model.snippetShelf.saveSnippet(
                title: try arguments.string("title"),
                text: try arguments.string("text"),
                trigger: arguments.optionalString("trigger"),
                folder: arguments.optionalString("folder")
            )
        case "clipboard.add-shelf-files":
            model.snippetShelf.addShelfItems(try existingURLs(arguments.stringArray("paths")))
        case "clipboard.move-shelf-files":
            let destination = URL(fileURLWithPath: try arguments.string("destination"), isDirectory: true).standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue else {
                throw ControllerError.invalidArgument("destination", "The destination must be an existing directory.")
            }
            model.snippetShelf.moveShelfItems(to: destination)
        case "clipboard.add-shelf-text":
            model.snippetShelf.addShelfText(try arguments.string("text"))
        case "clipboard.clean-url":
            model.clipboard.cleanCurrentURL()
        case "clipboard.set-automatic-url-cleaning":
            model.clipboard.setAutomaticallyCleansURLs(try arguments.bool("enabled"))
        case "clipboard.schedule-clear":
            model.clipboard.scheduleClipboardClear(after: arguments.optionalNumber("seconds"))
        case "clipboard.set-clear-events":
            model.clipboard.setClearOnSystemSleep(try arguments.bool("system_sleep"))
            model.clipboard.setClearOnDisplaySleep(try arguments.bool("display_sleep"))
            model.clipboard.setClearOnScreenLock(try arguments.bool("screen_lock"))
        case "clipboard.set-text-expansion":
            model.snippetShelf.setExpansionEnabled(try arguments.bool("enabled"))
        case "clipboard.delete-snippet":
            let id = try arguments.uuid("id")
            guard let snippet = model.snippetShelf.snippets.first(where: { $0.id == id }) else { throw ControllerError.invalidArgument("id", "Unknown snippet.") }
            model.snippetShelf.delete(snippet)
        case "clipboard.remove-shelf-file":
            let path = try arguments.string("path")
            guard let item = model.snippetShelf.shelfItems.first(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }) else { throw ControllerError.invalidArgument("path", "Unknown shelf file.") }
            model.snippetShelf.remove(item)
        case "clipboard.remove-shelf-text":
            let id = try arguments.uuid("id")
            guard let item = model.snippetShelf.shelfTextItems.first(where: { $0.id == id }) else { throw ControllerError.invalidArgument("id", "Unknown shelf text item.") }
            model.snippetShelf.remove(item)

        case "notes.create":
            let id = model.scratchpad.addTab()
            if let name = arguments.optionalString("name") { model.scratchpad.rename(id, to: name) }
            if let value = arguments.optionalString("text") { model.scratchpad.updateText(id, text: value) }
            return .object(["accepted": .bool(true), "id": .string(id.uuidString.lowercased())])
        case "notes.update":
            model.scratchpad.updateText(try arguments.uuid("id"), text: try arguments.string("text"))
        case "notes.rename":
            model.scratchpad.rename(try arguments.uuid("id"), to: try arguments.string("name"))
        case "notes.clear":
            model.scratchpad.clear(try arguments.uuid("id"))
        case "notes.delete":
            model.scratchpad.delete(try arguments.uuid("id"))
        case "notes.set-auto-clear":
            model.scratchpad.setAutoClear(after: arguments.optionalNumber("seconds"))

        case "maintenance.scan-applications":
            model.maintenance.scanApplications()
        case "maintenance.scan-downloads":
            model.maintenance.scanDownloads()
        case "maintenance.scan-cleanup":
            model.maintenance.scanCleanupCandidates()
        case "maintenance.check-updates":
            model.maintenance.checkApplicationUpdates()
        case "maintenance.check-homebrew":
            model.maintenance.checkHomebrew()
        case "maintenance.search-homebrew":
            model.maintenance.searchHomebrew(try arguments.string("query"))
        case "maintenance.move-to-trash":
            let requested = try existingURLs(arguments.stringArray("paths"))
            let allowed = Set(maintenanceCandidateURLs().map { $0.standardizedFileURL.path })
            guard requested.allSatisfy({ allowed.contains($0.standardizedFileURL.path) }) else {
                throw ControllerError.invalidArgument("paths", "Every path must be a current maintenance candidate returned by utility state.")
            }
            model.maintenance.moveToTrash(requested)
        case "maintenance.scan-messaging-downloads":
            model.maintenance.scanMessagingDownloads()
        case "maintenance.set-cleanup-schedule":
            model.maintenance.setCleanupSchedule(hours: arguments.optionalNumber("hours"))
        case "maintenance.set-update-settings":
            model.maintenance.setBackgroundUpdateChecksEnabled(try arguments.bool("background"))
            model.maintenance.setAppCatalogUpdateSourceEnabled(try arguments.bool("app_store"))
            model.maintenance.setHomebrewUpdateSourceEnabled(try arguments.bool("homebrew"))
        case "maintenance.upgrade-homebrew":
            let id = try arguments.string("id")
            guard let item = model.maintenance.outdatedPackages.first(where: { $0.id == id }) else { throw ControllerError.invalidArgument("id", "Unknown outdated Homebrew item.") }
            model.maintenance.upgrade(item)
        case "maintenance.set-homebrew-installed":
            let id = try arguments.string("id")
            guard let item = model.maintenance.homebrewSearchResults.first(where: { $0.id == id }) else { throw ControllerError.invalidArgument("id", "Unknown Homebrew search item.") }
            model.maintenance.setHomebrewInstalled(try arguments.bool("installed"), item: item)
        case "maintenance.process-terminate":
            let rawStartedAt = try arguments.string("expected_start_time")
            guard let startedAt = ISO8601DateFormatter().date(from: rawStartedAt) else {
                throw ControllerError.invalidArgument("expected_start_time", "Use the exact process start timestamp returned by live process data.")
            }
            let result = try ProcessController.executeSynchronously(.init(kind: .terminate, pid: try arguments.int32("pid"), expectedStartTime: startedAt))
            return try MacScopeMCPJSONValue.encode(result)
        case "maintenance.media-load-images":
            model.media.loadImages(try existingURLs(arguments.stringArray("paths")))
        case "maintenance.media-convert-images":
            let format: MediaExportFormat = switch try arguments.string("format") { case "png": .png; case "jpeg": .jpeg; default: throw ControllerError.invalidArgument("format", "Use png or jpeg.") }
            model.media.convert(format: format, quality: try arguments.number("quality", range: 0.1...1), maximumDimension: arguments.optionalNumber("maximum_dimension"), watermark: arguments.optionalString("watermark"))
        case "maintenance.media-extract-text":
            model.media.extractText()
        case "maintenance.media-create-gif":
            model.media.createAnimatedGIF(frameDuration: try arguments.number("frame_duration", range: 0.04...10))
        case "maintenance.media-load-video":
            model.media.loadVideo(try existingURLs([arguments.string("path")]).first!)
        case "maintenance.media-compress-video":
            model.media.compressVideo()
        case "maintenance.media-trim-video":
            model.media.trimVideo(start: arguments.optionalNumber("start") ?? 0, end: try arguments.requiredNumber("end"))
        case "maintenance.media-cut-video":
            model.media.cutVideo(start: arguments.optionalNumber("start") ?? 0, end: try arguments.requiredNumber("end"))
        case "maintenance.media-crop-video":
            model.media.cropVideo(left: arguments.optionalNumber("left") ?? 0, right: arguments.optionalNumber("right") ?? 0, top: arguments.optionalNumber("top") ?? 0, bottom: arguments.optionalNumber("bottom") ?? 0)
        case "maintenance.media-export-video-gif":
            model.media.exportVideoGIF(framesPerSecond: min(max(arguments.optionalInt("fps") ?? 12, 2), 24))

        case "power.keep-awake-start":
            model.keepAwake.start(
                duration: arguments.optionalNumber("duration_seconds"),
                includesDisplay: arguments.optionalBool("include_display") ?? false
            )
        case "power.keep-awake-stop":
            model.keepAwake.stop()
        case "power.set-keep-awake-automations":
            model.keepAwake.setStartsOnACPower(try arguments.bool("on_ac_power"))
            model.keepAwake.setStartsWithExternalDisplay(try arguments.bool("with_external_display"))
        case "power.cleaning-mode-start":
            model.cleaningMode.start(duration: min(max(arguments.optionalNumber("duration_seconds") ?? 30, 10), 300))
        case "power.cleaning-mode-stop":
            model.cleaningMode.stop()
        case "power.set-display-brightness":
            let id = try arguments.uint32("display_id")
            guard let display = model.displayControl.displays.first(where: { $0.id == id }) else {
                throw ControllerError.invalidArgument("display_id", "Unknown hardware display.")
            }
            model.displayControl.setBrightness(try arguments.number("value", range: 0...1), for: display)
        case "power.set-software-dimming":
            let id = try arguments.uint32("display_id")
            guard let display = model.displayControl.softwareDisplays.first(where: { $0.id == id }) else {
                throw ControllerError.invalidArgument("display_id", "Unknown software display.")
            }
            model.displayControl.setSoftwareLevel(try arguments.number("value", range: 0...1), for: display)
        case "power.restore-software-dimming":
            model.displayControl.restoreSoftwareDimming()
        default:
            throw ControllerError.invalidRequest("The action is catalogued but has no app executor.")
        }
        return .object(["accepted": .bool(true), "action": .string(action)])
    }

    private func state(module: MacScopeMCPUtilityModule, includeSensitive: Bool) -> MacScopeMCPJSONValue {
        let value: MacScopeMCPJSONValue
        switch module {
        case .sound:
            model.audioMixer.start(); model.audioMixer.refresh()
            value = .object([
                "running": .bool(model.audioMixer.isRunning),
                "system_volume": model.audioMixer.systemVolume.json,
                "system_muted": model.audioMixer.systemMuted.json,
                "input_muted": model.audioMixer.inputMuted.json,
                "needs_system_audio_permission": .bool(model.audioMixer.needsSystemAudioPermission),
                "error": model.audioMixer.errorMessage.json,
                "outputs": .array(model.audioMixer.outputDevices.map { .object(["id": .integer(Int64($0.id)), "uid": .string($0.uid), "name": .string($0.name), "default": .bool($0.isDefault)]) }),
                "inputs": .array(model.audioMixer.inputDevices.map { .object(["id": .integer(Int64($0.id)), "uid": .string($0.uid), "name": .string($0.name), "default": .bool($0.isDefault)]) }),
                "applications": .array(model.audioMixer.apps.map { .object(["pid": .integer(Int64($0.pid)), "name": .string($0.name), "bundle_identifier": $0.bundleIdentifier.json, "playing": .bool($0.isPlaying), "volume": .number($0.volume), "output_device_uid": $0.outputDeviceUID.json]) })
            ])
        case .capture:
            value = .object([
                "screen_recording_permission": .bool(model.screenshots.hasScreenRecordingPermission),
                "screenshot": .object(["capturing": .bool(model.screenshots.isCapturing), "stitching": .bool(model.screenshots.isStitching), "status": model.screenshots.statusMessage.json, "error": model.screenshots.errorMessage.json, "captures": .array(model.screenshots.captures.map { .object(["name": .string($0.url.lastPathComponent), "path": includeSensitive ? .string($0.url.path) : .null, "created_at": .string($0.createdAt.ISO8601Format())]) })]),
                "recording": .object(["recording": .bool(model.screenRecorder.isRecording), "paused": .bool(model.screenRecorder.isPaused), "preparing": .bool(model.screenRecorder.isPreparing), "elapsed_seconds": .number(model.screenRecorder.elapsed), "last_path": includeSensitive ? model.screenRecorder.lastRecordingURL.map(\.path).json : .null, "error": model.screenRecorder.errorMessage.json, "sources": .array(model.screenRecorder.sources.map { .object(["id": .string($0.id), "name": .string($0.name)]) })]),
                "ocr": .object(["recognizing": .bool(model.screenOCR.isRecognizing), "text": includeSensitive ? .string(model.screenOCR.recognizedText) : .null, "codes": includeSensitive ? .array(model.screenOCR.recognizedCodes.map(MacScopeMCPJSONValue.string)) : .array([]), "error": model.screenOCR.errorMessage.json]),
                "color": .object(["hex": model.colorPicker.hex.json, "rgb": model.colorPicker.rgb.json, "hsl": model.colorPicker.hsl.json, "swiftui": model.colorPicker.swiftUI.json]),
                "camera": .object(["running": .bool(model.cameraPreview.isRunning), "selected_device_id": model.cameraPreview.selectedDeviceID.json, "error": model.cameraPreview.errorMessage.json, "devices": .array(model.cameraPreview.devices.map { .object(["id": .string($0.id), "name": .string($0.name)]) })])
            ])
        case .windows:
            model.workspace.refresh()
            model.workspace.refreshInstalledApplications()
            value = .object([
                "accessibility_trusted": .bool(model.workspace.accessibilityTrusted), "frontmost_application": .string(model.workspace.frontmostApplication),
                "edge_snap_enabled": .bool(model.workspace.edgeSnapEnabled), "modifier_drag_enabled": .bool(model.workspace.modifierWindowDragEnabled), "green_button_override_enabled": .bool(model.workspace.greenButtonOverrideEnabled),
                "input_features": .object(["keyboard_debounce": .bool(model.keyboardDebounce.isEnabled), "focus_follows_mouse": .bool(model.focusFollowsMouse.isEnabled), "super_key": .bool(model.superKey.isEnabled), "smooth_scrolling": .bool(model.smoothScrolling.isEnabled), "plain_text_paste": .bool(model.plainTextPaste.isEnabled), "finder_shortcuts": .bool(model.finderShortcuts.isEnabled)])
                , "applications": .array(model.workspace.applications.map { .object(["pid": .integer(Int64($0.id)), "name": .string($0.name), "bundle_identifier": $0.bundleIdentifier.json, "active": .bool($0.isActive), "hidden": .bool($0.isHidden), "quit_on_close": .bool(model.workspace.quitsOnClose($0))]) })
                , "installed_applications": .array(model.workspace.installedApplications.map { .object(["bundle_identifier": .string($0.bundleIdentifier), "name": .string($0.name)]) })
            ])
        case .clipboard:
            let clipboardImages = Dictionary(uniqueKeysWithValues: (model.clipboard.pinnedEntries + model.clipboard.entries).compactMap { entry -> (String, Data)? in
                guard let source = entry.imageData,
                      let bitmap = NSBitmapImageRep(data: source),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
                return (entry.id.uuidString.lowercased(), png)
            })
            try? MacScopeMCPArtifactStore.replaceClipboardImages(clipboardImages)
            let history: [MacScopeMCPJSONValue] = (model.clipboard.pinnedEntries + model.clipboard.entries).map { entry in
                let kind = !entry.text.isEmpty ? "text" : (!entry.fileURLs.isEmpty ? "files" : "image")
                return .object([
                    "id": .string(entry.id.uuidString.lowercased()),
                    "kind": .string(kind),
                    "text": includeSensitive ? .string(entry.text) : .null,
                    "files": includeSensitive ? .array(entry.fileURLs.map { .string($0.path) }) : .array([]),
                    "has_image": .bool(entry.imageData != nil),
                    "captured_at": .string(entry.capturedAt.ISO8601Format())
                ])
            }
            let snippets: [MacScopeMCPJSONValue] = model.snippetShelf.snippets.map { snippet in
                .object(["id": .string(snippet.id.uuidString.lowercased()), "title": .string(snippet.title), "text": includeSensitive ? .string(snippet.text) : .null, "trigger": includeSensitive ? snippet.trigger.json : .null, "folder": snippet.folder.json])
            }
            let shelfFiles: [MacScopeMCPJSONValue] = model.snippetShelf.shelfItems.map { item in
                .object(["name": .string(item.url.lastPathComponent), "path": includeSensitive ? .string(item.url.path) : .null])
            }
            let shelfText: [MacScopeMCPJSONValue] = model.snippetShelf.shelfTextItems.map { item in
                .object(["id": .string(item.id.uuidString.lowercased()), "text": includeSensitive ? .string(item.text) : .null])
            }
            value = .object([
                "monitoring": .bool(model.clipboard.isEnabled), "history_count": .integer(Int64(model.clipboard.entries.count)), "pinned_count": .integer(Int64(model.clipboard.pinnedEntries.count)), "status": model.clipboard.statusMessage.json,
                "history": .array(history), "snippets": .array(snippets), "shelf_files": .array(shelfFiles), "shelf_text": .array(shelfText)
            ])
        case .notes:
            value = .object(["auto_clear_seconds": model.scratchpad.autoClearInterval.json, "status": model.scratchpad.statusMessage.json, "pads": .array(model.scratchpad.tabs.map { .object(["id": .string($0.id.uuidString.lowercased()), "name": .string($0.name), "text": includeSensitive ? .string($0.text) : .null]) })])
        case .maintenance:
            value = .object([
                "busy": model.maintenance.activeOperation.json, "status": model.maintenance.statusMessage.json,
                "applications": .integer(Int64(model.maintenance.applications.count)), "updates": .integer(Int64(model.maintenance.applicationUpdates.count)),
                "large_downloads": .array(model.maintenance.largeDownloads.map { .object(["name": .string($0.url.lastPathComponent), "path": .string($0.url.path), "bytes": .integer($0.size)]) }),
                "cleanup_candidates": .array(model.maintenance.cleanupCandidates.map { .object(["name": .string($0.url.lastPathComponent), "path": .string($0.url.path), "bytes": .integer($0.size)]) }),
                "homebrew_outdated": .array(model.maintenance.outdatedPackages.map { .object(["id": .string($0.id), "name": .string($0.name), "installed": .string($0.installed), "current": .string($0.current), "cask": .bool($0.isCask)]) }),
                "homebrew_search": .array(model.maintenance.homebrewSearchResults.map { .object(["id": .string($0.id), "name": .string($0.name), "cask": .bool($0.isCask), "installed": .bool($0.isInstalled)]) })
                , "media": .object(["image_sources": .array(model.media.sourceURLs.map { includeSensitive ? .string($0.path) : .string($0.lastPathComponent) }), "outputs": .array(model.media.outputURLs.map { includeSensitive ? .string($0.path) : .string($0.lastPathComponent) }), "extracted_text": includeSensitive ? .string(model.media.extractedText) : .null, "video_source": includeSensitive ? model.media.videoSourceURL.map(\.path).json : .null, "video_output": includeSensitive ? model.media.videoOutputURL.map(\.path).json : .null, "status": model.media.statusMessage.json])
            ])
        case .power:
            model.displayControl.refresh()
            value = .object([
                "keep_awake": .object(["active": .bool(model.keepAwake.isActive), "includes_display": .bool(model.keepAwake.includesDisplay), "ends_at": model.keepAwake.endsAt.map { $0.ISO8601Format() }.json, "error": model.keepAwake.errorMessage.json]),
                "cleaning_mode": .object(["active": .bool(model.cleaningMode.isActive), "ends_at": model.cleaningMode.endsAt.map { $0.ISO8601Format() }.json, "error": model.cleaningMode.errorMessage.json]),
                "hardware_displays": .array(model.displayControl.displays.map { .object(["id": .integer(Int64($0.id)), "name": .string($0.name), "brightness": $0.brightness.json]) }),
                "software_displays": .array(model.displayControl.softwareDisplays.map { .object(["id": .integer(Int64($0.id)), "name": .string($0.name), "level": .number($0.level)]) })
            ])
        }
        return includeSensitive ? value : value.redactingSensitiveFields()
    }

    private func audioApp(pid: Int32) throws -> AudioMixerApp {
        model.audioMixer.start(); model.audioMixer.refresh()
        guard let app = model.audioMixer.apps.first(where: { $0.pid == pid }) else {
            throw ControllerError.invalidArgument("pid", "The PID is not in the current audio application list.")
        }
        return app
    }

    private func workspaceApp(pid: Int32) throws -> WorkspaceApplication {
        model.workspace.refresh()
        guard let app = model.workspace.applications.first(where: { $0.id == pid }) else {
            throw ControllerError.invalidArgument("pid", "The PID is not in the current workspace application list.")
        }
        return app
    }

    private func setInputFeature(_ feature: String, enabled: Bool) throws {
        switch feature {
        case "keyboard_debounce": model.keyboardDebounce.setEnabled(enabled)
        case "focus_follows_mouse": model.focusFollowsMouse.setEnabled(enabled)
        case "super_key": model.superKey.setEnabled(enabled)
        case "smooth_scrolling": model.smoothScrolling.setEnabled(enabled)
        case "plain_text_paste": model.plainTextPaste.setEnabled(enabled)
        case "finder_shortcuts": model.finderShortcuts.setEnabled(enabled)
        default: throw ControllerError.invalidArgument("feature", "Unknown input feature.")
        }
    }

    private func existingURLs(_ paths: [String]) throws -> [URL] {
        guard !paths.isEmpty else { throw ControllerError.invalidArgument("paths", "At least one path is required.") }
        return try paths.map {
            let url = URL(fileURLWithPath: $0).standardizedFileURL
            guard url.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path) else {
                throw ControllerError.invalidArgument("paths", "Every path must be absolute and exist.")
            }
            return url
        }
    }

    private func maintenanceCandidateURLs() -> [URL] {
        model.maintenance.largeDownloads.map(\.url)
            + model.maintenance.messagingDownloads.map(\.url)
            + model.maintenance.cleanupCandidates.map(\.url)
            + model.maintenance.applications.map(\.url)
    }
}

private enum ControllerError: LocalizedError {
    case invalidRequest(String)
    case invalidArgument(String, String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidArgument(let name, let message): "Invalid \(name): \(message)"
        }
    }
}

private final class MCPUtilitySocketServer: @unchecked Sendable {
    private weak var controller: MacScopeMCPUtilityController?
    private let queue = DispatchQueue(label: "local.taskmanager.MacScope.mcp-utility", qos: .userInitiated)
    private var listenerFD: Int32 = -1
    private var socketPath = ""

    init(controller: MacScopeMCPUtilityController) {
        self.controller = controller
    }

    func start() throws {
        let path = try MacScopeMCPUtilityTransport.socketURL().path
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControllerError.invalidRequest("The MCP utility socket path is too long.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(min(Int(length), Int(UInt8.max)))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
        }
        Darwin.unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length)
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            Darwin.close(fd)
            Darwin.unlink(path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        listenerFD = fd
        socketPath = path
        queue.async { [weak self] in self?.acceptLoop() }
    }

    deinit {
        if listenerFD >= 0 { Darwin.close(listenerFD) }
        if !socketPath.isEmpty { Darwin.unlink(socketPath) }
    }

    private func acceptLoop() {
        while listenerFD >= 0 {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              MCPServerCodeValidator.isAllowed(pid: pid),
              let header = Self.readExactly(client, count: 4) else {
            Darwin.close(client)
            return
        }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0,
              count <= UInt32(MacScopeMCPUtilityTransport.maximumMessageBytes),
              let request = Self.readExactly(client, count: Int(count)) else {
            Darwin.close(client)
            return
        }
        Task { @MainActor [weak controller] in
            guard let controller else { Darwin.close(client); return }
            let response = controller.handle(request, connectionPID: pid)
            Self.writeMessage(response, to: client)
            Darwin.close(client)
        }
    }

    private static func readExactly(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            while offset < count {
                let amount = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if amount <= 0 { return -1 }
                offset += amount
            }
            return offset
        }
        return readCount == count ? data : nil
    }

    private static func writeMessage(_ data: Data, to fd: Int32) {
        let count = UInt32(data.count)
        let header = Data([
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff)
        ])
        writeAll(header, to: fd)
        writeAll(data, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if amount <= 0 { return }
                offset += amount
            }
        }
    }
}

private enum MCPServerCodeValidator {
    static func isAllowed(pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let url = path as URL? else { return false }
        let appURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let expected = appURL.appendingPathComponent("Contents/Resources/MacScopeMCPServer")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.standardizedFileURL.resolvingSymlinksInPath() == expected else { return false }
        var appCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode) == errSecSuccess,
              let appCode,
              SecStaticCodeCheckValidity(
                appCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                nil
              ) == errSecSuccess else { return false }
        return true
    }
}

private extension Dictionary where Key == String, Value == MacScopeMCPJSONValue {
    func string(_ key: String) throws -> String {
        guard case .string(let value) = self[key], !value.isEmpty else { throw ControllerError.invalidArgument(key, "A non-empty string is required.") }
        return value
    }
    func optionalString(_ key: String) -> String? { guard case .string(let value) = self[key] else { return nil }; return value }
    func bool(_ key: String) throws -> Bool { guard case .bool(let value) = self[key] else { throw ControllerError.invalidArgument(key, "A Boolean is required.") }; return value }
    func optionalBool(_ key: String) -> Bool? { guard case .bool(let value) = self[key] else { return nil }; return value }
    func optionalInt(_ key: String) -> Int? { if case .integer(let value) = self[key] { return Int(exactly: value) }; return nil }
    func optionalNumber(_ key: String) -> Double? { switch self[key] { case .number(let value): value; case .integer(let value): Double(value); default: nil } }
    func number(_ key: String, range: ClosedRange<Double>) throws -> Double { guard let value = optionalNumber(key), range.contains(value) else { throw ControllerError.invalidArgument(key, "Use a number from \(range.lowerBound) through \(range.upperBound).") }; return value }
    func requiredNumber(_ key: String) throws -> Double { guard let value = optionalNumber(key) else { throw ControllerError.invalidArgument(key, "A number is required.") }; return value }
    func int32(_ key: String) throws -> Int32 { guard let value = optionalInt(key), let result = Int32(exactly: value) else { throw ControllerError.invalidArgument(key, "A 32-bit integer is required.") }; return result }
    func uint32(_ key: String) throws -> UInt32 { guard let value = optionalInt(key), let result = UInt32(exactly: value) else { throw ControllerError.invalidArgument(key, "A non-negative 32-bit integer is required.") }; return result }
    func uuid(_ key: String) throws -> UUID { guard let result = UUID(uuidString: try string(key)) else { throw ControllerError.invalidArgument(key, "A UUID is required.") }; return result }
    func stringArray(_ key: String) throws -> [String] { guard case .array(let values) = self[key] else { throw ControllerError.invalidArgument(key, "An array of strings is required.") }; return try values.map { guard case .string(let value) = $0 else { throw ControllerError.invalidArgument(key, "Every item must be a string.") }; return value } }
}

private extension Optional where Wrapped == String {
    var json: MacScopeMCPJSONValue { map(MacScopeMCPJSONValue.string) ?? .null }
}
private extension Optional where Wrapped == Double {
    var json: MacScopeMCPJSONValue { map(MacScopeMCPJSONValue.number) ?? .null }
}
private extension Optional where Wrapped == Bool {
    var json: MacScopeMCPJSONValue { map(MacScopeMCPJSONValue.bool) ?? .null }
}
private extension String {
    var camelCasePlacement: String {
        let pieces = split(separator: "_")
        return pieces.enumerated().map { index, piece in index == 0 ? piece.lowercased() : piece.prefix(1).uppercased() + piece.dropFirst().lowercased() }.joined()
    }
}
