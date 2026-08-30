import AppKit
import Foundation
import Testing
@testable import MacScope

@Suite("Session Shelf file moves")
struct ShelfFlowTests {
    @Test("Top-edge reveal only accepts file drags at the screen top")
    func topEdgeRevealGeometry() {
        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(ShelfDropZoneGeometry.shouldReveal(
            location: CGPoint(x: 700, y: 895),
            screenFrame: frame,
            hasFileURLs: true
        ))
        #expect(!ShelfDropZoneGeometry.shouldReveal(
            location: CGPoint(x: 700, y: 780),
            screenFrame: frame,
            hasFileURLs: true
        ))
        #expect(!ShelfDropZoneGeometry.shouldReveal(
            location: CGPoint(x: 700, y: 899),
            screenFrame: frame,
            hasFileURLs: false
        ))
    }

    @Test("Drag detection accepts file URLs and rejects unrelated pasteboard content")
    func dragPasteboardRequiresFiles() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let file = fixture.source.appendingPathComponent("report.txt")
        try Data("MacScope".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacScope-Shelf-\(UUID().uuidString)"))

        pasteboard.clearContents()
        pasteboard.setString("dragged text", forType: .string)
        #expect(!ShelfDragContent.containsSupportedFiles(in: pasteboard))

        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(ShelfDragContent.containsSupportedFiles(in: pasteboard))
    }

    @Test("Shelf file rows export a standard file URL drag provider")
    func dragProviderExportsFileURL() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let file = fixture.source.appendingPathComponent("report.txt")
        try Data("MacScope".utf8).write(to: file)

        let provider = ShelfDragContent.itemProvider(for: file)

        #expect(provider.hasItemConformingToTypeIdentifier("public.file-url"))
    }

    @Test("Clicking the shelf moves parked files to the destination") @MainActor
    func movesParkedFile() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("report.txt")
        try Data("MacScope".utf8).write(to: source)
        let service = SnippetShelfService()
        service.addShelfItems([source])

        service.moveShelfItems(to: fixture.destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.destination.appendingPathComponent("report.txt").path
        ))
        #expect(service.shelfItems.isEmpty)
    }

    @Test("Compact shelf resolves the current Finder folder and moves every parked item") @MainActor
    func compactShelfMovesAllParkedFiles() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let sources = try (1...3).map { index in
            let source = fixture.source.appendingPathComponent("item-\(index).txt")
            try Data("item \(index)".utf8).write(to: source)
            return source
        }
        let service = SnippetShelfService(
            finderDestinationProvider: { fixture.destination },
            finderFocusProvider: { true }
        )
        service.addShelfItems(sources)

        service.moveShelfItemsToCurrentFinderFolder()

        #expect(service.shelfItems.isEmpty)
        for source in sources {
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent(source.lastPathComponent).path
            ))
        }
        #expect(service.statusMessage == "Moved 3.")
    }

    @Test("Move is disabled unless Finder is focused on a different folder") @MainActor
    func moveRequiresDifferentFocusedFinderFolder() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("report.txt")
        try Data("MacScope".utf8).write(to: source)
        let finder = FinderFixtureState(destination: fixture.destination)
        let service = SnippetShelfService(
            finderDestinationProvider: { finder.destination },
            finderFocusProvider: { finder.focused }
        )
        service.addShelfItems([source])

        #expect(service.captureFrontmostFinderDestination() == nil)
        #expect(!service.canMoveToCurrentFinderFolder)

        finder.focused = true
        finder.destination = fixture.source
        #expect(service.captureFrontmostFinderDestination() == fixture.source)
        #expect(!service.canMoveToCurrentFinderFolder)

        finder.destination = fixture.destination
        #expect(service.captureFrontmostFinderDestination() == fixture.destination)
        #expect(service.canMoveToCurrentFinderFolder)
    }

    @Test("Shelf accepts existing files and folders only") @MainActor
    func acceptsOnlySupportedFileURLs() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let file = fixture.source.appendingPathComponent("report.txt")
        try Data("MacScope".utf8).write(to: file)
        let missing = fixture.source.appendingPathComponent("missing.txt")
        let service = SnippetShelfService()

        service.addShelfItems([file, fixture.source, missing, URL(string: "https://example.com")!])

        #expect(service.shelfItems.map(\.url) == [file.standardizedFileURL, fixture.source.standardizedFileURL])
    }

    @Test("A name collision is never overwritten and stays parked") @MainActor
    func preservesNameCollision() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("report.txt")
        let target = fixture.destination.appendingPathComponent("report.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: target)
        let service = SnippetShelfService()
        service.addShelfItems([source])

        service.moveShelfItems(to: fixture.destination)

        #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(service.shelfItems.map(\.url) == [source.standardizedFileURL])
        #expect(service.statusMessage?.contains("name conflict") == true)
    }

    @Test("A folder cannot be moved inside itself") @MainActor
    func rejectsMoveIntoDescendant() throws {
        let fixture = try ShelfFixture()
        defer { fixture.remove() }
        let folder = fixture.source.appendingPathComponent("Project", isDirectory: true)
        let descendant = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        let service = SnippetShelfService()
        service.addShelfItems([folder])

        service.moveShelfItems(to: descendant)

        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(service.shelfItems.count == 1)
        #expect(service.statusMessage?.contains("failed and kept on shelf") == true)
    }
}

@MainActor
private final class FinderFixtureState {
    var focused = false
    var destination: URL

    init(destination: URL) {
        self.destination = destination
    }
}

private struct ShelfFixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-ShelfTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
