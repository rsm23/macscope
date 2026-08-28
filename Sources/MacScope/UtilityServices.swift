import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import IOKit.graphics
import MacScopeCore
import Network
import Observation

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case fullScreen = "Full screen"
    case window = "Window"
    case selection = "Selection"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fullScreen: "rectangle.inset.filled"
        case .window: "macwindow"
        case .selection: "viewfinder"
        }
    }
}

enum ScreenshotPostCaptureAction: String, CaseIterable, Identifiable {
    case none = "None"
    case previewMarkup = "Open in Preview"
    case reveal = "Reveal in Finder"
    case pin = "Pin floating"
    var id: String { rawValue }
}

struct ScreenshotRecord: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    var id: URL { url }
}

struct TemporaryCaptureShare: Identifiable, Equatable {
    let id: UUID
    let captureURL: URL
    let shareURL: URL
    let expiresAt: Date
}

struct ScreenshotFailure: Error, Sendable {
    let message: String
}

@MainActor
@Observable
final class ScreenshotService {
    private(set) var captures: [ScreenshotRecord] = []
    private(set) var isCapturing = false
    private(set) var countdownSeconds = 0
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isStitching = false
    private(set) var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    private(set) var temporaryShares: [TemporaryCaptureShare] = []
    private var pinnedPanels: [UUID: NSPanel] = [:]
    private var pinnedPanelObservers: [UUID: NSObjectProtocol] = [:]
    private var temporaryShareServers: [UUID: LocalCaptureShareServer] = [:]
    var organizesByDate: Bool {
        didSet { UserDefaults.standard.set(organizesByDate, forKey: "utility.captureDatedFolders") }
    }
    var filenamePrefix: String {
        didSet { UserDefaults.standard.set(filenamePrefix, forKey: "utility.captureFilenamePrefix") }
    }
    var exportsAt1x: Bool {
        didSet { UserDefaults.standard.set(exportsAt1x, forKey: "utility.captureExport1x") }
    }
    var postCaptureAction: ScreenshotPostCaptureAction {
        didSet { UserDefaults.standard.set(postCaptureAction.rawValue, forKey: "utility.capturePostAction") }
    }

    init() {
        organizesByDate = UserDefaults.standard.bool(forKey: "utility.captureDatedFolders")
        filenamePrefix = UserDefaults.standard.string(forKey: "utility.captureFilenamePrefix") ?? "MacScope"
        exportsAt1x = UserDefaults.standard.bool(forKey: "utility.captureExport1x")
        postCaptureAction = ScreenshotPostCaptureAction(
            rawValue: UserDefaults.standard.string(forKey: "utility.capturePostAction") ?? ""
        ) ?? .none
    }

    var captureFolder: URL {
        if let path = UserDefaults.standard.string(forKey: "utility.captureFolder"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacScope Captures", isDirectory: true)
    }

    func refresh() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        do {
            try FileManager.default.createDirectory(
                at: captureFolder, withIntermediateDirectories: true
            )
            let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
            let enumerator = FileManager.default.enumerator(
                at: captureFolder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            captures = (enumerator?.allObjects as? [URL] ?? []).compactMap { url in
                guard url.pathExtension.lowercased() == "png" else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { return nil }
                return ScreenshotRecord(
                    url: url,
                    createdAt: values?.creationDate ?? .distantPast
                )
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPermission() {
        hasScreenRecordingPermission = CGRequestScreenCaptureAccess()
        if !hasScreenRecordingPermission {
            errorMessage = "Screen capture permission is required. Enable MacScope in System Settings › Privacy & Security › Screen & System Audio Recording."
        }
    }

    func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Screenshot Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = captureFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "utility.captureFolder")
        refresh()
    }

    func chooseScrollingSegments(overlapPixels: Int, copyToClipboard: Bool) {
        guard !isStitching else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Scrolling Screenshot Segments in Top-to-Bottom Order"
        panel.prompt = "Stitch"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        let response = panel.runModal()
        guard response == .OK, panel.urls.count >= 2 else {
            if response == .OK { errorMessage = "Choose at least two image segments." }
            return
        }
        let sources = panel.urls
        let overlap = max(overlapPixels, 0)
        let folder = captureFolder
        isStitching = true
        statusMessage = "Stitching \(sources.count) scrolling segments locally…"
        Task {
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = UtilitySupport.screenshotFilename(at: Date(), prefix: "MacScope-Scrolling")
                    return try Self.stitchImages(
                        sources: sources,
                        overlapPixels: overlap,
                        destination: folder.appendingPathComponent(name)
                    )
                }.value
                refresh()
                if copyToClipboard { copy(destination) }
                statusMessage = "Saved stitched scrolling capture \(destination.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
            }
            isStitching = false
        }
    }

    func captureAutomaticScrolling(steps: Int, overlapPixels: Int, copyToClipboard: Bool) {
        guard !isStitching else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen Recording permission is required for scrolling capture."
            return
        }
        let count = min(max(steps, 2), 20)
        let overlap = max(overlapPixels, 0)
        let folder = captureFolder
        isStitching = true
        statusMessage = "In 3 seconds, switch to the target window and leave the pointer over its scrolling content."
        Task {
            do {
                for remaining in stride(from: 3, through: 1, by: -1) {
                    countdownSeconds = remaining
                    try await Task.sleep(for: .seconds(1))
                }
                countdownSeconds = 0
                guard let windowID = Self.windowUnderPointer() else {
                    throw ScreenshotFailure(message: "No other application window was found under the pointer.")
                }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MacScope-AutoScroll-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                var segments: [URL] = []
                for index in 0..<count {
                    let segment = temporary.appendingPathComponent("segment-\(index).png")
                    try Self.performWindowCapture(windowID: windowID, destination: segment)
                    segments.append(segment)
                    statusMessage = "Captured scrolling segment \(index + 1) of \(count)."
                    if index < count - 1 {
                        CGEvent(
                            scrollWheelEvent2Source: nil,
                            units: .pixel,
                            wheelCount: 1,
                            wheel1: -700,
                            wheel2: 0,
                            wheel3: 0
                        )?.post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(450))
                    }
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(
                    UtilitySupport.screenshotFilename(at: Date(), prefix: "MacScope-AutoScrolling")
                )
                _ = try await Task.detached(priority: .userInitiated) {
                    try Self.stitchImages(
                        sources: segments,
                        overlapPixels: overlap,
                        destination: destination
                    )
                }.value
                refresh()
                if copyToClipboard { copy(destination) }
                performPostCaptureAction(destination)
                statusMessage = "Saved automatic \(count)-segment scrolling capture."
            } catch let failure as ScreenshotFailure {
                errorMessage = failure.message
            } catch {
                errorMessage = error.localizedDescription
            }
            countdownSeconds = 0
            isStitching = false
        }
    }

    func capture(_ mode: ScreenshotMode, copyToClipboard: Bool, delay: Int = 0) {
        guard !isCapturing else { return }
        if !CGPreflightScreenCaptureAccess() {
            requestPermission()
            guard hasScreenRecordingPermission else { return }
        }

        isCapturing = true
        errorMessage = nil
        let now = Date()
        let folder = organizesByDate
            ? captureFolder.appendingPathComponent(Self.dateFolderName(now), isDirectory: true)
            : captureFolder
        let prefix = filenamePrefix
        let exportAt1x = exportsAt1x
        let captureScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
        Task {
            do {
                if delay > 0 {
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        countdownSeconds = remaining
                        try await Task.sleep(for: .seconds(1))
                    }
                    countdownSeconds = 0
                }
                let url = try await Task.detached(priority: .userInitiated) {
                    let url = try Self.performCapture(mode: mode, folder: folder, prefix: prefix)
                    if exportAt1x { try Self.downscaleCaptureTo1x(url, scale: captureScale) }
                    return url
                }.value
                if copyToClipboard { copy(url) }
                refresh()
                performPostCaptureAction(url)
            } catch let error as ScreenshotFailure {
                if error.message != "cancelled" { errorMessage = error.message }
            } catch {
                errorMessage = error.localizedDescription
            }
            countdownSeconds = 0
            isCapturing = false
        }
    }

    private func performPostCaptureAction(_ url: URL) {
        switch postCaptureAction {
        case .none: break
        case .previewMarkup: annotate(url)
        case .reveal: reveal(url)
        case .pin: pin(url)
        }
    }

    func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "The screenshot could not be read."
            return
        }
        NSPasteboard.general.clearContents()
        // Advertise both representations: image editors can paste pixels while
        // file-oriented tools receive the original PNG URL/path.
        let representations: [NSPasteboardWriting] = [image, url as NSURL]
        NSPasteboard.general.writeObjects(representations)
        statusMessage = "Copied PNG pixels and file reference."
    }

    func copyLatest() {
        guard let latest = captures.first else {
            statusMessage = "No recent screenshot is available."
            return
        }
        copy(latest.url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func shareTemporarily(_ captureURL: URL, hours: Int) {
        let duration = TimeInterval(min(max(hours, 1), 24) * 3_600)
        guard let data = try? Data(contentsOf: captureURL), !data.isEmpty else {
            errorMessage = "The capture could not be read for temporary sharing."
            return
        }
        for share in temporaryShares where share.captureURL == captureURL {
            temporaryShareServers.removeValue(forKey: share.id)?.stop()
        }
        temporaryShares.removeAll { $0.captureURL == captureURL }
        let id = UUID()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let server = LocalCaptureShareServer(imageData: data, token: token)
        temporaryShareServers[id] = server
        do {
            try server.start { [weak self] port in
                Task { @MainActor in
                    guard let self else { return }
                    let host = LocalCaptureShareServer.localIPv4Address() ?? "127.0.0.1"
                    guard let shareURL = URL(string: "http://\(host):\(port)/\(token).png") else { return }
                    let share = TemporaryCaptureShare(
                        id: id,
                        captureURL: captureURL,
                        shareURL: shareURL,
                        expiresAt: Date().addingTimeInterval(duration)
                    )
                    self.temporaryShares.removeAll { $0.captureURL == captureURL }
                    self.temporaryShares.append(share)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
                    self.statusMessage = "Temporary local-network link copied. It expires in \(hours) hour\(hours == 1 ? "" : "s")."
                    Task {
                        try? await Task.sleep(for: .seconds(duration))
                        guard !Task.isCancelled else { return }
                        self.stopTemporaryShare(id)
                    }
                }
            }
        } catch {
            temporaryShareServers[id] = nil
            errorMessage = error.localizedDescription
        }
    }

    func copyTemporaryShare(_ share: TemporaryCaptureShare) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(share.shareURL.absoluteString, forType: .string)
        statusMessage = "Temporary link copied."
    }

    func stopTemporaryShare(_ id: UUID) {
        guard temporaryShareServers[id] != nil || temporaryShares.contains(where: { $0.id == id }) else { return }
        temporaryShareServers.removeValue(forKey: id)?.stop()
        temporaryShares.removeAll { $0.id == id }
        statusMessage = "Temporary capture link revoked."
    }

    func annotate(_ url: URL) {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        guard FileManager.default.fileExists(atPath: preview.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: preview,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func pin(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "The screenshot could not be pinned because it could not be decoded."
            return
        }
        let identifier = UUID()
        let aspect = max(image.size.width / max(image.size.height, 1), 0.2)
        let width = min(max(image.size.width, 320), 720)
        let height = min(max(width / aspect, 220), 620)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = url.lastPathComponent
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 220, height: 140)
        panel.contentAspectRatio = image.size
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        panel.contentView = imageView
        panel.center()
        pinnedPanels[identifier] = panel
        pinnedPanelObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if let observer = self?.pinnedPanelObservers.removeValue(forKey: identifier) {
                    NotificationCenter.default.removeObserver(observer)
                }
                self?.pinnedPanels.removeValue(forKey: identifier)
            }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openCaptureFolder() {
        NSWorkspace.shared.open(captureFolder)
    }

    func delete(_ record: ScreenshotRecord) {
        for share in temporaryShares where share.captureURL == record.url {
            temporaryShareServers.removeValue(forKey: share.id)?.stop()
        }
        temporaryShares.removeAll { $0.captureURL == record.url }
        NSWorkspace.shared.recycle([record.url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.errorMessage = error.localizedDescription }
                self?.refresh()
            }
        }
    }

    nonisolated static func performCapture(
        mode: ScreenshotMode,
        folder: URL,
        prefix: String = "MacScope"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(
            UtilitySupport.screenshotFilename(at: Date(), prefix: prefix)
        )
        var arguments = ["-x"]
        switch mode {
        case .fullScreen:
            break
        case .window:
            arguments += ["-i", "-w"]
        case .selection:
            arguments += ["-i", "-s"]
        }
        arguments.append(destination.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw ScreenshotFailure(message: process.terminationStatus == 1 ? "cancelled" : "Screenshot capture failed.")
        }
        return destination
    }

    nonisolated private static func performWindowCapture(windowID: CGWindowID, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(windowID), destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw ScreenshotFailure(message: "The scrolling window could not be captured.")
        }
    }

    nonisolated private static func windowUnderPointer() -> CGWindowID? {
        let point = CGEvent(source: nil)?.location ?? .zero
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.first { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return bounds.contains(point)
        }?[kCGWindowNumber as String] as? CGWindowID
    }

    nonisolated static func stitchImages(
        sources: [URL],
        overlapPixels: Int,
        destination: URL
    ) throws -> URL {
        let representations = try sources.map { url -> NSBitmapImageRep in
            guard let image = NSImage(contentsOf: url),
                  let data = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: data),
                  representation.pixelsWide > 0,
                  representation.pixelsHigh > 0 else {
                throw ScreenshotFailure(message: "\(url.lastPathComponent) could not be decoded as an image segment.")
            }
            return representation
        }
        guard representations.count >= 2 else {
            throw ScreenshotFailure(message: "At least two image segments are required.")
        }
        let targetWidth = representations.map(\.pixelsWide).min() ?? 1
        let scaledHeights = representations.map { representation in
            max(Int((Double(representation.pixelsHigh) * Double(targetWidth) / Double(representation.pixelsWide)).rounded()), 1)
        }
        let overlap = min(
            max(overlapPixels, 0),
            max((scaledHeights.min() ?? 1) - 1, 0)
        )
        let outputHeight = scaledHeights.reduce(0, +) - overlap * (representations.count - 1)
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: outputHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ScreenshotFailure(message: "The stitched screenshot bitmap could not be allocated.")
        }
        output.size = NSSize(width: targetWidth, height: outputHeight)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: targetWidth, height: outputHeight)).fill()
        var cursor = outputHeight
        for (index, representation) in representations.enumerated() {
            let height = scaledHeights[index]
            cursor -= height
            let image = NSImage(size: NSSize(width: representation.pixelsWide, height: representation.pixelsHigh))
            image.addRepresentation(representation)
            image.draw(
                in: NSRect(x: 0, y: cursor, width: targetWidth, height: height),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            if index < representations.count - 1 { cursor += overlap }
        }
        guard let png = output.representation(using: .png, properties: [:]) else {
            throw ScreenshotFailure(message: "The stitched screenshot could not be encoded as PNG.")
        }
        try png.write(to: destination, options: .atomic)
        return destination
    }

    nonisolated static func downscaleCaptureTo1x(_ url: URL, scale: CGFloat) throws {
        guard scale > 1,
              let source = NSBitmapImageRep(data: try Data(contentsOf: url)) else { return }
        let width = max(Int((Double(source.pixelsWide) / scale).rounded()), 1)
        let height = max(Int((Double(source.pixelsHigh) / scale).rounded()), 1)
        guard let output = NSBitmapImageRep(
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
        ) else { throw ScreenshotFailure(message: "The 1x screenshot bitmap could not be created.") }
        output.size = NSSize(width: width, height: height)
        guard let image = NSImage(contentsOf: url) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = output.representation(using: .png, properties: [:]) else {
            throw ScreenshotFailure(message: "The 1x screenshot could not be encoded.")
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated private static func dateFolderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

final class LocalCaptureShareServer: @unchecked Sendable {
    private let imageData: Data
    private let token: String
    private let queue = DispatchQueue(label: "local.taskmanager.MacScope.capture-share")
    private var listener: NWListener?

    init(imageData: Data, token: String) {
        self.imageData = imageData
        self.token = token
    }

    func start(onReady: @escaping @Sendable (UInt16) -> Void) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { onReady(port) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] request, _, _, _ in
            guard let self else { connection.cancel(); return }
            let line = request.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let valid = line.hasPrefix("GET /\(self.token).png ") || line.hasPrefix("HEAD /\(self.token).png ")
            let body = valid && line.hasPrefix("GET ") ? self.imageData : Data()
            let status = valid ? "200 OK" : "404 Not Found"
            let length = valid ? self.imageData.count : 0
            let headers = "HTTP/1.1 \(status)\r\nContent-Type: image/png\r\nContent-Length: \(length)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: String?
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" || name == "en1" { return value }
            fallback = fallback ?? value
        }
        return fallback
    }
}

struct ClipboardHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let text: String
    let fileURLs: [URL]
    let imageData: Data?
    let capturedAt: Date

    var summary: String {
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        if !fileURLs.isEmpty { return fileURLs.map(\.lastPathComponent).joined(separator: ", ") }
        if imageData != nil { return "Copied image" }
        return "Clipboard item"
    }
}

struct SavedSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var text: String
    var trigger: String?
    var folder: String?
    let createdAt: Date
}

struct ShelfItem: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

struct ShelfTextItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let createdAt: Date

    var link: URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var summary: String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 100 ? String(singleLine.prefix(100)) + "…" : singleLine
    }
}

struct ScratchpadTab: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var text: String
}

@MainActor
@Observable
final class ScratchpadService {
    private(set) var tabs: [ScratchpadTab] = []
    private(set) var statusMessage: String?
    private(set) var autoClearInterval: TimeInterval?
    private let defaultsKey = "utility.scratchpadTabs"
    private let autoClearKey = "utility.scratchpadAutoClearInterval"
    private var clearTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ScratchpadTab].self, from: data),
           !decoded.isEmpty {
            tabs = decoded
        } else {
            tabs = [ScratchpadTab(id: UUID(), name: "Notes", text: "")]
        }
        let savedInterval = UserDefaults.standard.double(forKey: autoClearKey)
        autoClearInterval = savedInterval > 0 ? savedInterval : nil
        for tab in tabs where !tab.text.isEmpty { scheduleAutoClear(tab.id) }
    }

    func addTab() -> UUID {
        let tab = ScratchpadTab(id: UUID(), name: "Pad \(tabs.count + 1)", text: "")
        tabs.append(tab)
        persist()
        return tab.id
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].name = trimmed.isEmpty ? "Untitled" : trimmed
        persist()
    }

    func updateText(_ id: UUID, text: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].text = text
        persist()
        scheduleAutoClear(id)
    }

    func clear(_ id: UUID) { updateText(id, text: "") }

    func delete(_ id: UUID) {
        guard tabs.count > 1 else {
            clear(id)
            statusMessage = "The last pad was cleared instead of removed."
            return
        }
        tabs.removeAll { $0.id == id }
        clearTasks[id]?.cancel()
        clearTasks[id] = nil
        persist()
    }

    func setAutoClear(after interval: TimeInterval?) {
        autoClearInterval = interval
        if let interval { UserDefaults.standard.set(interval, forKey: autoClearKey) }
        else { UserDefaults.standard.removeObject(forKey: autoClearKey) }
        clearTasks.values.forEach { $0.cancel() }
        clearTasks.removeAll()
        if interval != nil {
            for tab in tabs where !tab.text.isEmpty { scheduleAutoClear(tab.id) }
            statusMessage = "Scratchpads will clear after the selected quiet period."
        } else {
            statusMessage = "Automatic scratchpad clearing is off."
        }
    }

    func copy(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.text, forType: .string)
        statusMessage = "Copied \(tab.name)."
    }

    func export(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Scratchpad"
        panel.nameFieldStringValue = "\(tab.name).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try tab.text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(tab.name)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func scheduleAutoClear(_ id: UUID) {
        clearTasks[id]?.cancel()
        clearTasks[id] = nil
        guard let autoClearInterval,
              tabs.first(where: { $0.id == id })?.text.isEmpty == false else { return }
        clearTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(autoClearInterval))
            guard !Task.isCancelled, let self else { return }
            self.clearTasks[id] = nil
            self.clear(id)
            self.statusMessage = "Cleared an inactive scratchpad."
        }
    }
}

@MainActor
@Observable
final class SnippetShelfService {
    private(set) var snippets: [SavedSnippet] = []
    private(set) var shelfItems: [ShelfItem] = []
    private(set) var shelfTextItems: [ShelfTextItem] = []
    private(set) var statusMessage: String?
    private(set) var destinationFolder: URL?
    private(set) var isExpansionEnabled = false
    private(set) var expansionError: String?
    private(set) var isInstallingDiskImage = false
    private let snippetsKey = "utility.savedSnippets"
    private let finderDestinationProvider: @MainActor () -> URL?
    private var expansionEngine: TextExpansionEngine?

    init(
        finderDestinationProvider: @escaping @MainActor () -> URL?
            = SnippetShelfService.currentFinderDestination
    ) {
        self.finderDestinationProvider = finderDestinationProvider
        load()
        if UserDefaults.standard.bool(forKey: "utility.textExpansionEnabled") {
            setExpansionEnabled(true, requestPermission: false)
        }
    }

    func saveSnippet(title: String, text: String, trigger: String? = nil, folder: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter snippet text first."
            return
        }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTrigger = Self.normalizedTrigger(trigger)
        let resolvedFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedTrigger,
           snippets.contains(where: { $0.trigger == resolvedTrigger }) {
            statusMessage = "That expansion trigger is already in use."
            return
        }
        snippets.insert(SavedSnippet(
            id: UUID(),
            title: resolvedTitle.isEmpty ? UtilitySupport.snippetTitle(for: trimmed) : resolvedTitle,
            text: trimmed,
            trigger: resolvedTrigger,
            folder: resolvedFolder.flatMap { $0.isEmpty ? nil : String($0.prefix(48)) },
            createdAt: Date()
        ), at: 0)
        persist()
        refreshExpansionEngine()
        statusMessage = "Snippet saved locally."
    }

    func saveClipboardAsSnippet() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            statusMessage = "The clipboard does not contain text."
            return
        }
        saveSnippet(title: "", text: text)
    }

    func copy(_ snippet: SavedSnippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.text, forType: .string)
        statusMessage = "Copied \(snippet.title)."
    }

    func delete(_ snippet: SavedSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
        refreshExpansionEngine()
        statusMessage = "Snippet removed."
    }

    func setExpansionEnabled(_ enabled: Bool, requestPermission: Bool = true) {
        if !enabled {
            expansionEngine?.stop()
            expansionEngine = nil
            isExpansionEnabled = false
            expansionError = nil
            UserDefaults.standard.set(false, forKey: "utility.textExpansionEnabled")
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            expansionError = "Text expansion needs Accessibility and Input Monitoring permission."
            if requestPermission { _ = CGRequestListenEventAccess() }
            return
        }
        let engine = TextExpansionEngine(replacements: expansionReplacements)
        guard engine.start() else {
            expansionError = "The text expansion keyboard filter could not start."
            return
        }
        expansionEngine = engine
        isExpansionEnabled = true
        expansionError = nil
        UserDefaults.standard.set(true, forKey: "utility.textExpansionEnabled")
    }

    func addShelfItems() {
        let panel = NSOpenPanel()
        panel.title = "Add Files to MacScope Shelf"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addShelfItems(panel.urls)
    }

    func addShelfItems(_ urls: [URL]) {
        let resolved = urls.map(\.standardizedFileURL).filter { $0.isFileURL }
        let existing = Set(shelfItems.map(\.url))
        let additions = resolved.filter { !existing.contains($0) }
        shelfItems.append(contentsOf: additions.map(ShelfItem.init))
        statusMessage = "Added \(additions.count) shelf item\(additions.count == 1 ? "" : "s")."
    }

    var destinationDisplayName: String {
        destinationFolder?.lastPathComponent ?? "Finder destination"
    }

    @discardableResult
    func captureFrontmostFinderDestination() -> URL? {
        guard let url = finderDestinationProvider() else { return nil }
        destinationFolder = url.standardizedFileURL
        return destinationFolder
    }

    private static func currentFinderDestination() -> URL? {
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.finder"
              ).first else { return nil }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedWindowStatus = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        if focusedWindowStatus != .success || focusedValue == nil {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
               let windows = windowsValue as? [AXUIElement] {
                focusedValue = windows.first
            }
        }
        guard let focusedValue else {
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
                ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                : nil
        }
        let window = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var documentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXDocumentAttribute as CFString,
            &documentValue
        ) == .success, let documentValue else { return nil }

        let url: URL?
        if let value = documentValue as? URL {
            url = value
        } else if let value = documentValue as? String {
            url = value.hasPrefix("file:")
                ? URL(string: value)
                : URL(fileURLWithPath: value, isDirectory: true)
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }

    func moveShelfItemsToCurrentFinderFolder() {
        guard !shelfItems.isEmpty else {
            statusMessage = "The shelf has no files or folders to move."
            return
        }
        guard let destination = captureFrontmostFinderDestination() else {
            chooseShelfDestinationAndMove()
            return
        }
        moveShelfItems(to: destination)
    }

    func chooseShelfDestinationAndMove() {
        guard !shelfItems.isEmpty else {
            statusMessage = "The shelf has no files or folders to move."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Move Shelf Items"
        panel.message = "Choose the destination folder for \(shelfItems.count) parked item\(shelfItems.count == 1 ? "" : "s")."
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else {
            statusMessage = "Move cancelled. Shelf items are still parked."
            return
        }
        destinationFolder = destination.standardizedFileURL
        moveShelfItems(to: destination)
    }

    func moveShelfItems(to destination: URL) {
        guard !shelfItems.isEmpty else {
            statusMessage = "The shelf has no files or folders to move."
            return
        }
        let fileManager = FileManager.default
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedDestination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            statusMessage = "The Finder destination is no longer available."
            return
        }

        var movedIDs = Set<URL>()
        var movedCount = 0
        var alreadyThereCount = 0
        var conflictCount = 0
        var failedCount = 0
        for item in shelfItems {
            let source = item.url.standardizedFileURL.resolvingSymlinksInPath()
            let sourceParent = source.deletingLastPathComponent()
            if sourceParent == resolvedDestination {
                movedIDs.insert(item.id)
                alreadyThereCount += 1
                continue
            }
            let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if sourceIsDirectory,
               resolvedDestination.path.hasPrefix(source.path + "/") {
                failedCount += 1
                continue
            }
            let target = resolvedDestination.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: sourceIsDirectory
            )
            guard !fileManager.fileExists(atPath: target.path) else {
                conflictCount += 1
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                movedIDs.insert(item.id)
                movedCount += 1
            } catch {
                failedCount += 1
            }
        }
        shelfItems.removeAll { movedIDs.contains($0.id) }

        var results: [String] = []
        if movedCount > 0 { results.append("Moved \(movedCount)") }
        if alreadyThereCount > 0 { results.append("\(alreadyThereCount) already there") }
        if conflictCount > 0 { results.append("\(conflictCount) name conflict\(conflictCount == 1 ? "" : "s") kept on shelf") }
        if failedCount > 0 { results.append("\(failedCount) failed and kept on shelf") }
        statusMessage = results.isEmpty
            ? "Nothing was moved."
            : results.joined(separator: "; ") + "."
    }

    func addClipboardTextToShelf() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            statusMessage = "The clipboard does not contain text or a link."
            return
        }
        addShelfText(text)
    }

    func addShelfText(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !shelfTextItems.contains(where: { $0.text == text }) else {
            statusMessage = "That clipboard text is already on the shelf."
            return
        }
        shelfTextItems.insert(ShelfTextItem(text: String(text.prefix(20_000)), createdAt: Date()), at: 0)
        statusMessage = URL(string: text)?.scheme?.hasPrefix("http") == true
            ? "Added clipboard link to the session shelf."
            : "Added clipboard text to the session shelf."
    }

    func copy(_ item: ShelfTextItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        statusMessage = "Shelf text copied."
    }

    func open(_ item: ShelfTextItem) {
        guard let link = item.link else { return }
        NSWorkspace.shared.open(link)
    }

    func remove(_ item: ShelfTextItem) {
        shelfTextItems.removeAll { $0.id == item.id }
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }

    func installDiskImage(_ item: ShelfItem) {
        guard item.url.pathExtension.lowercased() == "dmg", !isInstallingDiskImage else { return }
        let alert = NSAlert()
        alert.messageText = "Install app from disk image?"
        alert.informativeText = "MacScope will mount \(item.url.lastPathComponent) read-only, require exactly one app, copy it to your user Applications folder, eject the image, then move the DMG to Trash."
        alert.addButton(withTitle: "Install App")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isInstallingDiskImage = true
        statusMessage = "Inspecting disk image…"
        Task {
            do {
                let installed = try await Task.detached(priority: .userInitiated) {
                    try Self.installApplication(from: item.url)
                }.value
                NSWorkspace.shared.recycle([item.url]) { [weak self] _, error in
                    Task { @MainActor in
                        self?.shelfItems.removeAll { $0.id == item.id }
                        self?.statusMessage = error == nil
                            ? "Installed \(installed.lastPathComponent) and moved the disk image to Trash."
                            : "Installed \(installed.lastPathComponent), but the disk image could not be moved to Trash."
                    }
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isInstallingDiskImage = false
        }
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: ShelfItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path(percentEncoded: false), forType: .string)
        statusMessage = "Path copied."
    }

    func remove(_ item: ShelfItem) {
        shelfItems.removeAll { $0.id == item.id }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: snippetsKey),
              let decoded = try? JSONDecoder().decode([SavedSnippet].self, from: data) else { return }
        snippets = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: snippetsKey)
    }

    private var expansionReplacements: [String: String] {
        snippets.reduce(into: [String: String]()) { replacements, snippet in
            if let trigger = snippet.trigger { replacements[trigger] = snippet.text }
        }
    }

    private func refreshExpansionEngine() {
        expansionEngine?.replacements = expansionReplacements
    }

    private static func normalizedTrigger(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !trimmed.contains(where: \Character.isWhitespace) else { return nil }
        return String(trimmed.prefix(32))
    }

    nonisolated private static func installApplication(from diskImage: URL) throws -> URL {
        let attach = try runProcess(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-readonly", "-nobrowse", "-plist", diskImage.path]
        )
        guard let plist = try PropertyListSerialization.propertyList(from: attach, format: nil)
                as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw NSError(domain: "MacScope.DiskImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "The mounted disk image did not return a readable mount description."])
        }
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !mountPoints.isEmpty else {
            throw NSError(domain: "MacScope.DiskImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "The disk image did not expose a mounted volume."])
        }
        defer {
            for mountPoint in mountPoints {
                _ = try? runProcess(
                    URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["detach", mountPoint.path]
                )
            }
        }
        let applications = mountPoints.flatMap { mount -> [URL] in
            (try? FileManager.default.contentsOfDirectory(
                at: mount,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension.lowercased() == "app" } ?? []
        }
        guard applications.count == 1, let application = applications.first else {
            throw NSError(
                domain: "MacScope.DiskImage", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Installation requires a disk image containing exactly one top-level app; found \(applications.count)."]
            )
        }
        let applicationsFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationsFolder, withIntermediateDirectories: true)
        let destination = applicationsFolder.appendingPathComponent(application.lastPathComponent, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "MacScope.DiskImage", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(application.lastPathComponent) already exists in your Applications folder."]
            )
        }
        try FileManager.default.copyItem(at: application, to: destination)
        return destination
    }

    nonisolated private static func runProcess(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = (String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MacScope.DiskImage", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "The disk image operation failed." : detail]
            )
        }
        return data
    }
}

@MainActor
@Observable
final class ClipboardHistoryService {
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var pinnedEntries: [ClipboardHistoryEntry] = []
    private(set) var isEnabled = false
    private(set) var statusMessage: String?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var clearTask: Task<Void, Never>?
    private(set) var clearsAt: Date?
    private(set) var clearOnSystemSleep = false
    private(set) var clearOnDisplaySleep = false
    private(set) var clearOnScreenLock = false
    private(set) var automaticallyCleansURLs = false
    var customTrackingParameters = "" {
        didSet { UserDefaults.standard.set(customTrackingParameters, forKey: "utility.customTrackingParameters") }
    }
    private var eventObservers: [NSObjectProtocol] = []
    private let pinnedKey = "utility.clipboardPinnedEntries"

    init() {
        guard let data = UserDefaults.standard.data(forKey: pinnedKey),
              let decoded = try? JSONDecoder().decode([ClipboardHistoryEntry].self, from: data) else { return }
        pinnedEntries = decoded
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.clipboardHistoryEnabled")
        if enabled { startPolling() }
        else { stopPolling() }
    }

    func restorePreference() {
        setEnabled(UserDefaults.standard.bool(forKey: "utility.clipboardHistoryEnabled"))
        clearOnSystemSleep = UserDefaults.standard.bool(forKey: "utility.clipboardClearOnSystemSleep")
        clearOnDisplaySleep = UserDefaults.standard.bool(forKey: "utility.clipboardClearOnDisplaySleep")
        clearOnScreenLock = UserDefaults.standard.bool(forKey: "utility.clipboardClearOnScreenLock")
        automaticallyCleansURLs = UserDefaults.standard.bool(forKey: "utility.automaticallyCleansURLs")
        customTrackingParameters = UserDefaults.standard.string(forKey: "utility.customTrackingParameters") ?? ""
        installEventObserversIfNeeded()
    }

    func setClearOnSystemSleep(_ enabled: Bool) {
        clearOnSystemSleep = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.clipboardClearOnSystemSleep")
        installEventObserversIfNeeded()
    }

    func setClearOnDisplaySleep(_ enabled: Bool) {
        clearOnDisplaySleep = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.clipboardClearOnDisplaySleep")
        installEventObserversIfNeeded()
    }

    func setClearOnScreenLock(_ enabled: Bool) {
        clearOnScreenLock = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.clipboardClearOnScreenLock")
        installEventObserversIfNeeded()
    }

    func setAutomaticallyCleansURLs(_ enabled: Bool) {
        automaticallyCleansURLs = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.automaticallyCleansURLs")
    }

    func clear() {
        entries.removeAll()
        statusMessage = "Session history cleared."
    }

    func pin(_ entry: ClipboardHistoryEntry) {
        guard !pinnedEntries.contains(where: { Self.sameContent($0, entry) }) else {
            statusMessage = "This clipboard item is already pinned."
            return
        }
        pinnedEntries.insert(entry, at: 0)
        persistPinnedEntries()
        statusMessage = "Pinned clipboard favorite."
    }

    func unpin(_ entry: ClipboardHistoryEntry) {
        pinnedEntries.removeAll { $0.id == entry.id }
        persistPinnedEntries()
        statusMessage = "Removed pinned clipboard favorite."
    }

    func copy(_ entry: ClipboardHistoryEntry) {
        NSPasteboard.general.clearContents()
        if !entry.fileURLs.isEmpty {
            NSPasteboard.general.writeObjects(entry.fileURLs as [NSURL])
        } else if let imageData = entry.imageData, let image = NSImage(data: imageData) {
            NSPasteboard.general.writeObjects([image])
        } else {
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        lastChangeCount = NSPasteboard.general.changeCount
        statusMessage = entry.fileURLs.isEmpty && entry.imageData == nil
            ? "Copied as plain text." : "Clipboard item restored."
    }

    func cleanCurrentURL() {
        guard let source = NSPasteboard.general.string(forType: .string),
              let cleaned = UtilitySupport.cleanedTrackingURL(
                source,
                additionalParameters: customParameterSet
              ) else {
            statusMessage = "The clipboard does not contain a valid web URL."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleaned, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
        statusMessage = cleaned == source ? "No known tracking parameters found." : "Clean URL copied."
    }

    func scheduleClipboardClear(after duration: TimeInterval?) {
        clearTask?.cancel()
        clearTask = nil
        clearsAt = nil
        guard let duration else {
            statusMessage = "Automatic clipboard clearing cancelled."
            return
        }
        clearsAt = Date().addingTimeInterval(duration)
        statusMessage = "Clipboard will clear in \(Int(duration / 60)) minute\(duration == 60 ? "" : "s")."
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSPasteboard.general.clearContents()
            self?.lastChangeCount = NSPasteboard.general.changeCount
            self?.clearsAt = nil
            self?.statusMessage = "Clipboard cleared automatically."
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let files = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let imageData = pasteboard.data(forType: .tiff)
        var text = pasteboard.string(forType: .string) ?? ""
        if files.isEmpty, imageData == nil, automaticallyCleansURLs,
           let cleaned = UtilitySupport.cleanedTrackingURL(
               text,
               additionalParameters: customParameterSet
           ), cleaned != text {
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)
            lastChangeCount = pasteboard.changeCount
            text = cleaned
            statusMessage = "Tracking parameters removed automatically."
        }
        guard !files.isEmpty || imageData != nil || !text.isEmpty else { return }
        let entry = ClipboardHistoryEntry(
            id: UUID(),
            text: files.isEmpty && imageData == nil ? text : "",
            fileURLs: files,
            imageData: files.isEmpty ? imageData : nil,
            capturedAt: Date()
        )
        guard entries.first.map({ $0.text != entry.text || $0.fileURLs != entry.fileURLs || $0.imageData != entry.imageData }) ?? true else { return }
        entries.insert(entry, at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
    }

    private var customParameterSet: Set<String> {
        Set(customTrackingParameters
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased() })
    }

    private func persistPinnedEntries() {
        guard let data = try? JSONEncoder().encode(pinnedEntries) else { return }
        UserDefaults.standard.set(data, forKey: pinnedKey)
    }

    private static func sameContent(_ lhs: ClipboardHistoryEntry, _ rhs: ClipboardHistoryEntry) -> Bool {
        lhs.text == rhs.text && lhs.fileURLs == rhs.fileURLs && lhs.imageData == rhs.imageData
    }

    private func installEventObserversIfNeeded() {
        guard eventObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, @MainActor (ClipboardHistoryService) -> Bool)] = [
            (NSWorkspace.willSleepNotification, { $0.clearOnSystemSleep }),
            (NSWorkspace.screensDidSleepNotification, { $0.clearOnDisplaySleep }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.clearOnScreenLock })
        ]
        for (name, shouldClear) in events {
            eventObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, shouldClear(self) else { return }
                    NSPasteboard.general.clearContents()
                    self.lastChangeCount = NSPasteboard.general.changeCount
                    self.statusMessage = "Clipboard cleared for privacy."
                }
            })
        }
    }
}

@MainActor
@Observable
final class KeepAwakeService {
    private(set) var isActive = false
    private(set) var includesDisplay = false
    private(set) var endsAt: Date?
    private(set) var errorMessage: String?
    private var assertionID = IOPMAssertionID(0)
    private var timer: Timer?
    private var automationTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var automationStartedAssertion = false
    private(set) var startsOnACPower = false
    private(set) var startsWithExternalDisplay = false

    func start(duration: TimeInterval?, includesDisplay: Bool) {
        stop()
        let assertionType = includesDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacScope keep-awake utility" as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else {
            errorMessage = "Unable to create a power assertion (IOReturn \(result))."
            return
        }
        assertionID = identifier
        self.includesDisplay = includesDisplay
        isActive = true
        errorMessage = nil
        endsAt = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        assertionID = 0
        isActive = false
        endsAt = nil
    }

    func restoreAutomations() {
        startsOnACPower = UserDefaults.standard.bool(forKey: "utility.keepAwakeOnACPower")
        startsWithExternalDisplay = UserDefaults.standard.bool(forKey: "utility.keepAwakeWithExternalDisplay")
        installAutomationObservers()
        evaluateAutomations()
    }

    func setStartsOnACPower(_ enabled: Bool) {
        startsOnACPower = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.keepAwakeOnACPower")
        installAutomationObservers()
        evaluateAutomations()
    }

    func setStartsWithExternalDisplay(_ enabled: Bool) {
        startsWithExternalDisplay = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.keepAwakeWithExternalDisplay")
        installAutomationObservers()
        evaluateAutomations()
    }

    private func installAutomationObservers() {
        guard automationTimer == nil else { return }
        automationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutomations() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutomations() }
        }
    }

    private func evaluateAutomations() {
        let shouldRun = (startsOnACPower && Self.isUsingACPower())
            || (startsWithExternalDisplay && NSScreen.screens.count > 1)
        if shouldRun, !isActive {
            start(duration: nil, includesDisplay: false)
            automationStartedAssertion = isActive
        } else if !shouldRun, automationStartedAssertion {
            automationStartedAssertion = false
            stop()
        }
    }

    private static func isUsingACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (source as String) == (kIOPSACPowerValue as String)
    }
}

@MainActor
@Observable
final class CleaningModeService {
    private(set) var isActive = false
    private(set) var endsAt: Date?
    private(set) var errorMessage: String?
    private var panels: [NSPanel] = []
    private var timer: Timer?
    private var blocker: CleaningInputBlocker?

    func start(duration: TimeInterval) {
        guard !isActive else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            errorMessage = "Cleaning Mode needs Accessibility and Input Monitoring permission."
            _ = CGRequestListenEventAccess()
            return
        }
        let blocker = CleaningInputBlocker(owner: self)
        guard blocker.start() else {
            errorMessage = "Cleaning Mode could not secure the keyboard and pointer."
            return
        }
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let label = NSTextField(labelWithString: "Cleaning Mode · Press Escape to finish")
            label.textColor = NSColor.white.withAlphaComponent(0.45)
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 32, width: screen.frame.width, height: 30)
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            content.addSubview(label)
            panel.contentView = content
            panel.orderFrontRegardless()
            return panel
        }
        self.blocker = blocker
        isActive = true
        endsAt = Date().addingTimeInterval(duration)
        errorMessage = nil
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        blocker?.stop()
        blocker = nil
        timer?.invalidate()
        timer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        isActive = false
        endsAt = nil
    }
}

private final class CleaningInputBlocker: @unchecked Sendable {
    private weak var owner: CleaningModeService?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(owner: CleaningModeService) { self.owner = owner }

    func start() -> Bool {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cleaningInputCallback,
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
            return nil
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            Task { @MainActor [weak owner] in owner?.stop() }
        }
        return nil
    }
}

private func cleaningInputCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<CleaningInputBlocker>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .handle(type: type, event: event)
}

struct DisplayControlItem: Identifiable, Equatable {
    let id: UInt64
    let name: String
    var brightness: Double?
}

struct SoftwareDisplayControlItem: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    var level: Double
}

@MainActor
@Observable
final class DisplayControlService {
    private(set) var displays: [DisplayControlItem] = []
    private(set) var softwareDisplays: [SoftwareDisplayControlItem] = []
    private(set) var statusMessage: String?
    @ObservationIgnored private var services: [UInt64: io_service_t] = [:]
    @ObservationIgnored private var hasSoftwareAdjustment = false

    deinit {
        if hasSoftwareAdjustment { CGDisplayRestoreColorSyncSettings() }
    }

    func refresh() {
        services.values.forEach { _ = IOObjectRelease($0) }
        services.removeAll()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else {
            displays = []
            statusMessage = "Display controls could not be enumerated."
            return
        }
        defer { IOObjectRelease(iterator) }
        var result: [DisplayControlItem] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let registryID: UInt64 = {
                var value: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &value)
                return value
            }()
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as NSDictionary
            let names = info[kDisplayProductName] as? [String: String]
            let name = names?.values.first ?? "Display \(result.count + 1)"
            var value: Float = 0
            let readable = IODisplayGetFloatParameter(
                service, IOOptionBits(0), kIODisplayBrightnessKey as CFString, &value
            ) == kIOReturnSuccess
            services[registryID] = service
            result.append(DisplayControlItem(
                id: registryID,
                name: name,
                brightness: readable ? Double(value) : nil
            ))
        }
        displays = result
        refreshSoftwareDisplays()
        statusMessage = result.isEmpty ? "No controllable display services were found." : nil
    }

    func setBrightness(_ brightness: Double, for item: DisplayControlItem) {
        guard let service = services[item.id] else { return }
        let value = Float(min(max(brightness, 0), 1))
        let result = IODisplaySetFloatParameter(
            service, IOOptionBits(0), kIODisplayBrightnessKey as CFString, value
        )
        if result == kIOReturnSuccess {
            if let index = displays.firstIndex(where: { $0.id == item.id }) {
                displays[index].brightness = Double(value)
            }
            statusMessage = nil
        } else {
            statusMessage = "\(item.name) does not accept software brightness changes."
        }
    }

    func setSoftwareLevel(_ level: Double, for item: SoftwareDisplayControlItem) {
        let clamped = min(max(level, 0.1), 1)
        let result = CGSetDisplayTransferByFormula(
            item.id,
            0, Float(clamped), 1,
            0, Float(clamped), 1,
            0, Float(clamped), 1
        )
        guard result == .success else {
            statusMessage = "macOS could not apply software dimming to \(item.name) (CGError \(result.rawValue))."
            return
        }
        if let index = softwareDisplays.firstIndex(where: { $0.id == item.id }) {
            softwareDisplays[index].level = clamped
        }
        hasSoftwareAdjustment = softwareDisplays.contains { $0.level < 0.999 }
        statusMessage = clamped < 0.999
            ? "Software dimming is active on \(item.name)."
            : nil
    }

    func restoreSoftwareDimming() {
        CGDisplayRestoreColorSyncSettings()
        for index in softwareDisplays.indices { softwareDisplays[index].level = 1 }
        hasSoftwareAdjustment = false
        statusMessage = "Restored ColorSync output on every display."
    }

    private func refreshSoftwareDisplays() {
        let oldLevels = Dictionary(uniqueKeysWithValues: softwareDisplays.map { ($0.id, $0.level) })
        softwareDisplays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let identifier = CGDirectDisplayID(number.uint32Value)
            return SoftwareDisplayControlItem(
                id: identifier,
                name: screen.localizedName,
                level: oldLevels[identifier] ?? 1
            )
        }
    }
}
