import AppKit
import SwiftUI

enum ShelfScreenEdge: String, CaseIterable, Identifiable {
    case left = "Left"
    case right = "Right"
    case top = "Top"
    var id: String { rawValue }
}

enum ShelfDropZoneGeometry {
    static func shouldReveal(
        location: CGPoint,
        screenFrame: CGRect,
        hasFileURLs: Bool,
        threshold: CGFloat = 96
    ) -> Bool {
        hasFileURLs && location.y >= screenFrame.maxY - threshold
    }
}

enum ShelfDragContent {
    static func containsSupportedFiles(in pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else { return false }
        return values.contains(where: SnippetShelfService.isSupportedShelfURL)
    }

    static func itemProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
}

struct ShelfOverlayView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    let service: SnippetShelfService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Session Shelf", systemImage: "tray.full.fill")
                    .font(.headline)
                Text("⌃⌥S").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Clipboard", systemImage: "clipboard") { service.addClipboardTextToShelf() }
                    .macScopeGlassButton()
                Button("Files…", systemImage: "plus") { service.addShelfItems() }
                    .macScopeGlassButton()
                if !service.shelfItems.isEmpty {
                    Button("Move Here", systemImage: "arrow.right.circle.fill") {
                        service.moveShelfItemsToCurrentFinderFolder()
                    }
                    .macScopeGlassButton(prominent: true)
                    .disabled(!service.canMoveToCurrentFinderFolder)
                    .help(service.moveDestinationHelp)
                }
                Button { dismissWindow(id: "session-shelf") } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }

            if service.shelfItems.isEmpty && service.shelfTextItems.isEmpty {
                ContentUnavailableView(
                    "Drop something here",
                    systemImage: "arrow.down.doc",
                    description: Text("Drag files or folders to the top of the screen to park them, then click the shelf at your Finder destination to move them.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(service.shelfTextItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.link == nil ? "text.alignleft" : "link")
                                    .foregroundStyle(MacScopeTheme.accent).frame(width: 24)
                                Text(item.summary).lineLimit(2).font(.callout)
                                Spacer()
                                if item.link != nil { Button("Open") { service.open(item) }.buttonStyle(.link) }
                                Button("Copy") { service.copy(item) }.buttonStyle(.link)
                                Button(role: .destructive) { service.remove(item) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            .draggable(item.text)
                        }
                        ForEach(service.shelfItems) { item in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable().scaledToFit().frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.url.lastPathComponent).lineLimit(1).font(.callout.weight(.medium))
                                    Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                                        .lineLimit(1).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "hand.draw")
                                    .foregroundStyle(.secondary)
                                    .help("Drag this file into Finder or another app")
                                Button("Open") { service.open(item) }.buttonStyle(.link)
                                Button("Reveal") { service.reveal(item) }.buttonStyle(.link)
                                Button(role: .destructive) { service.remove(item) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onDrag {
                                ShelfDragContent.itemProvider(for: item.url)
                            }
                        }
                    }
                }
            }
            if let message = service.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 520, height: 390)
        .background(MacScopeTheme.contentBackground)
        .dropDestination(for: URL.self) { urls, _ in
            service.addShelfItems(urls)
            return !urls.isEmpty
        }
        .dropDestination(for: String.self) { strings, _ in
            for string in strings { service.addShelfText(string) }
            return !strings.isEmpty
        }
        .background(ShelfWindowConfigurator().frame(width: 0, height: 0))
        .onExitCommand { dismissWindow(id: "session-shelf") }
    }
}

struct ShelfDropZoneView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    let service: SnippetShelfService

    var body: some View {
        shelfContent
        .dropDestination(for: URL.self) { urls, _ in
            service.addShelfItems(urls)
            return !urls.isEmpty
        } isTargeted: { _ in }
        .background(ShelfDropZoneWindowConfigurator().frame(width: 0, height: 0))
        .onAppear { service.captureFrontmostFinderDestination() }
    }

    private var shelfContent: some View {
        HStack(spacing: 12) {
            Image(systemName: service.shelfItems.isEmpty ? "arrow.down.doc.fill" : "tray.full.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(MacScopeTheme.accent)
                .frame(width: 42, height: 42)
                .background(MacScopeTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))

            if service.shelfItems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Drop files or folders here").font(.headline)
                    Text("They will stay parked while you navigate to their destination.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    moveParkedItems()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Move \(service.shelfItems.count) item\(service.shelfItems.count == 1 ? "" : "s") here")
                            .font(.headline)
                        Text(service.destinationDisplayName)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Move every parked file or folder to the current Finder folder")
            }

            Spacer(minLength: 8)
            if !service.shelfItems.isEmpty {
                Text("\(service.shelfItems.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Button("Move", systemImage: "arrow.right.circle.fill") {
                    moveParkedItems()
                }
                .macScopeGlassButton(prominent: true)
                .disabled(!service.canMoveToCurrentFinderFolder)
                .help(service.moveDestinationHelp)
                Button {
                    openWindow(id: "session-shelf")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.plain)
                .help("Open the full session shelf")
            }
            Button {
                dismissWindow(id: "shelf-drop-zone")
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide the shelf")
        }
        .padding(14)
        .frame(width: 520, height: 82)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MacScopeTheme.accent.opacity(service.shelfItems.isEmpty ? 0.65 : 0.28), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func moveParkedItems() {
        service.moveShelfItemsToCurrentFinderFolder()
        if service.shelfItems.isEmpty { dismissWindow(id: "shelf-drop-zone") }
    }
}

private struct ShelfDropZoneWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = false
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 6
        ))
        window.orderFrontRegardless()
    }
}

private struct ShelfWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(CGPoint(
            x: min(max(pointer.x - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height)
        ))
        window.makeKeyAndOrderFront(nil)
    }
}
