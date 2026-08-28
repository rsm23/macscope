import AppKit
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import MacScope

@Suite("Media utility video editing")
struct MediaUtilityServiceTests {
    @Test("Scrolling screenshot segments stitch in top-to-bottom order") @MainActor
    func scrollingScreenshotSegmentsStitch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-StitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("1.png")
        let second = directory.appendingPathComponent("2.png")
        try makeImage(at: first, width: 100, height: 80, color: .red)
        try makeImage(at: second, width: 100, height: 60, color: .blue)
        let output = directory.appendingPathComponent("stitched.png")

        _ = try ScreenshotService.stitchImages(
            sources: [first, second],
            overlapPixels: 10,
            destination: output
        )

        let representation = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(representation.pixelsWide == 100)
        #expect(representation.pixelsHigh == 130)
    }

    @Test("Retina screenshots export at logical 1x dimensions") @MainActor
    func screenshotDownscalesToLogicalDimensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-ScaleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("retina.png")
        try makeImage(at: image, width: 200, height: 120, color: .green)

        try ScreenshotService.downscaleCaptureTo1x(image, scale: 2)

        let representation = try #require(NSBitmapImageRep(data: Data(contentsOf: image)))
        #expect(representation.pixelsWide == 100)
        #expect(representation.pixelsHigh == 60)
    }

    @Test("Temporary capture server requires its token and serves exact PNG bytes")
    func temporaryCaptureServerIsTokenScoped() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let token = "macscope-test-token"
        let server = LocalCaptureShareServer(imageData: payload, token: token)
        let port = try await withCheckedThrowingContinuation { continuation in
            do {
                try server.start { port in continuation.resume(returning: port) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        defer { server.stop() }

        let validURL = try #require(URL(string: "http://127.0.0.1:\(port)/\(token).png"))
        let invalidURL = try #require(URL(string: "http://127.0.0.1:\(port)/wrong.png"))
        let (served, validResponse) = try await URLSession.shared.data(from: validURL)
        let (_, invalidResponse) = try await URLSession.shared.data(from: invalidURL)

        #expect(served == payload)
        #expect((validResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((invalidResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Trim, cut and crop exports preserve requested media geometry")
    func trimAndCutExportsHaveExpectedDurations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-MediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mp4")
        try await makeVideo(at: source, seconds: 3)

        let trimmed = try await MediaUtilityService.trimVideo(source: source, start: 0.5, end: 2.5)
        let cut = try await MediaUtilityService.cutVideo(source: source, start: 1, end: 2)
        let cropped = try await MediaUtilityService.cropVideo(
            source: source,
            left: 0.25,
            right: 0.25,
            top: 0.25,
            bottom: 0.25
        )
        let decorated = try await MediaUtilityService.decorateVideo(
            source: source,
            text: "MacScope",
            paddingPercent: 0.10,
            background: .accent,
            audioVolume: 0,
            autoZoomEvents: [.init(time: 0.5, normalizedX: 0.25, normalizedY: 0.35)],
            autoZoomFactor: 1.6,
            autoZoomHoldSeconds: 0.8
        )
        let gif = try await MediaUtilityService.exportVideoGIF(source: source, framesPerSecond: 4)

        let trimmedDuration = try await duration(of: trimmed)
        let cutDuration = try await duration(of: cut)
        #expect(abs(trimmedDuration - 2) < 0.12)
        #expect(abs(cutDuration - 2) < 0.12)
        #expect(FileManager.default.fileExists(atPath: trimmed.path))
        #expect(FileManager.default.fileExists(atPath: cut.path))
        #expect(FileManager.default.fileExists(atPath: cropped.path))
        #expect(FileManager.default.fileExists(atPath: decorated.path))
        #expect(FileManager.default.fileExists(atPath: gif.path))
        let croppedTrack = try #require(try await AVURLAsset(url: cropped).loadTracks(withMediaType: .video).first)
        let croppedSize = try await croppedTrack.load(.naturalSize)
        #expect(abs(croppedSize.width - 80) < 1)
        #expect(abs(croppedSize.height - 60) < 1)
        let decoratedTrack = try #require(try await AVURLAsset(url: decorated).loadTracks(withMediaType: .video).first)
        let decoratedSize = try await decoratedTrack.load(.naturalSize)
        #expect(abs(decoratedSize.width - 192) < 1)
        #expect(abs(decoratedSize.height - 152) < 1)
        let gifSource = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(gifSource) == 12)
    }

    private func duration(of url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private func makeVideo(at destination: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 160,
                AVVideoHeightKey: 120
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120
            ]
        )
        guard writer.canAdd(input) else { throw TestVideoError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestVideoError.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let frameCount = seconds * 30
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var optionalBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else { throw TestVideoError.cannotAllocateFrame }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame % 240), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
            ) else { throw writer.error ?? TestVideoError.cannotWrite }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideoError.cannotWrite }
    }

    private func makeImage(at destination: URL, width: Int, height: Int, color: NSColor) throws {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        representation.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: destination)
    }

    private enum TestVideoError: Error {
        case cannotAddInput, cannotWrite, cannotAllocateFrame
    }
}
