import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MacScopeCore
import Observation
import ScreenCaptureKit
import Vision

enum ScreenImageAnalyzer {
    static func detectQRCodes(at url: URL) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(url: url)
            try handler.perform([request])
            return Array(Set((request.results ?? []).compactMap(\.payloadStringValue))).sorted()
        }.value
    }
}

@MainActor
@Observable
final class ColorPickerService {
    private(set) var color: NSColor?
    private(set) var statusMessage: String?

    var hex: String? {
        guard let components else { return nil }
        return UtilitySupport.colorStrings(
            red: components.red, green: components.green, blue: components.blue
        ).hex
    }

    var rgb: String? {
        guard let components else { return nil }
        return UtilitySupport.colorStrings(
            red: components.red, green: components.green, blue: components.blue
        ).rgb
    }

    var swiftUI: String? {
        guard let components else { return nil }
        return UtilitySupport.colorStrings(
            red: components.red, green: components.green, blue: components.blue
        ).swiftUI
    }

    var hsl: String? {
        guard let components else { return nil }
        return UtilitySupport.colorStrings(
            red: components.red, green: components.green, blue: components.blue
        ).hsl
    }

    func pick() {
        NSColorSampler().show { [weak self] picked in
            Task { @MainActor in
                guard let picked else {
                    self?.statusMessage = "Color picking cancelled."
                    return
                }
                self?.color = picked.usingColorSpace(.sRGB) ?? picked
                self?.statusMessage = "Color sampled."
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = "Copied \(value)"
    }

    private var components: (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
    }
}

@MainActor
@Observable
final class ScreenOCRService {
    private(set) var recognizedText = ""
    private(set) var recognizedCodes: [String] = []
    private(set) var isRecognizing = false
    private(set) var errorMessage: String?

    func recognizeSelection() {
        guard !isRecognizing else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen Recording permission is required for screen text recognition."
            return
        }

        isRecognizing = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MacScope OCR", isDirectory: true)
                    let imageURL = try ScreenshotService.performCapture(mode: .selection, folder: folder)
                    defer { try? FileManager.default.removeItem(at: imageURL) }

                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    let barcodeRequest = VNDetectBarcodesRequest()
                    barcodeRequest.symbologies = [.qr]
                    let handler = VNImageRequestHandler(url: imageURL)
                    try handler.perform([request, barcodeRequest])
                    let text = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    let codes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
                    return (text, codes)
                }.value
                recognizedText = result.0
                recognizedCodes = result.1
                if result.0.isEmpty, result.1.isEmpty {
                    errorMessage = "No text or QR code was found in the selected area."
                }
            } catch let error as ScreenshotFailure {
                if error.message != "cancelled" { errorMessage = error.message }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRecognizing = false
        }
    }

    func copyText() {
        guard !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
    }

    func copyCode(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openCode(_ value: String) {
        guard let url = URL(string: value),
              url.scheme == "http" || url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
@Observable
final class CameraPreviewService {
    struct CameraDeviceItem: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var devices: [CameraDeviceItem] = []
    var selectedDeviceID: String?
    let session = AVCaptureSession()
    private let sessionBox: CameraSessionBox
    private var previewPanel: NSPanel?
    private var panelResignObserver: NSObjectProtocol?
    private var panelCloseObserver: NSObjectProtocol?

    init() {
        sessionBox = CameraSessionBox(session: session)
        refreshDevices()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices.map { CameraDeviceItem(id: $0.uniqueID, name: $0.localizedName) }
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }
    }

    func selectDevice(_ id: String) {
        guard selectedDeviceID != id else { return }
        selectedDeviceID = id
        if isRunning {
            stop()
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        Task {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                granted = true
            case .notDetermined:
                granted = await AVCaptureDevice.requestAccess(for: .video)
            default:
                granted = false
            }
            guard granted else {
                errorMessage = "Camera access is disabled for MacScope in System Settings › Privacy & Security › Camera."
                return
            }

            let deviceID = selectedDeviceID
            let result = await Task.detached(priority: .userInitiated) { [sessionBox] in
                sessionBox.configureAndStart(deviceID: deviceID)
            }.value
            if let result { errorMessage = result }
            else {
                isRunning = true
                showFloatingPreview()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        previewPanel?.orderOut(nil)
        Task.detached(priority: .utility) { [sessionBox] in sessionBox.stop() }
    }

    private func showFloatingPreview() {
        let panel: NSPanel
        if let previewPanel {
            panel = previewPanel
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Camera Preview"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 360, height: 240)
            panel.contentView = FloatingCameraPreviewView(session: session)
            panel.center()
            previewPanel = panel

            panelResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            panelCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class FloatingCameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private final class CameraSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    private var configuredDeviceID: String?

    init(session: AVCaptureSession) {
        self.session = session
    }

    func configureAndStart(deviceID: String?) -> String? {
        if configuredDeviceID != deviceID {
            let camera = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
                ?? AVCaptureDevice.default(for: .video)
            guard let camera else {
                return "No camera is available."
            }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                session.beginConfiguration()
                session.sessionPreset = .high
                session.inputs.forEach { session.removeInput($0) }
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    return "The selected camera cannot be added to the preview session."
                }
                session.addInput(input)
                session.commitConfiguration()
                configuredDeviceID = camera.uniqueID
            } catch {
                return error.localizedDescription
            }
        }
        session.startRunning()
        return session.isRunning ? nil : "The camera preview did not start."
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }
}

@MainActor
@Observable
final class ScreenRecordingService {
    struct PointerEvent: Codable, Equatable, Sendable {
        let time: TimeInterval
        let normalizedX: Double
        let normalizedY: Double
    }
    enum Target: Hashable, Sendable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    struct Source: Identifiable, Hashable, Sendable {
        let target: Target
        let name: String
        var id: String {
            switch target {
            case .display(let id): "display:\(id)"
            case .window(let id): "window:\(id)"
            }
        }
    }

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var isPreparing = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastRecordingURL: URL?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var sources: [Source] = []
    private(set) var isLoadingSources = false
    private(set) var pointerEvents: [PointerEvent] = []
    var selectedSourceID: String?
    var includesSystemAudio = true
    var includesMicrophone = false

    private var engine: ScreenRecorderEngine?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pointerMonitor: Any?
    private var recordingBounds: CGRect?

    var recordingsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacScope Recordings", isDirectory: true)
    }

    var selectedSourceName: String {
        sources.first(where: { $0.id == selectedSourceID })?.name ?? "Primary display"
    }

    func loadSources() {
        guard !isLoadingSources else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen Recording permission is required to list displays and windows."
            return
        }
        isLoadingSources = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                var loaded = content.displays.enumerated().map { index, display in
                    Source(target: .display(display.displayID), name: "Display \(index + 1) · \(display.width)×\(display.height)")
                }
                let ownBundle = Bundle.main.bundleIdentifier
                loaded += content.windows.compactMap { window in
                    guard window.frame.width >= 160, window.frame.height >= 100,
                          window.owningApplication?.bundleIdentifier != ownBundle else { return nil }
                    let app = window.owningApplication?.applicationName ?? "Application"
                    let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Source(
                        target: .window(window.windowID),
                        name: "\(app) — \(title?.isEmpty == false ? title! : "Window")"
                    )
                }
                sources = loaded
                if selectedSourceID == nil || !loaded.contains(where: { $0.id == selectedSourceID }) {
                    selectedSourceID = loaded.first?.id
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingSources = false
        }
    }

    func start() {
        guard !isRecording, !isPreparing else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen Recording permission is required before recording can start."
            return
        }

        isPreparing = true
        errorMessage = nil
        let destination = recordingsFolder.appendingPathComponent(Self.filename())
        let recorder = ScreenRecorderEngine(
            destination: destination,
            includesSystemAudio: includesSystemAudio,
            includesMicrophone: includesMicrophone,
            target: sources.first(where: { $0.id == selectedSourceID })?.target
        ) { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
                if self?.isRecording == true { self?.stop() }
            }
        }

        Task {
            do {
                if includesMicrophone {
                    let microphoneGranted: Bool
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        microphoneGranted = true
                    case .notDetermined:
                        microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
                    default:
                        microphoneGranted = false
                    }
                    guard microphoneGranted else {
                        throw NSError(
                            domain: "MacScope.ScreenRecorder", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Microphone access is disabled for MacScope in System Settings › Privacy & Security › Microphone."]
                        )
                    }
                }
                try FileManager.default.createDirectory(
                    at: recordingsFolder, withIntermediateDirectories: true
                )
                try await recorder.start()
                engine = recorder
                isRecording = true
                isPaused = false
                startedAt = Date()
                pausedAt = nil
                pausedDuration = 0
                elapsed = 0
                pointerEvents = []
                recordingBounds = Self.bounds(for: recorder.target)
                pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    Task { @MainActor in self?.recordPointerClick(event) }
                }
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let startedAt = self.startedAt else { return }
                        let activePause = self.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
                        self.elapsed = max(Date().timeIntervalSince(startedAt) - self.pausedDuration - activePause, 0)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparing = false
        }
    }

    func stop() {
        guard let engine else { return }
        self.engine = nil
        timer?.invalidate()
        timer = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        recordingBounds = nil
        startedAt = nil
        pausedAt = nil
        pausedDuration = 0
        isPaused = false
        isRecording = false
        Task {
            do {
                let url = try await engine.stop()
                lastRecordingURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePause() {
        guard isRecording, let engine else { return }
        if isPaused {
            if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
            self.pausedAt = nil
            isPaused = false
            engine.resume()
        } else {
            pausedAt = Date()
            isPaused = true
            engine.pause()
        }
    }

    func revealLastRecording() {
        guard let lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    func copyLastRecording() {
        guard let lastRecordingURL,
              FileManager.default.fileExists(atPath: lastRecordingURL.path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([lastRecordingURL as NSURL])
        statusMessage = "Recording copied as a file."
    }

    func copyAndTrashLastRecording() {
        guard let lastRecordingURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([lastRecordingURL as NSURL])
        NSWorkspace.shared.recycle([lastRecordingURL]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.errorMessage = error.localizedDescription }
                else {
                    self?.lastRecordingURL = nil
                    self?.statusMessage = "Recording copied, then moved to recoverable Trash."
                }
            }
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(
            at: recordingsFolder, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(recordingsFolder)
    }

    private static func filename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "MacScope-Recording-\(formatter.string(from: Date())).mov"
    }

    private func recordPointerClick(_ event: NSEvent) {
        guard isRecording, !isPaused, let recordingBounds,
              recordingBounds.width > 0, recordingBounds.height > 0 else { return }
        let location = event.cgEvent?.location ?? NSEvent.mouseLocation
        guard recordingBounds.insetBy(dx: -2, dy: -2).contains(location) else { return }
        let x = min(max((location.x - recordingBounds.minX) / recordingBounds.width, 0), 1)
        let y = min(max((location.y - recordingBounds.minY) / recordingBounds.height, 0), 1)
        let time: TimeInterval
        if let startedAt {
            time = max(Date().timeIntervalSince(startedAt) - pausedDuration, 0)
        } else {
            time = elapsed
        }
        pointerEvents.append(.init(time: time, normalizedX: x, normalizedY: y))
    }

    private static func bounds(for target: Target?) -> CGRect? {
        switch target {
        case .display(let id):
            return CGDisplayBounds(id)
        case .window(let id):
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            guard let dictionary = rows?.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dictionary)
        case nil:
            return CGDisplayBounds(CGMainDisplayID())
        }
    }
}

private final class ScreenRecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let destination: URL
    private let includesSystemAudio: Bool
    private let includesMicrophone: Bool
    let target: ScreenRecordingService.Target?
    private let failureHandler: @Sendable (String) -> Void
    private let outputQueue = DispatchQueue(label: "local.taskmanager.MacScope.screen-recorder")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopping = false
    private var isPaused = false
    private var pauseBeganAt: Date?
    private var totalPausedSeconds: TimeInterval = 0

    init(
        destination: URL,
        includesSystemAudio: Bool,
        includesMicrophone: Bool,
        target: ScreenRecordingService.Target?,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        self.destination = destination
        self.includesSystemAudio = includesSystemAudio
        self.includesMicrophone = includesMicrophone
        self.target = target
        self.failureHandler = failureHandler
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let fallbackDisplay = content.displays.first else {
            throw NSError(
                domain: "MacScope.ScreenRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display is available to record."]
            )
        }

        let filter: SCContentFilter
        let captureWidth: Int
        let captureHeight: Int
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw NSError(domain: "MacScope.ScreenRecorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "The selected window is no longer available."])
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureWidth = max(Int(window.frame.width), 1)
            captureHeight = max(Int(window.frame.height), 1)
        case .display(let id):
            let display = content.displays.first(where: { $0.displayID == id }) ?? fallbackDisplay
            filter = SCContentFilter(display: display, excludingWindows: [])
            captureWidth = display.width
            captureHeight = display.height
        case nil:
            filter = SCContentFilter(display: fallbackDisplay, excludingWindows: [])
            captureWidth = fallbackDisplay.width
            captureHeight = fallbackDisplay.height
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: captureWidth,
                AVVideoHeightKey: captureHeight
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(
                domain: "MacScope.ScreenRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The recording writer rejected the display format."]
            )
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        var microphoneInput: AVAssetWriterInput?
        if includesMicrophone, #available(macOS 15.0, *) {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
            }
        }

        let configuration = SCStreamConfiguration()
        configuration.width = captureWidth
        configuration.height = captureHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = includesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = includesMicrophone
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if includesSystemAudio, audioInput != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if #available(macOS 15.0, *), includesMicrophone, microphoneInput != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        guard !stopping else { return destination }
        stopping = true
        if let stream { try await stream.stopCapture() }

        outputQueue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            microphoneInput?.markAsFinished()
        }
        if let writer {
            await writer.finishWriting()
            if writer.status == .failed {
                throw writer.error ?? NSError(
                    domain: "MacScope.ScreenRecorder", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The recording could not be finalized."]
                )
            }
        }
        return destination
    }

    func pause() {
        outputQueue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
            self.pauseBeganAt = Date()
        }
    }

    func resume() {
        outputQueue.async { [weak self] in
            guard let self, self.isPaused else { return }
            if let pauseBeganAt { self.totalPausedSeconds += Date().timeIntervalSince(pauseBeganAt) }
            self.pauseBeganAt = nil
            self.isPaused = false
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard !stopping, !isPaused, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let writer else { return }
        let adjusted = retimed(sampleBuffer) ?? sampleBuffer
        let time = CMSampleBufferGetPresentationTimeStamp(adjusted)

        if !sessionStarted {
            guard outputType == .screen, writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }

        switch outputType {
        case .screen:
            if videoInput?.isReadyForMoreMediaData == true { videoInput?.append(adjusted) }
        case .audio:
            if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(adjusted) }
        case .microphone:
            if microphoneInput?.isReadyForMoreMediaData == true {
                microphoneInput?.append(adjusted)
            }
        @unknown default:
            break
        }
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard totalPausedSeconds > 0 else { return sampleBuffer }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: count
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count
        ) == noErr else { return nil }
        let offset = CMTime(seconds: totalPausedSeconds, preferredTimescale: 1_000_000_000)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &adjusted
        ) == noErr else { return nil }
        return adjusted
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        failureHandler(error.localizedDescription)
    }
}
