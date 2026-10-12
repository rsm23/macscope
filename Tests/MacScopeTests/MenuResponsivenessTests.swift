import AppKit
import Foundation
import Observation
import Testing
@testable import MacScope

@Suite("Menu responsiveness", .serialized)
struct MenuResponsivenessTests {
    @Test("A telemetry tick does not rebuild the application's scenes and menus") @MainActor
    func liveReadoutDoesNotInvalidateScenes() {
        let model = AppModel(
            alertNotifications: UsageAlertNotificationController(center: nil), startsUtilityServer: false
        )
        let application = MacScopeApp(model: model)
        let changes = MenuReadCounter()
        let readoutChanges = MenuReadCounter()
        withObservationTracking {
            _ = application.body
        } onChange: {
            changes.increment()
        }
        withObservationTracking {
            _ = LiveMenuBarStatusLabel(model: model).body
        } onChange: {
            readoutChanges.increment()
        }

        model.menuBarPresentation = MenuBarPresentation()

        #expect(changes.value == 0)
        #expect(readoutChanges.value == 1)
    }

    @Test("Refreshing the screenshot library does not block menus") @MainActor
    func slowScreenshotScanDoesNotBlockMenus() async throws {
        let reads = MenuReadCounter()
        let record = ScreenshotRecord(url: URL(fileURLWithPath: "/tmp/worker.png"), createdAt: .distantPast)
        let service = ScreenshotService(captureScanner: { _ in
            reads.increment()
            Thread.sleep(forTimeInterval: 0.3)
            return Thread.isMainThread ? [] : [record]
        })
        let start = ContinuousClock.now

        service.refresh()

        #expect(start.duration(to: .now) < .milliseconds(100))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.captures.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.captures == [record])
        #expect(reads.value == 1)
    }

    @Test("Screenshot discovery still finds nested PNGs and excludes unrelated files") @MainActor
    func discoversRealCaptureLibrary() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let nested = folder.appendingPathComponent("dated")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.png")
        let second = nested.appendingPathComponent("second.PNG")
        for url in [first, second, folder.appendingPathComponent("notes.txt"), folder.appendingPathComponent(".hidden.png")] {
            try Data().write(to: url)
        }
        let service = ScreenshotService()
        service.refresh(in: folder)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.captures.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let discovered = Set(service.captures.map { $0.url.resolvingSymlinksInPath() })
        let expected = Set([first, second].map { $0.resolvingSymlinksInPath() })
        #expect(discovered == expected)
        #expect(service.captures.map(\.createdAt) == service.captures.map(\.createdAt).sorted(by: >))
    }

    @Test("An old screenshot scan cannot overwrite a newer refresh") @MainActor
    func latestCaptureRefreshWins() async throws {
        let reads = MenuReadCounter()
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")
        let service = ScreenshotService(captureScanner: { folder in
            reads.increment()
            if folder == first { Thread.sleep(forTimeInterval: 0.1) }
            return [ScreenshotRecord(url: folder, createdAt: .distantPast)]
        })
        service.refresh(in: first)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reads.value == 0 && ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reads.value == 1)
        service.refresh(in: second)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.captures.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(service.captures.map(\.url) == [second])
    }

    @Test("Mouse movement does not query Finder when the shelf is empty") @MainActor
    func emptyShelfDoesNotPollFinder() throws {
        let delegate = MacScopeApplicationDelegate()
        var reads = 0
        delegate.hasShelfItems = { false }
        delegate.captureShelfDestination = { reads += 1 }
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))

        for _ in 0..<100 { delegate.handleShelfEvent(event) }

        #expect(reads == 0)
    }

    @Test("Opening the Command Bar returns before a slow external app replies") @MainActor
    func slowOriginDoesNotBlockOpening() async throws {
        let service = CommandBarService(originReader: { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return CommandBarOriginContext(selectedText: "delayed selection")
        })
        let clock = ContinuousClock()
        let start = clock.now

        service.captureOrigin(pid: 123, applicationName: "Slow application")

        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(service.originApplicationName == "Slow application")
        let deadline = clock.now.advanced(by: .seconds(2))
        while service.selectedText == nil && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.selectedText == "delayed selection")
    }

    @Test("A late origin read cannot replace the most recently captured app") @MainActor
    func lateOriginDoesNotReplaceNewOrigin() async throws {
        let reads = MenuReadCounter()
        let service = CommandBarService(originReader: { pid in
            reads.increment()
            Thread.sleep(forTimeInterval: 0.1)
            return CommandBarOriginContext(selectedText: "selection from \(pid)")
        })
        service.captureOrigin(pid: 1, applicationName: "First")
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reads.value == 0 && ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(reads.value == 1)
        service.captureOrigin(pid: 2, applicationName: "Second")
        #expect(service.selectedText == nil)
        #expect(service.menuCommands.isEmpty)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.selectedText == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(service.originApplicationName == "Second")
        #expect(service.selectedText == "selection from 2")
    }

    @Test("Finder discovery runs off the UI thread and coalesces mouse events") @MainActor
    func slowFinderDoesNotBlockMouseEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workerDestination = directory.appendingPathComponent("worker")
        let mainDestination = directory.appendingPathComponent("main")
        let reads = MenuReadCounter()
        let service = SnippetShelfService(
            finderDestinationProvider: { directory },
            finderFocusProvider: { true },
            finderPIDProvider: { 123 },
            finderDestinationReader: { _ in
                reads.increment()
                Thread.sleep(forTimeInterval: 0.3)
                return Thread.isMainThread ? mainDestination : workerDestination
            }
        )
        service.addShelfItems([directory])
        let start = ContinuousClock.now

        for _ in 0..<100 { service.requestFrontmostFinderDestination() }

        #expect(start.duration(to: .now) < .milliseconds(100))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.destinationFolder == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.destinationFolder == workerDestination)
        #expect(reads.value == 1)
    }
}

private final class MenuReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
