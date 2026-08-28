import AppKit
import AVFoundation
import Foundation
import ImageIO
import Observation
import QuartzCore
import UniformTypeIdentifiers
import UserNotifications
import Vision

enum MediaExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: String { rawValue }
    var pathExtension: String { self == .png ? "png" : "jpg" }
}

enum RecordingCanvasBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case black = "Black"
    case white = "White"
    case accent = "Accent"

    var id: String { rawValue }
    var color: NSColor {
        switch self {
        case .black: .black
        case .white: .white
        case .accent: NSColor(red: 0.10, green: 0.45, blue: 0.86, alpha: 1)
        }
    }
}

struct MediaConversionProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var format: MediaExportFormat
    var quality: Double
    var maximumDimension: Double?
    var watermark: String?
}

struct RecordingEditPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var overlayText: String
    var paddingPercent: Double
    var background: RecordingCanvasBackground
    var audioVolume: Double
    var gifFramesPerSecond: Int
}

@MainActor
@Observable
final class MediaUtilityService {
    private(set) var sourceURL: URL?
    private(set) var sourceURLs: [URL] = []
    private(set) var outputURL: URL?
    private(set) var outputURLs: [URL] = []
    private(set) var isConverting = false
    private(set) var isExtractingText = false
    private(set) var isCreatingGIF = false
    private(set) var extractedText = ""
    private(set) var gifOutputURL: URL?
    private(set) var videoSourceURL: URL?
    private(set) var videoOutputURL: URL?
    private(set) var videoDuration: Double = 0
    private(set) var isCompressingVideo = false
    private(set) var isEditingVideo = false
    private(set) var statusMessage: String?
    private(set) var profiles: [MediaConversionProfile] = []
    private(set) var recordingPresets: [RecordingEditPreset] = []
    private let profilesKey = "utility.mediaConversionProfiles"
    private let recordingPresetsKey = "utility.recordingEditPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([MediaConversionProfile].self, from: data) {
            profiles = decoded
        }
        if let data = UserDefaults.standard.data(forKey: recordingPresetsKey),
           let decoded = try? JSONDecoder().decode([RecordingEditPreset].self, from: data) {
            recordingPresets = decoded
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Images"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sourceURLs = panel.urls
        sourceURL = panel.urls.first
        outputURL = nil
        outputURLs = []
        gifOutputURL = nil
        statusMessage = nil
    }

    /// Non-interactive counterpart used by the local MCP bridge.
    func loadImages(_ urls: [URL]) {
        let images = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !images.isEmpty else {
            statusMessage = "No readable images were provided."
            return
        }
        sourceURLs = images
        sourceURL = images.first
        outputURL = nil
        outputURLs = []
        gifOutputURL = nil
        statusMessage = "Loaded \(images.count) image\(images.count == 1 ? "" : "s")."
    }

    func convert(
        format: MediaExportFormat,
        quality: Double,
        maximumDimension: Double?,
        watermark: String? = nil
    ) {
        let sources = sourceURLs.isEmpty ? sourceURL.map { [$0] } ?? [] : sourceURLs
        guard !sources.isEmpty, !isConverting else { return }
        isConverting = true
        statusMessage = "Converting image…"
        Task {
            do {
                outputURLs = try await Task.detached(priority: .userInitiated) {
                    try sources.map { source in
                        try Self.convertImage(
                            source: source,
                            format: format,
                            quality: quality,
                            maximumDimension: maximumDimension,
                            watermark: watermark
                        )
                    }
                }.value
                outputURL = outputURLs.first
                statusMessage = "Converted \(outputURLs.count) image\(outputURLs.count == 1 ? "" : "s") beside the source files."
            } catch {
                statusMessage = error.localizedDescription
            }
            isConverting = false
        }
    }

    func extractText() {
        guard let sourceURL, !isExtractingText else { return }
        isExtractingText = true
        statusMessage = "Recognizing image text locally…"
        Task {
            do {
                extractedText = try await Task.detached(priority: .userInitiated) {
                    try Self.recognizeText(in: sourceURL)
                }.value
                statusMessage = extractedText.isEmpty ? "No text was recognized." : "Recognized text locally with Vision."
            } catch {
                statusMessage = error.localizedDescription
            }
            isExtractingText = false
        }
    }

    func copyExtractedText() {
        guard !extractedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(extractedText, forType: .string)
        statusMessage = "Recognized text copied."
    }

    func createAnimatedGIF(frameDuration: Double) {
        let sources = sourceURLs.isEmpty ? sourceURL.map { [$0] } ?? [] : sourceURLs
        guard sources.count >= 2, !isCreatingGIF else { return }
        isCreatingGIF = true
        statusMessage = "Creating animated GIF locally…"
        Task {
            do {
                gifOutputURL = try await Task.detached(priority: .userInitiated) {
                    try Self.createAnimatedGIF(
                        sources: sources,
                        frameDuration: min(max(frameDuration, 0.04), 10)
                    )
                }.value
                statusMessage = "Animated GIF created from \(sources.count) frames."
            } catch {
                statusMessage = error.localizedDescription
            }
            isCreatingGIF = false
        }
    }

    func revealGIFOutput() {
        guard let gifOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([gifOutputURL])
    }

    func saveProfile(
        name: String,
        format: MediaExportFormat,
        quality: Double,
        maximumDimension: Double?,
        watermark: String?
    ) {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else {
            statusMessage = "Enter a profile name first."
            return
        }
        let resolvedWatermark = watermark?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = MediaConversionProfile(
            id: UUID(),
            name: String(resolvedName.prefix(48)),
            format: format,
            quality: min(max(quality, 0.1), 1),
            maximumDimension: maximumDimension.flatMap { $0 > 0 ? $0 : nil },
            watermark: resolvedWatermark.flatMap { $0.isEmpty ? nil : $0 }
        )
        if let index = profiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(profile.name) == .orderedSame }) {
            profiles[index] = profile
            statusMessage = "Updated image profile \(profile.name)."
        } else {
            profiles.append(profile)
            profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            statusMessage = "Saved image profile \(profile.name)."
        }
        persistProfiles()
    }

    func deleteProfile(_ profile: MediaConversionProfile) {
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
        statusMessage = "Removed image profile \(profile.name)."
    }

    func saveRecordingPreset(
        name: String,
        overlayText: String,
        paddingPercent: Double,
        background: RecordingCanvasBackground,
        audioVolume: Double,
        gifFramesPerSecond: Int
    ) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = RecordingEditPreset(
            id: UUID(),
            name: String(name.prefix(48)),
            overlayText: String(overlayText.prefix(240)),
            paddingPercent: min(max(paddingPercent, 0), 25),
            background: background,
            audioVolume: min(max(audioVolume, 0), 2),
            gifFramesPerSecond: min(max(gifFramesPerSecond, 2), 15)
        )
        if let index = recordingPresets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame }) {
            recordingPresets[index] = preset
            statusMessage = "Updated recording preset \(preset.name)."
        } else {
            recordingPresets.append(preset)
            recordingPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            statusMessage = "Saved recording preset \(preset.name)."
        }
        persistRecordingPresets()
    }

    func deleteRecordingPreset(_ preset: RecordingEditPreset) {
        recordingPresets.removeAll { $0.id == preset.id }
        persistRecordingPresets()
        statusMessage = "Removed recording preset \(preset.name)."
    }

    func revealOutput() {
        let outputs = outputURLs.isEmpty ? outputURL.map { [$0] } ?? [] : outputURLs
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func loadVideo(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "The selected video no longer exists."
            return
        }
        videoSourceURL = url
        videoOutputURL = nil
        videoDuration = 0
        statusMessage = nil
        Task {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                videoDuration = max(CMTimeGetSeconds(duration), 0)
            } catch {
                statusMessage = "The selected video's duration could not be read."
            }
        }
    }

    func compressVideo() {
        guard let videoSourceURL, !isCompressingVideo else { return }
        isCompressingVideo = true
        statusMessage = "Compressing video locally…"
        Task {
            do {
                videoOutputURL = try await Self.compressVideo(source: videoSourceURL)
                statusMessage = "Compressed MP4 saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isCompressingVideo = false
        }
    }

    func revealVideoOutput() {
        guard let videoOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([videoOutputURL])
    }

    func copyVideoOutput() {
        guard let videoOutputURL,
              FileManager.default.fileExists(atPath: videoOutputURL.path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([videoOutputURL as NSURL])
        statusMessage = "Edited video copied as a file."
    }

    func trimVideo(start: Double, end: Double) {
        guard let videoSourceURL, !isEditingVideo else { return }
        let safeStart = max(start, 0)
        let safeEnd = min(end, videoDuration)
        guard videoDuration > 0, safeEnd - safeStart >= 0.1 else {
            statusMessage = "Choose a trim range at least 0.1 seconds long."
            return
        }
        isEditingVideo = true
        statusMessage = "Trimming video locally…"
        Task {
            do {
                videoOutputURL = try await Self.trimVideo(
                    source: videoSourceURL,
                    start: safeStart,
                    end: safeEnd
                )
                statusMessage = "Trimmed MP4 saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isEditingVideo = false
        }
    }

    func cutVideo(start: Double, end: Double) {
        guard let videoSourceURL, !isEditingVideo else { return }
        let safeStart = max(start, 0)
        let safeEnd = min(end, videoDuration)
        guard videoDuration > 0,
              safeEnd - safeStart >= 0.1,
              safeStart > 0 || safeEnd < videoDuration else {
            statusMessage = "Choose a middle range to remove while leaving some video before or after it."
            return
        }
        isEditingVideo = true
        statusMessage = "Removing the selected video range locally…"
        Task {
            do {
                videoOutputURL = try await Self.cutVideo(
                    source: videoSourceURL,
                    start: safeStart,
                    end: safeEnd
                )
                statusMessage = "Cut MP4 saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isEditingVideo = false
        }
    }

    func cropVideo(left: Double, right: Double, top: Double, bottom: Double) {
        guard let videoSourceURL, !isEditingVideo else { return }
        let insets = [left, right, top, bottom].map { min(max($0, 0), 45) / 100 }
        guard insets[0] + insets[1] < 0.9, insets[2] + insets[3] < 0.9 else {
            statusMessage = "The crop must leave at least 10% of the video's width and height."
            return
        }
        guard insets.contains(where: { $0 > 0 }) else {
            statusMessage = "Enter at least one crop inset above zero."
            return
        }
        isEditingVideo = true
        statusMessage = "Cropping video locally…"
        Task {
            do {
                videoOutputURL = try await Self.cropVideo(
                    source: videoSourceURL,
                    left: insets[0],
                    right: insets[1],
                    top: insets[2],
                    bottom: insets[3]
                )
                statusMessage = "Cropped MP4 saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isEditingVideo = false
        }
    }

    func decorateVideo(
        text: String,
        paddingPercent: Double,
        background: RecordingCanvasBackground,
        audioVolume: Double,
        autoZoomEvents: [ScreenRecordingService.PointerEvent] = [],
        autoZoomFactor: Double = 1,
        autoZoomHoldSeconds: Double = 1.5
    ) {
        guard let videoSourceURL, !isEditingVideo else { return }
        isEditingVideo = true
        statusMessage = "Rendering recording text, canvas and audio locally…"
        Task {
            do {
                videoOutputURL = try await Self.decorateVideo(
                    source: videoSourceURL,
                    text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
                    paddingPercent: min(max(paddingPercent, 0), 25) / 100,
                    background: background,
                    audioVolume: Float(min(max(audioVolume, 0), 2)),
                    autoZoomEvents: autoZoomEvents,
                    autoZoomFactor: min(max(autoZoomFactor, 1), 2.5),
                    autoZoomHoldSeconds: min(max(autoZoomHoldSeconds, 0.4), 5)
                )
                statusMessage = "Decorated MP4 saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isEditingVideo = false
        }
    }

    func exportVideoGIF(framesPerSecond: Int) {
        guard let videoSourceURL, !isEditingVideo else { return }
        isEditingVideo = true
        statusMessage = "Exporting the first 12 seconds as an animated GIF locally…"
        Task {
            do {
                videoOutputURL = try await Self.exportVideoGIF(
                    source: videoSourceURL,
                    framesPerSecond: min(max(framesPerSecond, 2), 15)
                )
                statusMessage = "Animated GIF saved next to the source."
            } catch {
                statusMessage = error.localizedDescription
            }
            isEditingVideo = false
        }
    }

    nonisolated private static func convertImage(
        source: URL,
        format: MediaExportFormat,
        quality: Double,
        maximumDimension: Double?,
        watermark: String?
    ) throws -> URL {
        guard let image = NSImage(contentsOf: source),
              let sourceRepresentation = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            throw NSError(
                domain: "MacScope.Media", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected image could not be decoded."]
            )
        }
        let original = NSSize(width: sourceRepresentation.pixelsWide, height: sourceRepresentation.pixelsHigh)
        let target: NSSize
        if let maximumDimension, maximumDimension > 0,
           max(original.width, original.height) > maximumDimension {
            let scale = maximumDimension / max(original.width, original.height)
            target = NSSize(width: floor(original.width * scale), height: floor(original.height * scale))
        } else {
            target = original
        }
        guard let outputRepresentation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(target.width), 1),
            pixelsHigh: max(Int(target.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: format == .png ? 4 : 3,
            hasAlpha: format == .png,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "MacScope.Media", code: 2, userInfo: [NSLocalizedDescriptionKey: "The output bitmap could not be created."])
        }
        outputRepresentation.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outputRepresentation)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        if let watermark = watermark?.trimmingCharacters(in: .whitespacesAndNewlines), !watermark.isEmpty {
            let fontSize = max(min(target.width, target.height) * 0.035, 12)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black.withAlphaComponent(0.65),
                .strokeWidth: -2.0
            ]
            let text = NSString(string: watermark)
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: max(target.width - size.width - fontSize, fontSize), y: fontSize),
                withAttributes: attributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
            ? [.compressionFactor: min(max(quality, 0.1), 1)] : [:]
        let fileType: NSBitmapImageRep.FileType = format == .png ? .png : .jpeg
        guard let data = outputRepresentation.representation(using: fileType, properties: properties) else {
            throw NSError(domain: "MacScope.Media", code: 3, userInfo: [NSLocalizedDescriptionKey: "The image encoder failed."])
        }
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent()
            .appendingPathComponent("\(base)-MacScope.\(format.pathExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent()
                .appendingPathComponent("\(base)-MacScope-\(suffix).\(format.pathExtension)")
            suffix += 1
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    nonisolated private static func recognizeText(in source: URL) throws -> String {
        guard let image = NSImage(contentsOf: source) else {
            throw NSError(domain: "MacScope.Media", code: 6, userInfo: [NSLocalizedDescriptionKey: "The selected image could not be decoded for OCR."])
        }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw NSError(domain: "MacScope.Media", code: 7, userInfo: [NSLocalizedDescriptionKey: "The selected image could not be converted for OCR."])
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    nonisolated private static func createAnimatedGIF(
        sources: [URL],
        frameDuration: Double
    ) throws -> URL {
        guard let first = sources.first else {
            throw NSError(domain: "MacScope.Media", code: 8, userInfo: [NSLocalizedDescriptionKey: "Choose at least two images."])
        }
        let base = first.deletingPathExtension().lastPathComponent
        var destination = first.deletingLastPathComponent().appendingPathComponent("\(base)-animated.gif")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = first.deletingLastPathComponent().appendingPathComponent("\(base)-animated-\(suffix).gif")
            suffix += 1
        }
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            "com.compuserve.gif" as CFString,
            sources.count,
            nil
        ) else {
            throw NSError(domain: "MacScope.Media", code: 9, userInfo: [NSLocalizedDescriptionKey: "The GIF encoder could not be created."])
        }
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDuration,
                kCGImagePropertyGIFUnclampedDelayTime: frameDuration
            ]
        ] as CFDictionary
        for source in sources {
            guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let frame = CGImageSourceCreateImageAtIndex(reader, 0, nil) else {
                throw NSError(
                    domain: "MacScope.Media", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "\(source.lastPathComponent) could not be decoded as a GIF frame."]
                )
            }
            CGImageDestinationAddImage(writer, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "MacScope.Media", code: 11, userInfo: [NSLocalizedDescriptionKey: "The animated GIF could not be finalized."])
        }
        return destination
    }

    nonisolated private static func compressVideo(source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw NSError(
                domain: "MacScope.Media", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "This video cannot be exported with the medium-quality preset."]
            )
        }
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-compressed.mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-compressed-\(suffix).mp4")
            suffix += 1
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "MacScope.Media", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The video export did not complete."]
            )
        }
        return destination
    }

    nonisolated static func trimVideo(
        source: URL,
        start: Double,
        end: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(
                domain: "MacScope.Media", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "This video cannot be exported with the high-quality trim preset."]
            )
        }
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-trimmed.mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-trimmed-\(suffix).mp4")
            suffix += 1
        }
        let timescale = CMTimeScale(600)
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            end: CMTime(seconds: end, preferredTimescale: timescale)
        )
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "MacScope.Media", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "The trimmed video export did not complete."]
            )
        }
        return destination
    }

    nonisolated static func cutVideo(
        source: URL,
        start: Double,
        end: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let sourceDuration = try await asset.load(.duration)
        let timescale = CMTimeScale(600)
        let cutStart = CMTime(seconds: start, preferredTimescale: timescale)
        let cutEnd = CMTime(seconds: end, preferredTimescale: timescale)
        let leadingRange = CMTimeRange(start: .zero, end: cutStart)
        let trailingRange = CMTimeRange(start: cutEnd, end: sourceDuration)
        let composition = AVMutableComposition()

        for mediaType in [AVMediaType.video, AVMediaType.audio] {
            let sourceTracks = try await asset.loadTracks(withMediaType: mediaType)
            guard let sourceTrack = sourceTracks.first,
                  let destinationTrack = composition.addMutableTrack(
                    withMediaType: mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            if leadingRange.duration > .zero {
                try destinationTrack.insertTimeRange(leadingRange, of: sourceTrack, at: .zero)
            }
            if trailingRange.duration > .zero {
                try destinationTrack.insertTimeRange(
                    trailingRange,
                    of: sourceTrack,
                    at: leadingRange.duration
                )
            }
            if mediaType == .video {
                destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
            }
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(
                domain: "MacScope.Media", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "This video cannot be exported after cutting."]
            )
        }
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-cut.mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-cut-\(suffix).mp4")
            suffix += 1
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "MacScope.Media", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "The cut video export did not complete."]
            )
        }
        return destination
    }

    nonisolated static func cropVideo(
        source: URL,
        left: Double,
        right: Double,
        top: Double,
        bottom: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(
                domain: "MacScope.Media", code: 16,
                userInfo: [NSLocalizedDescriptionKey: "The selected file does not contain a video track."]
            )
        }
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let displaySize = transformedBounds.size
        guard displaySize.width >= 4, displaySize.height >= 4 else {
            throw NSError(
                domain: "MacScope.Media", code: 17,
                userInfo: [NSLocalizedDescriptionKey: "The video dimensions are too small to crop."]
            )
        }
        let rawCrop = CGRect(
            x: displaySize.width * left,
            y: displaySize.height * top,
            width: displaySize.width * (1 - left - right),
            height: displaySize.height * (1 - top - bottom)
        )
        let renderWidth = max(2, floor(rawCrop.width / 2) * 2)
        let renderHeight = max(2, floor(rawCrop.height / 2) * 2)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: renderWidth, height: renderHeight)
        let nominalFrameRate = try await sourceTrack.load(.nominalFrameRate)
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, min(nominalFrameRate.rounded(), 120)))
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceTrack)
        let normalize = CGAffineTransform(
            translationX: -transformedBounds.minX,
            y: -transformedBounds.minY
        )
        let cropTranslation = CGAffineTransform(
            translationX: -rawCrop.minX,
            y: -rawCrop.minY
        )
        layer.setTransform(
            preferredTransform.concatenating(normalize).concatenating(cropTranslation),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(
                domain: "MacScope.Media", code: 18,
                userInfo: [NSLocalizedDescriptionKey: "This video cannot be exported with a crop composition."]
            )
        }
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-cropped.mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-cropped-\(suffix).mp4")
            suffix += 1
        }
        exporter.videoComposition = composition
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "MacScope.Media", code: 19,
                userInfo: [NSLocalizedDescriptionKey: "The cropped video export did not complete."]
            )
        }
        return destination
    }

    nonisolated static func decorateVideo(
        source: URL,
        text: String,
        paddingPercent: Double,
        background: RecordingCanvasBackground,
        audioVolume: Float,
        autoZoomEvents: [ScreenRecordingService.PointerEvent] = [],
        autoZoomFactor: Double = 1,
        autoZoomHoldSeconds: Double = 1.5
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "MacScope.Media", code: 20, userInfo: [NSLocalizedDescriptionKey: "The file has no video track."])
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let baseSize = bounds.size
        let padding = floor(max(baseSize.width, baseSize.height) * paddingPercent)
        let renderSize = CGSize(
            width: max(2, floor((baseSize.width + padding * 2) / 2) * 2),
            height: max(2, floor((baseSize.height + padding * 2) / 2) * 2)
        )
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(nominalRate.rounded(), 120))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let normalize = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let inset = CGAffineTransform(translationX: padding, y: padding)
        let baseTransform = transform.concatenating(normalize).concatenating(inset)
        layer.setTransform(baseTransform, at: .zero)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0)
        let zoomFactor = min(max(autoZoomFactor, 1), 2.5)
        if zoomFactor > 1.001, durationSeconds > 0.5 {
            var lastAccepted = -Double.infinity
            for event in autoZoomEvents.sorted(by: { $0.time < $1.time }) {
                guard event.time - lastAccepted >= autoZoomHoldSeconds + 0.55 else { continue }
                lastAccepted = event.time
                let focus = CGPoint(
                    x: padding + min(max(event.normalizedX, 0), 1) * baseSize.width,
                    y: padding + (1 - min(max(event.normalizedY, 0), 1)) * baseSize.height
                )
                let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
                let zoomAroundFocus = CGAffineTransform(
                    a: zoomFactor,
                    b: 0,
                    c: 0,
                    d: zoomFactor,
                    tx: center.x - zoomFactor * focus.x,
                    ty: center.y - zoomFactor * focus.y
                )
                let zoomed = baseTransform.concatenating(zoomAroundFocus)
                let rampInStart = min(max(event.time - 0.12, 0), durationSeconds)
                let rampInEnd = min(rampInStart + 0.22, durationSeconds)
                let rampOutStart = min(rampInEnd + autoZoomHoldSeconds, durationSeconds)
                let rampOutEnd = min(rampOutStart + 0.32, durationSeconds)
                guard rampInEnd > rampInStart else { continue }
                layer.setTransformRamp(
                    fromStart: baseTransform,
                    toEnd: zoomed,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: rampInStart, preferredTimescale: 600),
                        end: CMTime(seconds: rampInEnd, preferredTimescale: 600)
                    )
                )
                layer.setTransform(zoomed, at: CMTime(seconds: rampInEnd, preferredTimescale: 600))
                if rampOutEnd > rampOutStart {
                    layer.setTransformRamp(
                        fromStart: zoomed,
                        toEnd: baseTransform,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: rampOutStart, preferredTimescale: 600),
                            end: CMTime(seconds: rampOutEnd, preferredTimescale: 600)
                        )
                    )
                }
            }
        }
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.backgroundColor = background.color.cgColor
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        if !text.isEmpty {
            let textLayer = CATextLayer()
            textLayer.string = text
            textLayer.alignmentMode = .center
            textLayer.font = NSFont.systemFont(ofSize: max(renderSize.width * 0.032, 16), weight: .semibold)
            textLayer.fontSize = max(renderSize.width * 0.032, 16)
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.8
            textLayer.shadowRadius = 3
            textLayer.contentsScale = 2
            textLayer.isWrapped = true
            textLayer.frame = CGRect(x: padding + 16, y: padding + 14, width: baseSize.width - 32, height: max(renderSize.height * 0.16, 60))
            parentLayer.addSublayer(textLayer)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "MacScope.Media", code: 21, userInfo: [NSLocalizedDescriptionKey: "This recording cannot be decorated."])
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(audioVolume, at: .zero)
                return parameters
            }
            exporter.audioMix = mix
        }
        let destination = uniqueMediaDestination(source: source, suffix: "edited", extension: "mp4")
        exporter.videoComposition = composition
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "MacScope.Media", code: 22, userInfo: [NSLocalizedDescriptionKey: "The decorated video export did not complete."])
        }
        return destination
    }

    nonisolated static func exportVideoGIF(source: URL, framesPerSecond: Int) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let seconds = min(max(CMTimeGetSeconds(duration), 0), 12)
        guard seconds >= 0.1 else {
            throw NSError(domain: "MacScope.Media", code: 23, userInfo: [NSLocalizedDescriptionKey: "The recording is too short for GIF export."])
        }
        let fps = min(max(framesPerSecond, 2), 15)
        let frameCount = min(max(Int((seconds * Double(fps)).rounded(.down)), 1), 180)
        let destination = uniqueMediaDestination(source: source, suffix: "animated", extension: "gif")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw NSError(domain: "MacScope.Media", code: 24, userInfo: [NSLocalizedDescriptionKey: "The GIF encoder could not be created."])
        }
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1 / Double(fps),
            kCGImagePropertyGIFUnclampedDelayTime: 1 / Double(fps),
        ]] as CFDictionary
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        for index in 0..<frameCount {
            let time = CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600)
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            CGImageDestinationAddImage(writer, image, properties)
        }
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "MacScope.Media", code: 25, userInfo: [NSLocalizedDescriptionKey: "The GIF export could not be finalized."])
        }
        return destination
    }

    nonisolated private static func uniqueMediaDestination(source: URL, suffix: String, extension pathExtension: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix).\(pathExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix)-\(number).\(pathExtension)")
            number += 1
        }
        return destination
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }

    private func persistRecordingPresets() {
        guard let data = try? JSONEncoder().encode(recordingPresets) else { return }
        UserDefaults.standard.set(data, forKey: recordingPresetsKey)
    }
}

struct InstalledApplicationItem: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    var id: URL { url }
}

struct ApplicationUpdateItem: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
    let installedVersion: String
    let availableVersion: String
    let storeURL: URL
    var id: String { bundleIdentifier }
}

struct LargeDownloadItem: Identifiable, Equatable, Sendable {
    let url: URL
    let size: Int64
    let modifiedAt: Date
    var id: URL { url }
}

enum MessagingDownloadCategory: String, CaseIterable, Codable, Sendable {
    case image = "Image"
    case video = "Video"
    case audio = "Audio"
    case document = "Document"
    case archive = "Archive"
    case other = "Other"
}

enum MessagingAutomationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "Off"
    case trashEligible = "Trash eligible daily"
    case organizeEligible = "Organize eligible daily"
    var id: String { rawValue }
}

struct MessagingDownloadItem: Identifiable, Equatable, Sendable {
    let url: URL
    let size: Int64
    let downloadedAt: Date
    let modifiedAt: Date
    let sourceApplication: String
    let category: MessagingDownloadCategory
    let isRetentionEligible: Bool
    var id: URL { url }
}

struct CleanupCandidate: Identifiable, Equatable, Sendable {
    let url: URL
    let category: String
    let size: Int64
    let modifiedAt: Date
    var id: URL { url }
}

struct HomebrewOutdatedItem: Identifiable, Equatable, Sendable {
    let name: String
    let installed: String
    let current: String
    let isCask: Bool
    var id: String { "\(isCask ? "cask" : "formula"):\(name)" }
}

struct HomebrewSearchItem: Identifiable, Equatable, Sendable {
    let name: String
    let isCask: Bool
    let isInstalled: Bool
    var id: String { "\(isCask ? "cask" : "formula"):\(name)" }
}

@MainActor
@Observable
final class MaintenanceUtilityService {
    private(set) var applications: [InstalledApplicationItem] = []
    private(set) var applicationUpdates: [ApplicationUpdateItem] = []
    private(set) var largeDownloads: [LargeDownloadItem] = []
    private(set) var messagingDownloads: [MessagingDownloadItem] = []
    private(set) var cleanupCandidates: [CleanupCandidate] = []
    private(set) var outdatedPackages: [HomebrewOutdatedItem] = []
    private(set) var homebrewSearchResults: [HomebrewSearchItem] = []
    private(set) var isScanningApplications = false
    private(set) var isCheckingApplicationUpdates = false
    private(set) var isScanningDownloads = false
    private(set) var isScanningMessagingDownloads = false
    private(set) var isScanningCleanup = false
    private(set) var isCheckingHomebrew = false
    private(set) var isSearchingHomebrew = false
    private(set) var activeOperation: String?
    private(set) var statusMessage: String?
    private(set) var cleanupScheduleHours: Double?
    private(set) var nextCleanupScan: Date?
    private(set) var messagingRetentionDays = 7
    private(set) var messagingOrganizerFolder: URL?
    private(set) var messagingAutomationMode = MessagingAutomationMode.off
    private(set) var nextMessagingAutomation: Date?
    private(set) var deepUninstallerScanEnabled = false
    private(set) var backgroundUpdateChecksEnabled = false
    private(set) var appCatalogUpdateSourceEnabled = true
    private(set) var homebrewUpdateSourceEnabled = true
    private(set) var nextBackgroundUpdateCheck: Date?
    private var cleanupTimer: Timer?
    private var messagingAutomationTimer: Timer?
    private var backgroundUpdateTimer: Timer?
    private let cleanupScheduleKey = "utility.cleanupScheduleHours"
    private let messagingRetentionKey = "utility.messagingRetentionDays"
    private let messagingOrganizerFolderKey = "utility.messagingOrganizerFolder"
    private let messagingAutomationKey = "utility.messagingAutomationMode"
    private let deepUninstallerScanKey = "utility.deepUninstallerScanEnabled"
    private let backgroundUpdateChecksKey = "utility.backgroundUpdateChecksEnabled"
    private let appCatalogUpdateSourceKey = "utility.appCatalogUpdateSourceEnabled"
    private let homebrewUpdateSourceKey = "utility.homebrewUpdateSourceEnabled"

    init() {
        let saved = UserDefaults.standard.double(forKey: cleanupScheduleKey)
        if saved > 0 {
            cleanupScheduleHours = saved
            configureCleanupTimer()
        }
        let retention = UserDefaults.standard.integer(forKey: messagingRetentionKey)
        if [1, 2, 7, 14, 30].contains(retention) { messagingRetentionDays = retention }
        if let path = UserDefaults.standard.string(forKey: messagingOrganizerFolderKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { messagingOrganizerFolder = url }
        }
        if let raw = UserDefaults.standard.string(forKey: messagingAutomationKey),
           let mode = MessagingAutomationMode(rawValue: raw) {
            messagingAutomationMode = mode
            configureMessagingAutomationTimer()
        }
        deepUninstallerScanEnabled = UserDefaults.standard.bool(forKey: deepUninstallerScanKey)
        backgroundUpdateChecksEnabled = UserDefaults.standard.bool(forKey: backgroundUpdateChecksKey)
        appCatalogUpdateSourceEnabled = UserDefaults.standard.object(forKey: appCatalogUpdateSourceKey) as? Bool ?? true
        homebrewUpdateSourceEnabled = UserDefaults.standard.object(forKey: homebrewUpdateSourceKey) as? Bool ?? true
        configureBackgroundUpdateTimer()
    }

    var brewExecutable: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func scanApplications() {
        guard !isScanningApplications else { return }
        isScanningApplications = true
        Task {
            applications = await Task.detached(priority: .utility) { Self.applicationInventory() }.value
            isScanningApplications = false
            statusMessage = "Found \(applications.count) installed applications."
        }
    }

    func checkApplicationUpdates(sendNotification: Bool = false) {
        guard appCatalogUpdateSourceEnabled else {
            applicationUpdates = []
            statusMessage = "App Store catalog update checks are disabled."
            return
        }
        guard !isCheckingApplicationUpdates else { return }
        isCheckingApplicationUpdates = true
        statusMessage = "Checking public App Store versions…"
        Task {
            let inventory = applications.isEmpty
                ? await Task.detached(priority: .utility) { Self.applicationInventory() }.value
                : applications
            if applications.isEmpty { applications = inventory }
            let region = Locale.current.region?.identifier.lowercased() ?? "us"
            var discovered: [ApplicationUpdateItem] = []
            for start in stride(from: 0, to: inventory.count, by: 12) {
                let batch = Array(inventory[start..<min(start + 12, inventory.count)])
                let values = await withTaskGroup(of: ApplicationUpdateItem?.self) { group in
                    for app in batch {
                        group.addTask { await Self.availableUpdate(for: app, region: region) }
                    }
                    var results: [ApplicationUpdateItem] = []
                    for await item in group { if let item { results.append(item) } }
                    return results
                }
                discovered += values
            }
            applicationUpdates = discovered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            statusMessage = applicationUpdates.isEmpty
                ? "No newer App Store versions were found for exact bundle identifiers."
                : "Found \(applicationUpdates.count) application update\(applicationUpdates.count == 1 ? "" : "s")."
            if sendNotification, !applicationUpdates.isEmpty {
                await Self.sendUpdateNotification(
                    title: "MacScope found app updates",
                    body: "\(applicationUpdates.count) App Store catalog update\(applicationUpdates.count == 1 ? " is" : "s are") ready to review."
                )
            }
            isCheckingApplicationUpdates = false
        }
    }

    func setBackgroundUpdateChecksEnabled(_ enabled: Bool) {
        backgroundUpdateChecksEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: backgroundUpdateChecksKey)
        configureBackgroundUpdateTimer()
        statusMessage = enabled
            ? "Daily app and Homebrew update checks are enabled while MacScope is running."
            : "Background update checks are off."
    }

    func setAppCatalogUpdateSourceEnabled(_ enabled: Bool) {
        appCatalogUpdateSourceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: appCatalogUpdateSourceKey)
        if !enabled { applicationUpdates = [] }
        statusMessage = "App Store catalog checks are \(enabled ? "enabled" : "disabled")."
    }

    func setHomebrewUpdateSourceEnabled(_ enabled: Bool) {
        homebrewUpdateSourceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: homebrewUpdateSourceKey)
        if !enabled { outdatedPackages = [] }
        statusMessage = "Homebrew update checks are \(enabled ? "enabled" : "disabled")."
    }

    func runBackgroundUpdateCheckNow() {
        if appCatalogUpdateSourceEnabled { checkApplicationUpdates(sendNotification: true) }
        if homebrewUpdateSourceEnabled { checkHomebrew(sendNotification: true) }
        if !appCatalogUpdateSourceEnabled, !homebrewUpdateSourceEnabled {
            statusMessage = "Enable at least one update source first."
        }
        if backgroundUpdateChecksEnabled { nextBackgroundUpdateCheck = Date().addingTimeInterval(24 * 3_600) }
    }

    func scanDownloads() {
        guard !isScanningDownloads else { return }
        isScanningDownloads = true
        Task {
            largeDownloads = await Task.detached(priority: .utility) { Self.largeDownloadInventory() }.value
            isScanningDownloads = false
            statusMessage = largeDownloads.isEmpty
                ? "No files larger than 100 MB were found in Downloads."
                : "Found \(largeDownloads.count) large Downloads items."
        }
    }

    func setMessagingRetentionDays(_ days: Int) {
        guard [1, 2, 7, 14, 30].contains(days) else { return }
        messagingRetentionDays = days
        UserDefaults.standard.set(days, forKey: messagingRetentionKey)
        scanMessagingDownloads()
    }

    func scanMessagingDownloads() {
        guard !isScanningMessagingDownloads else { return }
        isScanningMessagingDownloads = true
        let retention = messagingRetentionDays
        Task {
            messagingDownloads = await Task.detached(priority: .utility) {
                Self.messagingDownloadInventory(retentionDays: retention)
            }.value
            isScanningMessagingDownloads = false
            statusMessage = messagingDownloads.isEmpty
                ? "No top-level Downloads files were attributed to a supported messaging app by macOS metadata."
                : "Found \(messagingDownloads.count) metadata-confirmed messaging download\(messagingDownloads.count == 1 ? "" : "s")."
        }
    }

    func chooseMessagingOrganizerFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Messaging Downloads Organizer Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        messagingOrganizerFolder = url.standardizedFileURL
        UserDefaults.standard.set(url.path, forKey: messagingOrganizerFolderKey)
        statusMessage = "Messaging downloads will be organized inside \(url.lastPathComponent)."
    }

    func organizeMessagingDownloads(_ urls: [URL]) {
        guard let root = messagingOrganizerFolder, !urls.isEmpty else { return }
        let chosen = messagingDownloads.filter { urls.contains($0.url) }
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.organizeMessagingItems(chosen, inside: root)
            }.value
            let moved = Set(result.moved)
            messagingDownloads.removeAll { moved.contains($0.url) }
            statusMessage = result.failed == 0
                ? "Organized \(result.moved.count) messaging download\(result.moved.count == 1 ? "" : "s")."
                : "Organized \(result.moved.count); \(result.failed) item\(result.failed == 1 ? "" : "s") could not be moved."
        }
    }

    func setMessagingAutomationMode(_ mode: MessagingAutomationMode) {
        if mode == .organizeEligible, messagingOrganizerFolder == nil {
            statusMessage = "Choose an organizer folder before enabling automatic organization."
            return
        }
        messagingAutomationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: messagingAutomationKey)
        configureMessagingAutomationTimer()
        statusMessage = mode == .off
            ? "Messaging-download automation is off."
            : "Messaging-download automation will run daily while MacScope is running."
    }

    func runMessagingAutomationNow() {
        guard messagingAutomationMode != .off, !isScanningMessagingDownloads else { return }
        isScanningMessagingDownloads = true
        let retention = messagingRetentionDays
        let mode = messagingAutomationMode
        let organizer = messagingOrganizerFolder
        statusMessage = "Checking metadata-confirmed messaging downloads for automation…"
        Task {
            let inventory = await Task.detached(priority: .utility) {
                Self.messagingDownloadInventory(retentionDays: retention)
            }.value
            messagingDownloads = inventory
            let eligible = inventory.filter(\.isRetentionEligible)
            guard !eligible.isEmpty else {
                isScanningMessagingDownloads = false
                statusMessage = "No metadata-confirmed messaging files are eligible for the configured automation."
                return
            }
            switch mode {
            case .off:
                break
            case .trashEligible:
                let urls = eligible.map(\.url)
                NSWorkspace.shared.recycle(urls) { [weak self] _, error in
                    Task { @MainActor in
                        self?.isScanningMessagingDownloads = false
                        if let error {
                            self?.statusMessage = error.localizedDescription
                        } else {
                            let removed = Set(urls)
                            self?.messagingDownloads.removeAll { removed.contains($0.url) }
                            self?.statusMessage = "Automation moved \(urls.count) metadata-confirmed messaging file\(urls.count == 1 ? "" : "s") to recoverable Trash."
                        }
                    }
                }
                return
            case .organizeEligible:
                guard let organizer else {
                    isScanningMessagingDownloads = false
                    statusMessage = "The organizer folder is unavailable; no files were moved."
                    return
                }
                let result = await Task.detached(priority: .utility) {
                    Self.organizeMessagingItems(eligible, inside: organizer)
                }.value
                let moved = Set(result.moved)
                messagingDownloads.removeAll { moved.contains($0.url) }
                statusMessage = "Automation organized \(result.moved.count) file\(result.moved.count == 1 ? "" : "s")\(result.failed == 0 ? "." : "; \(result.failed) could not be moved.")"
            }
            isScanningMessagingDownloads = false
        }
    }

    func scanCleanupCandidates() {
        guard !isScanningCleanup else { return }
        isScanningCleanup = true
        Task {
            cleanupCandidates = await Task.detached(priority: .utility) {
                Self.cleanupInventory()
            }.value
            isScanningCleanup = false
            statusMessage = cleanupCandidates.isEmpty
                ? "No cache or log candidates were found."
                : "Found \(cleanupCandidates.count) cache and log candidates for review."
        }
    }

    func setCleanupSchedule(hours: Double?) {
        cleanupScheduleHours = hours
        if let hours { UserDefaults.standard.set(hours, forKey: cleanupScheduleKey) }
        else { UserDefaults.standard.removeObject(forKey: cleanupScheduleKey) }
        configureCleanupTimer()
        statusMessage = hours == nil
            ? "Scheduled cleanup scans are off."
            : "MacScope will scan caches and logs every \(Int(hours!)) hours; removal still requires review."
    }

    private func configureCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        nextCleanupScan = nil
        guard let cleanupScheduleHours else { return }
        let interval = max(cleanupScheduleHours * 3_600, 3_600)
        nextCleanupScan = Date().addingTimeInterval(interval)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nextCleanupScan = Date().addingTimeInterval(interval)
                self.scanCleanupCandidates()
            }
        }
    }

    private func configureMessagingAutomationTimer() {
        messagingAutomationTimer?.invalidate()
        messagingAutomationTimer = nil
        nextMessagingAutomation = nil
        guard messagingAutomationMode != .off else { return }
        let interval: TimeInterval = 24 * 3_600
        nextMessagingAutomation = Date().addingTimeInterval(interval)
        messagingAutomationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nextMessagingAutomation = Date().addingTimeInterval(interval)
                self.runMessagingAutomationNow()
            }
        }
    }

    private func configureBackgroundUpdateTimer() {
        backgroundUpdateTimer?.invalidate()
        backgroundUpdateTimer = nil
        nextBackgroundUpdateCheck = nil
        guard backgroundUpdateChecksEnabled else { return }
        let interval: TimeInterval = 24 * 3_600
        nextBackgroundUpdateCheck = Date().addingTimeInterval(interval)
        backgroundUpdateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nextBackgroundUpdateCheck = Date().addingTimeInterval(interval)
                self.runBackgroundUpdateCheckNow()
            }
        }
    }

    func checkHomebrew(sendNotification: Bool = false) {
        guard homebrewUpdateSourceEnabled else {
            outdatedPackages = []
            statusMessage = "Homebrew update checks are disabled."
            return
        }
        guard !isCheckingHomebrew, let brewExecutable else { return }
        isCheckingHomebrew = true
        statusMessage = nil
        Task {
            do {
                outdatedPackages = try await Task.detached(priority: .utility) {
                    try Self.homebrewOutdated(executable: brewExecutable)
                }.value
                statusMessage = outdatedPackages.isEmpty
                    ? "Homebrew packages are up to date."
                    : "\(outdatedPackages.count) Homebrew update\(outdatedPackages.count == 1 ? "" : "s") available."
                if sendNotification, !outdatedPackages.isEmpty {
                    await Self.sendUpdateNotification(
                        title: "MacScope found Homebrew updates",
                        body: "\(outdatedPackages.count) managed package update\(outdatedPackages.count == 1 ? " is" : "s are") ready to review."
                    )
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isCheckingHomebrew = false
        }
    }

    nonisolated private static func sendUpdateNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "MacScope.updates.\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }

    func upgrade(_ item: HomebrewOutdatedItem) {
        guard activeOperation == nil, let brewExecutable else { return }
        activeOperation = item.id
        statusMessage = "Updating \(item.name)…"
        Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try Self.run(
                        brewExecutable,
                        arguments: ["upgrade"] + (item.isCask ? ["--cask"] : []) + [item.name]
                    )
                }.value
                statusMessage = "Updated \(item.name)."
                outdatedPackages.removeAll { $0.id == item.id }
            } catch {
                statusMessage = error.localizedDescription
            }
            activeOperation = nil
        }
    }

    func upgradeAll(_ items: [HomebrewOutdatedItem]) {
        guard activeOperation == nil, let brewExecutable, !items.isEmpty else { return }
        let selected = items
        activeOperation = "upgrade-all"
        statusMessage = "Updating \(selected.count) Homebrew packages…"
        Task {
            var completed: [String] = []
            do {
                for item in selected {
                    try await Task.detached(priority: .utility) {
                        _ = try Self.run(
                            brewExecutable,
                            arguments: ["upgrade"] + (item.isCask ? ["--cask"] : []) + [item.name]
                        )
                    }.value
                    completed.append(item.id)
                    outdatedPackages.removeAll { $0.id == item.id }
                }
                statusMessage = "Updated all \(selected.count) Homebrew packages."
            } catch {
                statusMessage = "Updated \(completed.count) of \(selected.count); stopped because \(error.localizedDescription)"
            }
            activeOperation = nil
        }
    }

    func searchHomebrew(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !isSearchingHomebrew, let brewExecutable else { return }
        isSearchingHomebrew = true
        Task {
            do {
                homebrewSearchResults = try await Task.detached(priority: .utility) {
                    try Self.homebrewSearch(executable: brewExecutable, query: query)
                }.value
                statusMessage = "Found \(homebrewSearchResults.count) Homebrew result\(homebrewSearchResults.count == 1 ? "" : "s")."
            } catch {
                statusMessage = error.localizedDescription
            }
            isSearchingHomebrew = false
        }
    }

    func setHomebrewInstalled(_ install: Bool, item: HomebrewSearchItem) {
        guard activeOperation == nil, let brewExecutable else { return }
        activeOperation = item.id
        statusMessage = "\(install ? "Installing" : "Removing") \(item.name)…"
        Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try Self.run(
                        brewExecutable,
                        arguments: [install ? "install" : "uninstall"]
                            + (item.isCask ? ["--cask"] : []) + [item.name]
                    )
                }.value
                if let index = homebrewSearchResults.firstIndex(where: { $0.id == item.id }) {
                    homebrewSearchResults[index] = HomebrewSearchItem(
                        name: item.name, isCask: item.isCask, isInstalled: install
                    )
                }
                statusMessage = "\(install ? "Installed" : "Removed") \(item.name)."
            } catch {
                statusMessage = error.localizedDescription
            }
            activeOperation = nil
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func setDeepUninstallerScanEnabled(_ enabled: Bool) {
        deepUninstallerScanEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: deepUninstallerScanKey)
        statusMessage = enabled
            ? "Deep leftover discovery is enabled. Protected folders remain subject to Full Disk Access."
            : "Uninstaller leftover discovery is limited to standard user-library locations."
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func moveToTrash(_ url: URL) {
        moveToTrash([url])
    }

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.statusMessage = error.localizedDescription }
                else {
                    let removed = Set(urls)
                    self?.applications.removeAll { removed.contains($0.url) }
                    self?.largeDownloads.removeAll { removed.contains($0.url) }
                    self?.cleanupCandidates.removeAll { removed.contains($0.url) }
                    self?.messagingDownloads.removeAll { removed.contains($0.url) }
                    self?.statusMessage = "Moved \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash."
                }
            }
        }
    }

    func relatedApplicationFiles(for app: InstalledApplicationItem) -> [URL] {
        let manager = FileManager.default
        let infoURL = app.url.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: infoURL)
        let bundleIdentifier = info?["CFBundleIdentifier"] as? String
        let homeLibrary = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        var candidates = [
            homeLibrary.appendingPathComponent("Application Support/\(app.name)", isDirectory: true)
        ]
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            candidates += [
                homeLibrary.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true),
                homeLibrary.appendingPathComponent("Preferences/\(bundleIdentifier).plist"),
                homeLibrary.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true),
                homeLibrary.appendingPathComponent("Containers/\(bundleIdentifier)", isDirectory: true),
                homeLibrary.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true),
                homeLibrary.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true)
            ]
            let launchAgents = homeLibrary.appendingPathComponent("LaunchAgents", isDirectory: true)
            if let agentURLs = try? manager.contentsOfDirectory(
                at: launchAgents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                candidates += agentURLs.filter {
                    $0.lastPathComponent.localizedCaseInsensitiveContains(bundleIdentifier)
                }
            }
        }
        if deepUninstallerScanEnabled {
            let roots = [
                homeLibrary.appendingPathComponent("Group Containers", isDirectory: true),
                homeLibrary.appendingPathComponent("Logs", isDirectory: true),
                homeLibrary.appendingPathComponent("Application Scripts", isDirectory: true),
                URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
                URL(fileURLWithPath: "/Library/Preferences", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true),
                URL(fileURLWithPath: "/Library/QuickLook", isDirectory: true),
                URL(fileURLWithPath: "/Library/Internet Plug-Ins", isDirectory: true),
            ]
            let identifiers = [bundleIdentifier, app.name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            for root in roots {
                guard let children = try? manager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                candidates += children.filter { child in
                    let name = child.deletingPathExtension().lastPathComponent.lowercased()
                    return identifiers.contains(where: { identifier in
                        name == identifier || name.contains(bundleIdentifier?.lowercased() ?? "\u{0}")
                    })
                }
            }
        }
        return Array(Set(candidates.filter { manager.fileExists(atPath: $0.path) }))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func applicationInventory() -> [InstalledApplicationItem] {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        return roots.flatMap { root -> [InstalledApplicationItem] in
            guard let urls = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return urls.compactMap { url in
                guard url.pathExtension.lowercased() == "app" else { return nil }
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                return InstalledApplicationItem(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    size: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                )
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func availableUpdate(
        for app: InstalledApplicationItem,
        region: String
    ) async -> ApplicationUpdateItem? {
        let info = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist"))
        guard let bundleIdentifier = info?["CFBundleIdentifier"] as? String,
              let installedVersion = info?["CFBundleShortVersionString"] as? String,
              !bundleIdentifier.isEmpty, !installedVersion.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: region)
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let lookup = try? JSONDecoder().decode(AppStoreLookupResponse.self, from: data),
              let result = lookup.results.first(where: { $0.bundleId == bundleIdentifier }),
              result.version.compare(installedVersion, options: .numeric) == .orderedDescending,
              let storeURL = URL(string: result.trackViewUrl) else { return nil }
        return ApplicationUpdateItem(
            bundleIdentifier: bundleIdentifier,
            name: result.trackName,
            installedVersion: installedVersion,
            availableVersion: result.version,
            storeURL: storeURL
        )
    }

    nonisolated private static func largeDownloadInventory() -> [LargeDownloadItem] {
        let manager = FileManager.default
        let root = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [LargeDownloadItem] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileAllocatedSize ?? 0)
            guard size >= 100 * 1_024 * 1_024 else { continue }
            result.append(LargeDownloadItem(
                url: url,
                size: size,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return result.sorted { $0.size > $1.size }.prefix(50).map { $0 }
    }

    nonisolated private static func messagingDownloadInventory(retentionDays: Int) -> [MessagingDownloadItem] {
        let manager = FileManager.default
        let root = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .isAliasFileKey, .isHiddenKey, .fileAllocatedSizeKey, .contentTypeKey,
            .quarantinePropertiesKey, .addedToDirectoryDateKey, .creationDateKey,
            .contentModificationDateKey
        ]
        guard let children = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        let allowedAgents = ["whatsapp", "telegram", "signal", "discord", "messages"]
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        return children.compactMap { url -> MessagingDownloadItem? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isDirectory != true,
                  values.isPackage != true,
                  values.isSymbolicLink != true,
                  values.isAliasFile != true,
                  values.isHidden != true,
                  let quarantine = values.quarantineProperties,
                  let rawAgent = quarantine["LSQuarantineAgentName"] as? String,
                  allowedAgents.contains(where: { rawAgent.localizedCaseInsensitiveContains($0) }),
                  let downloaded = (quarantine["LSQuarantineTimeStamp"] as? Date)
                    ?? values.addedToDirectoryDate ?? values.creationDate else { return nil }
            let modified = values.contentModificationDate ?? downloaded
            return MessagingDownloadItem(
                url: url.standardizedFileURL,
                size: Int64(values.fileAllocatedSize ?? 0),
                downloadedAt: downloaded,
                modifiedAt: modified,
                sourceApplication: rawAgent,
                category: messagingCategory(contentType: values.contentType, fileExtension: url.pathExtension),
                isRetentionEligible: downloaded <= cutoff && modified <= cutoff
            )
        }.sorted {
            if $0.downloadedAt != $1.downloadedAt { return $0.downloadedAt > $1.downloadedAt }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated private static func messagingCategory(
        contentType: UTType?,
        fileExtension rawExtension: String
    ) -> MessagingDownloadCategory {
        let ext = rawExtension.lowercased()
        let archives: Set<String> = ["7z", "bz2", "dmg", "gz", "iso", "rar", "tar", "tgz", "xz", "zip"]
        let documents: Set<String> = ["csv", "doc", "docx", "epub", "key", "md", "numbers", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx"]
        if archives.contains(ext) { return .archive }
        if documents.contains(ext) { return .document }
        if let contentType {
            if contentType.conforms(to: .image) { return .image }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) { return .video }
            if contentType.conforms(to: .audio) { return .audio }
            if contentType.conforms(to: .archive) { return .archive }
            if contentType.conforms(to: .text) || contentType.conforms(to: .pdf) { return .document }
        }
        return .other
    }

    nonisolated private static func organizeMessagingItems(
        _ items: [MessagingDownloadItem],
        inside root: URL
    ) -> (moved: [URL], failed: Int) {
        let manager = FileManager.default
        var moved: [URL] = []
        var failed = 0
        for item in items {
            let folder = root.appendingPathComponent(item.category.rawValue + "s", isDirectory: true)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                var destination = folder.appendingPathComponent(item.url.lastPathComponent)
                var suffix = 2
                while manager.fileExists(atPath: destination.path) {
                    let base = item.url.deletingPathExtension().lastPathComponent
                    let ext = item.url.pathExtension
                    let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                    destination = folder.appendingPathComponent(name)
                    suffix += 1
                }
                try manager.moveItem(at: item.url, to: destination)
                moved.append(item.url)
            } catch {
                failed += 1
            }
        }
        return (moved, failed)
    }

    nonisolated private static func cleanupInventory() -> [CleanupCandidate] {
        let manager = FileManager.default
        let library = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let roots = [
            (library.appendingPathComponent("Caches", isDirectory: true), "Cache"),
            (library.appendingPathComponent("Logs", isDirectory: true), "Log")
        ]
        var candidates: [CleanupCandidate] = []
        for (root, category) in roots {
            guard let children = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileAllocatedSizeKey])
                let size = values?.isDirectory == true
                    ? recursiveSize(child, manager: manager)
                    : Int64(values?.fileAllocatedSize ?? 0)
                guard size > 0 else { continue }
                candidates.append(CleanupCandidate(
                    url: child,
                    category: category,
                    size: size,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return candidates.sorted { $0.size > $1.size }.prefix(100).map { $0 }
    }

    nonisolated private static func recursiveSize(_ root: URL, manager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey]
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated private static func homebrewOutdated(executable: URL) throws -> [HomebrewOutdatedItem] {
        let data = try run(executable, arguments: ["outdated", "--json=v2"])
        let root = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        let formulae = root.formulae.map {
            HomebrewOutdatedItem(
                name: $0.name,
                installed: $0.installedVersions.joined(separator: ", "),
                current: $0.currentVersion,
                isCask: false
            )
        }
        let casks = root.casks.map {
            HomebrewOutdatedItem(
                name: $0.name,
                installed: $0.installedVersions.joined(separator: ", "),
                current: $0.currentVersion,
                isCask: true
            )
        }
        return (formulae + casks).sorted { $0.name < $1.name }
    }

    nonisolated private static func homebrewSearch(
        executable: URL,
        query: String
    ) throws -> [HomebrewSearchItem] {
        func lines(_ data: Data) -> [String] {
            String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.hasPrefix("==>") && !$0.isEmpty } ?? []
        }
        let formulae = lines(try run(executable, arguments: ["search", "--formulae", query]))
        let casks = lines(try run(executable, arguments: ["search", "--casks", query]))
        let installedFormulae = Set(lines(try run(executable, arguments: ["list", "--formula", "-1"])))
        let installedCasks = Set(lines(try run(executable, arguments: ["list", "--cask", "-1"])))
        return (
            formulae.map { HomebrewSearchItem(name: $0, isCask: false, isInstalled: installedFormulae.contains($0)) }
            + casks.map { HomebrewSearchItem(name: $0, isCask: true, isInstalled: installedCasks.contains($0)) }
        ).sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    @discardableResult
    nonisolated private static func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorText = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )
            let detail = errorText?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MacScope.Homebrew", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "Homebrew command failed."]
            )
        }
        return outputData
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let bundleId: String
    let trackName: String
    let version: String
    let trackViewUrl: String
}

private struct BrewOutdatedResponse: Decodable {
    let formulae: [BrewOutdatedEntry]
    let casks: [BrewOutdatedEntry]
}

private struct BrewOutdatedEntry: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}
