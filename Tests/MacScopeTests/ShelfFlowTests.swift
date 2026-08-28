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
