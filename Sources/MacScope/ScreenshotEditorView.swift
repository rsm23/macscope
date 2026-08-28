import AppKit
import SwiftUI

private enum ScreenshotEditorTool: String, CaseIterable, Identifiable {
    case crop = "Crop"
    case rectangle = "Rectangle"
    case arrow = "Arrow"
    case pen = "Pen"
    case text = "Text"
    case sticker = "Sticker"
    case redact = "Redact"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .sticker: "face.smiling"
        case .redact: "eye.slash.fill"
        }
    }
}

private enum ScreenshotEditorBackground: String, CaseIterable, Identifiable {
    case transparent = "Transparent"
    case dark = "Dark"
    case light = "Light"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .transparent: .clear
        case .dark: Color(nsColor: .windowBackgroundColor).opacity(0.92)
        case .light: .white
        }
    }
    var nsColor: NSColor {
        switch self {
        case .transparent: .clear
        case .dark: .windowBackgroundColor
        case .light: .white
        }
    }
}

private struct ScreenshotEditorMark: Identifiable {
    enum Kind { case rectangle, arrow, pen, text, sticker, redact }
    let id = UUID()
    let kind: Kind
    let rect: CGRect
    let points: [CGPoint]
    let content: String

    init(kind: Kind, rect: CGRect = .zero, points: [CGPoint] = [], content: String = "") {
        self.kind = kind
        self.rect = rect
        self.points = points
        self.content = content
    }
}

struct ScreenshotEditorView: View {
    let sourceURL: URL
    let onSaved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tool = ScreenshotEditorTool.crop
    @State private var marks: [ScreenshotEditorMark] = []
    @State private var cropRect: CGRect?
    @State private var dragStart: CGPoint?
    @State private var liveRect: CGRect?
    @State private var livePoints: [CGPoint] = []
    @State private var background = ScreenshotEditorBackground.transparent
    @State private var backgroundPadding = 0.0
    @State private var annotationText = "Note"
    @State private var stickerText = "✨"
    @State private var statusMessage: String?
    @State private var isSaving = false
    @State private var detectedCodes: [String] = []

    private var image: NSImage? { NSImage(contentsOf: sourceURL) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $tool) {
                    ForEach(ScreenshotEditorTool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.icon).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 620)
                Divider().frame(height: 24)
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    .disabled(marks.isEmpty && cropRect == nil)
                Button("Clear", systemImage: "trash") {
                    marks.removeAll()
                    cropRect = nil
                }
                .disabled(marks.isEmpty && cropRect == nil)
                Spacer()
                Picker("Background", selection: $background) {
                    ForEach(ScreenshotEditorBackground.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .frame(width: 160)
            }
            .padding(14)

            HStack(spacing: 10) {
                Text("Background padding").font(.caption).foregroundStyle(.secondary)
                Slider(value: $backgroundPadding, in: 0...80, step: 2)
                    .frame(width: 180)
                Text("\(Int(backgroundPadding)) px")
                    .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                if tool == .text {
                    TextField("Annotation text", text: $annotationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                } else if tool == .sticker {
                    TextField("Emoji or symbol", text: $stickerText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                Spacer()
                Text("Drag on the image to apply the selected tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            GeometryReader { geometry in
                if let image {
                    let fitted = fittedRect(imageSize: image.size, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.82)
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                        Canvas { context, _ in
                            for mark in marks {
                                draw(mark, in: fitted, context: &context)
                            }
                            if let cropRect {
                                drawSelection(cropRect, color: .cyan, in: fitted, context: &context)
                            }
                            if let liveRect {
                                let color: Color = tool == .redact ? .black : tool == .crop ? .cyan : .red
                                drawSelection(liveRect, color: color, in: fitted, context: &context)
                            }
                            if livePoints.count >= 2 {
                                drawPath(points: livePoints, arrow: tool == .arrow, in: fitted, context: &context)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(editorGesture(imageRect: fitted))
                    }
                } else {
                    ContentUnavailableView(
                        "Screenshot unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(sourceURL.path(percentEncoded: false))
                    )
                }
            }

            Divider()
            HStack {
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                } else if let cropRect {
                    Text("Crop: \(Int(cropRect.width * 100))% × \(Int(cropRect.height * 100))% of the original")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy", systemImage: "square.and.arrow.down") {
                    saveCopy()
                }
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            if !detectedCodes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detectedCodes, id: \.self) { code in
                        HStack(spacing: 8) {
                            Label("QR code", systemImage: "qrcode")
                                .font(.caption.weight(.semibold))
                            Text(code).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Button("Copy") { copyCode(code) }.buttonStyle(.link)
                            if isWebURL(code) {
                                Button("Open") { openCode(code) }.buttonStyle(.link)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task(id: sourceURL) {
            detectedCodes = (try? await ScreenImageAnalyzer.detectQRCodes(at: sourceURL)) ?? []
        }
    }

    private func editorGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                let point = clamped(value.location, to: imageRect)
                if dragStart == nil { dragStart = clamped(value.startLocation, to: imageRect) }
                guard let dragStart else { return }
                switch tool {
                case .pen:
                    liveRect = nil
                    livePoints.append(normalizedPoint(point, in: imageRect))
                case .arrow:
                    liveRect = nil
                    livePoints = [
                        normalizedPoint(dragStart, in: imageRect),
                        normalizedPoint(point, in: imageRect),
                    ]
                default:
                    livePoints = []
                    liveRect = normalizedRect(from: dragStart, to: point, in: imageRect)
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    liveRect = nil
                    livePoints = []
                }
                guard let start = dragStart else { return }
                if tool == .pen {
                    guard livePoints.count >= 2 else { return }
                    marks.append(.init(kind: .pen, points: livePoints))
                    return
                }
                if tool == .arrow {
                    let end = normalizedPoint(clamped(value.location, to: imageRect), in: imageRect)
                    let beginning = normalizedPoint(start, in: imageRect)
                    guard hypot(end.x - beginning.x, end.y - beginning.y) >= 0.01 else { return }
                    marks.append(.init(kind: .arrow, points: [beginning, end]))
                    return
                }
                let rect = normalizedRect(
                    from: start,
                    to: clamped(value.location, to: imageRect),
                    in: imageRect
                )
                guard rect.width >= 0.01, rect.height >= 0.01 else { return }
                switch tool {
                case .crop: cropRect = rect
                case .rectangle: marks.append(.init(kind: .rectangle, rect: rect))
                case .text:
                    let content = annotationText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return }
                    marks.append(.init(kind: .text, rect: rect, content: String(content.prefix(240))))
                case .sticker:
                    let content = stickerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return }
                    marks.append(.init(kind: .sticker, rect: rect, content: String(content.prefix(12))))
                case .redact: marks.append(.init(kind: .redact, rect: rect))
                case .arrow, .pen: break
                }
            }
    }

    private func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in imageRect: CGRect) -> CGRect {
        let raw = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        return CGRect(
            x: (raw.minX - imageRect.minX) / imageRect.width,
            y: (raw.minY - imageRect.minY) / imageRect.height,
            width: raw.width / imageRect.width,
            height: raw.height / imageRect.height
        )
    }

    private func normalizedPoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - imageRect.minX) / imageRect.width,
            y: (point.y - imageRect.minY) / imageRect.height
        )
    }

    private func denormalized(_ rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private func draw(_ mark: ScreenshotEditorMark, in imageRect: CGRect, context: inout GraphicsContext) {
        let rect = denormalized(mark.rect, in: imageRect)
        switch mark.kind {
        case .rectangle:
            context.stroke(Path(rect), with: .color(.red), lineWidth: 3)
        case .arrow:
            drawPath(points: mark.points, arrow: true, in: imageRect, context: &context)
        case .pen:
            drawPath(points: mark.points, arrow: false, in: imageRect, context: &context)
        case .text:
            context.draw(
                Text(mark.content)
                    .font(.system(size: max(rect.height * 0.42, 12), weight: .bold))
                    .foregroundStyle(.white),
                in: rect.insetBy(dx: 6, dy: 4)
            )
            context.stroke(Path(rect), with: .color(.black.opacity(0.5)), lineWidth: 1)
        case .sticker:
            context.draw(
                Text(mark.content).font(.system(size: max(min(rect.width, rect.height) * 0.75, 16))),
                at: CGPoint(x: rect.midX, y: rect.midY),
                anchor: .center
            )
        case .redact:
            context.fill(Path(rect), with: .color(.black))
            context.stroke(Path(rect), with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }

    private func drawPath(
        points: [CGPoint],
        arrow: Bool,
        in imageRect: CGRect,
        context: inout GraphicsContext
    ) {
        guard points.count >= 2 else { return }
        let mapped = points.map {
            CGPoint(
                x: imageRect.minX + $0.x * imageRect.width,
                y: imageRect.minY + $0.y * imageRect.height
            )
        }
        var path = Path()
        path.move(to: mapped[0])
        for point in mapped.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        guard arrow, let start = mapped.dropLast().last, let end = mapped.last else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 14
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
        context.stroke(head, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    private func drawSelection(
        _ normalized: CGRect,
        color: Color,
        in imageRect: CGRect,
        context: inout GraphicsContext
    ) {
        let rect = denormalized(normalized, in: imageRect)
        context.fill(Path(rect), with: .color(color.opacity(0.14)))
        context.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
    }

    private func undo() {
        if !marks.isEmpty { marks.removeLast() }
        else { cropRect = nil }
    }

    private func saveCopy() {
        guard let image,
              let tiff = image.tiffRepresentation,
              let sourceRep = NSBitmapImageRep(data: tiff) else {
            statusMessage = "The source screenshot could not be decoded."
            return
        }
        isSaving = true
        do {
            let crop = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let contentWidth = max(Int(Double(sourceRep.pixelsWide) * crop.width), 1)
            let contentHeight = max(Int(Double(sourceRep.pixelsHigh) * crop.height), 1)
            let padding = Int(backgroundPadding.rounded())
            let outputWidth = contentWidth + padding * 2
            let outputHeight = contentHeight + padding * 2
            guard let outputRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: outputWidth,
                pixelsHigh: outputHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { throw EditorError.bitmap }
            outputRep.size = NSSize(width: outputWidth, height: outputHeight)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outputRep)
            background.nsColor.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: outputWidth, height: outputHeight)).fill()
            let sourceRect = NSRect(
                x: crop.minX * Double(sourceRep.pixelsWide),
                y: (1 - crop.maxY) * Double(sourceRep.pixelsHigh),
                width: crop.width * Double(sourceRep.pixelsWide),
                height: crop.height * Double(sourceRep.pixelsHigh)
            )
            image.draw(
                in: NSRect(x: padding, y: padding, width: contentWidth, height: contentHeight),
                from: sourceRect,
                operation: .copy,
                fraction: 1
            )
            for mark in marks {
                switch mark.kind {
                case .rectangle:
                    guard let drawingRect = outputRect(for: mark.rect, crop: crop, width: contentWidth, height: contentHeight, padding: padding) else { continue }
                    NSColor.systemRed.setStroke()
                    let path = NSBezierPath(rect: drawingRect)
                    path.lineWidth = max(Double(contentWidth) / 350, 3)
                    path.stroke()
                case .redact:
                    guard let drawingRect = outputRect(for: mark.rect, crop: crop, width: contentWidth, height: contentHeight, padding: padding) else { continue }
                    NSColor.black.setFill()
                    NSBezierPath(rect: drawingRect).fill()
                case .pen, .arrow:
                    drawOutputPath(
                        mark.points,
                        arrow: mark.kind == .arrow,
                        crop: crop,
                        width: contentWidth,
                        height: contentHeight,
                        padding: padding
                    )
                case .text, .sticker:
                    guard let drawingRect = outputRect(for: mark.rect, crop: crop, width: contentWidth, height: contentHeight, padding: padding) else { continue }
                    drawOutputText(mark, in: drawingRect)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let data = outputRep.representation(using: .png, properties: [:]) else {
                throw EditorError.encoding
            }
            let destination = uniqueDestination()
            try data.write(to: destination, options: .atomic)
            statusMessage = "Saved \(destination.lastPathComponent)."
            onSaved(destination)
        } catch {
            statusMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func outputRect(
        for rect: CGRect,
        crop: CGRect,
        width: Int,
        height: Int,
        padding: Int
    ) -> NSRect? {
        let local = CGRect(
            x: (rect.minX - crop.minX) / crop.width,
            y: (rect.minY - crop.minY) / crop.height,
            width: rect.width / crop.width,
            height: rect.height / crop.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !local.isNull, local.width > 0, local.height > 0 else { return nil }
        return NSRect(
            x: Double(padding) + local.minX * Double(width),
            y: Double(padding) + (1 - local.maxY) * Double(height),
            width: local.width * Double(width),
            height: local.height * Double(height)
        )
    }

    private func drawOutputPath(
        _ points: [CGPoint],
        arrow: Bool,
        crop: CGRect,
        width: Int,
        height: Int,
        padding: Int
    ) {
        let mapped = points.map { point in
            NSPoint(
                x: Double(padding) + ((point.x - crop.minX) / crop.width) * Double(width),
                y: Double(padding) + (1 - ((point.y - crop.minY) / crop.height)) * Double(height)
            )
        }
        guard mapped.count >= 2 else { return }
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.move(to: mapped[0])
        for point in mapped.dropFirst() { path.line(to: point) }
        path.lineWidth = max(Double(width) / 350, 3)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        guard arrow, let start = mapped.dropLast().last, let end = mapped.last else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(Double(width) / 35, 12)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
        head.lineWidth = path.lineWidth
        head.lineCapStyle = .round
        head.stroke()
    }

    private func drawOutputText(_ mark: ScreenshotEditorMark, in rect: NSRect) {
        let fontSize: CGFloat
        let alignment = NSMutableParagraphStyle()
        if mark.kind == .sticker {
            fontSize = max(min(rect.width, rect.height) * 0.75, 16)
            alignment.alignment = .center
        } else {
            fontSize = max(rect.height * 0.42, 12)
            alignment.alignment = .left
        }
        alignment.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: mark.kind == .text ? .bold : .regular),
            .foregroundColor: mark.kind == .text ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: alignment,
            .strokeColor: mark.kind == .text ? NSColor.black : NSColor.clear,
            .strokeWidth: mark.kind == .text ? -2.0 : 0.0,
        ]
        (mark.content as NSString).draw(
            with: rect.insetBy(dx: mark.kind == .text ? 6 : 0, dy: mark.kind == .text ? 4 : 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
    }

    private func uniqueDestination() -> URL {
        let folder = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(base)-edited.png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-edited-\(suffix).png")
            suffix += 1
        }
        return destination
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        statusMessage = "QR content copied."
    }

    private func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func openCode(_ code: String) {
        guard isWebURL(code), let url = URL(string: code) else { return }
        NSWorkspace.shared.open(url)
    }

    private enum EditorError: LocalizedError {
        case bitmap, encoding
        var errorDescription: String? {
            switch self {
            case .bitmap: "The edited bitmap could not be created."
            case .encoding: "The edited screenshot could not be encoded as PNG."
            }
        }
    }
}
