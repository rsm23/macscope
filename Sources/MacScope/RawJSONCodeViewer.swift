import AppKit
import MacScopeCore
import SwiftUI

struct RawJSONViewerPanel: View {
    let document: JSONOutlineDocument
    @State private var command = RawJSONFoldCommand.none
    @State private var commandRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("JSON snapshot", systemImage: "curlybraces")
                    .font(.subheadline.weight(.semibold))
                Text("\(lineCount.formatted()) \(lineCount == 1 ? "line" : "lines")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(document.originalText, forType: .string)
                }
                .disabled(document.originalText.isEmpty)
                .macScopeGlassButton()
                .help("Copy the complete expanded JSON snapshot")

                Button("Collapse All", systemImage: "arrow.down.right.and.arrow.up.left") {
                    issue(.collapseAll)
                }
                .disabled(document.foldableLineNumbers.isEmpty)
                .macScopeGlassButton()
                .help("Collapse every multi-line JSON object and array")

                Button("Expand All", systemImage: "arrow.up.left.and.arrow.down.right") {
                    issue(.expandAll)
                }
                .disabled(document.foldableLineNumbers.isEmpty)
                .macScopeGlassButton()
                .help("Expand every JSON object and array")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if document.originalText.isEmpty {
                ProgressView("Preparing JSON preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    RawJSONCodeViewer(document: document, command: command)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macScopeGlassSurface(cornerRadius: MacScopeTheme.cardRadius)
        .clipShape(RoundedRectangle(cornerRadius: MacScopeTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func issue(_ kind: RawJSONFoldCommand.Kind) {
        commandRevision &+= 1
        command = RawJSONFoldCommand(kind: kind, revision: commandRevision)
    }

    private var lineCount: Int {
        document.originalText.isEmpty ? 0 : document.lines.count
    }
}

private struct RawJSONFoldCommand: Equatable {
    enum Kind: Equatable {
        case none
        case collapseAll
        case expandAll
    }

    let kind: Kind
    let revision: Int

    static let none = RawJSONFoldCommand(kind: .none, revision: 0)
}

private struct RawJSONCodeViewer: NSViewRepresentable {
    let document: JSONOutlineDocument
    let command: RawJSONFoldCommand

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> JSONCodeContainerView {
        let container = JSONCodeContainerView()
        container.gutterTableView.dataSource = context.coordinator
        container.gutterTableView.delegate = context.coordinator
        container.codeTableView.dataSource = context.coordinator
        container.codeTableView.delegate = context.coordinator
        context.coordinator.connect(container: container)
        context.coordinator.apply(document: document, command: command)
        return container
    }

    func updateNSView(_ container: JSONCodeContainerView, context: Context) {
        context.coordinator.apply(document: document, command: command)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: JSONCodeContainerView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? max(nsView.bounds.width, 1)
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
            ?? max(nsView.bounds.height, 180)
        return CGSize(width: width, height: max(height, 180))
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var container: JSONCodeContainerView?
        private weak var gutterTableView: NSTableView?
        private weak var codeTableView: NSTableView?
        private weak var codeScrollView: NSScrollView?
        private var document = JSONOutlineDocument(text: "")
        private var visibleLines: [JSONOutlineVisibleLine] = []
        private var collapsedLineNumbers = Set<Int>()
        private var lastCommand = RawJSONFoldCommand.none
        private var structureSignature: [String] = []

        func connect(container: JSONCodeContainerView) {
            self.container = container
            gutterTableView = container.gutterTableView
            codeTableView = container.codeTableView
            codeScrollView = container.codeScrollView
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            visibleLines.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard visibleLines.indices.contains(row), let tableColumn else { return nil }
            let line = visibleLines[row]

            switch tableColumn.identifier {
            case .jsonGutter:
                let identifier = NSUserInterfaceItemIdentifier("json-gutter-cell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? JSONGutterCellView)
                    ?? JSONGutterCellView(identifier: identifier)
                cell.configure(line: line) { [weak self] lineNumber in
                    self?.toggle(lineNumber: lineNumber)
                }
                return cell
            case .jsonCode:
                let identifier = NSUserInterfaceItemIdentifier("json-code-cell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? JSONCodeCellView)
                    ?? JSONCodeCellView(identifier: identifier)
                cell.configure(line: line)
                return cell
            default:
                return nil
            }
        }

        func apply(document newDocument: JSONOutlineDocument, command: RawJSONFoldCommand) {
            guard let gutterTableView, let codeTableView else { return }
            let documentChanged = newDocument != document
            let commandChanged = command != lastCommand
            guard documentChanged || commandChanged else { return }

            let newStructureSignature = Self.signature(for: newDocument)
            let structureChanged = documentChanged && newStructureSignature != structureSignature
            let anchor = structureChanged ? nil : captureScrollAnchor()
            if documentChanged {
                document = newDocument
                structureSignature = newStructureSignature
                if structureChanged {
                    collapsedLineNumbers.removeAll(keepingCapacity: true)
                } else {
                    collapsedLineNumbers.formIntersection(document.foldableLineNumbers)
                }
                updateCodeColumnWidth()
            }

            if commandChanged {
                switch command.kind {
                case .none:
                    break
                case .collapseAll:
                    collapsedLineNumbers = document.foldableLineNumbers
                case .expandAll:
                    collapsedLineNumbers.removeAll(keepingCapacity: true)
                }
                lastCommand = command
            }

            visibleLines = document.visibleLines(collapsedLineNumbers: collapsedLineNumbers)
            gutterTableView.reloadData()
            codeTableView.reloadData()
            container?.updateDocumentFrames()
            restoreScrollAnchor(anchor)
            container?.synchronizeGutter()
        }

        private func toggle(lineNumber: Int) {
            guard document.foldableLineNumbers.contains(lineNumber),
                  let gutterTableView, let codeTableView else { return }
            let anchor = captureScrollAnchor()
            if collapsedLineNumbers.remove(lineNumber) == nil {
                collapsedLineNumbers.insert(lineNumber)
            }
            visibleLines = document.visibleLines(collapsedLineNumbers: collapsedLineNumbers)
            gutterTableView.reloadData()
            codeTableView.reloadData()
            container?.updateDocumentFrames()
            restoreScrollAnchor(anchor)
            container?.synchronizeGutter()
        }

        private func updateCodeColumnWidth() {
            guard let codeTableView,
                  let column = codeTableView.tableColumn(withIdentifier: .jsonCode) else { return }
            let longestLine = document.lines.lazy.map { $0.text.utf16.count }.max() ?? 80
            let estimatedWidth = min(max(CGFloat(longestLine) * 7.1 + 30, 700), 12_000)
            column.minWidth = estimatedWidth
            column.width = estimatedWidth
        }

        private func captureScrollAnchor() -> JSONScrollAnchor? {
            guard let codeTableView, let codeScrollView, !visibleLines.isEmpty else { return nil }
            let visibleRect = codeTableView.visibleRect
            let row = codeTableView.row(at: NSPoint(x: visibleRect.minX + 1, y: visibleRect.minY + 1))
            guard visibleLines.indices.contains(row) else { return nil }
            let rowRect = codeTableView.rect(ofRow: row)
            return JSONScrollAnchor(
                lineNumber: visibleLines[row].lineNumber,
                fallbackRow: row,
                verticalOffset: rowRect.minY - codeScrollView.contentView.bounds.minY,
                horizontalOffset: codeScrollView.contentView.bounds.minX
            )
        }

        private func restoreScrollAnchor(_ anchor: JSONScrollAnchor?) {
            guard let anchor, let codeTableView, let codeScrollView, !visibleLines.isEmpty else { return }
            let exactRow = visibleLines.firstIndex { $0.lineNumber == anchor.lineNumber }
            let precedingRow = visibleLines.lastIndex { $0.lineNumber < anchor.lineNumber }
            let row = exactRow ?? precedingRow ?? min(anchor.fallbackRow, visibleLines.count - 1)
            let rowRect = codeTableView.rect(ofRow: row)
            let maximumY = max(0, codeTableView.bounds.height - codeScrollView.contentView.bounds.height)
            let maximumX = max(0, codeTableView.bounds.width - codeScrollView.contentView.bounds.width)
            let origin = NSPoint(
                x: min(max(0, anchor.horizontalOffset), maximumX),
                y: min(max(0, rowRect.minY - anchor.verticalOffset), maximumY)
            )
            codeScrollView.contentView.scroll(to: origin)
            codeScrollView.reflectScrolledClipView(codeScrollView.contentView)
        }

        private static func signature(for document: JSONOutlineDocument) -> [String] {
            document.lines.compactMap { line in
                guard line.isFoldable else { return nil }
                let prefix = line.text.prefix { $0 != "{" && $0 != "[" }
                return "\(line.lineNumber):\(line.closingLineNumber ?? 0):\(prefix)"
            }
        }
    }
}

@MainActor
private final class JSONCodeContainerView: NSView {
    let gutterTableView = NSTableView()
    let codeTableView = NSTableView()
    let gutterScrollView = JSONGutterScrollView()
    let codeScrollView = NSScrollView()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        Self.configure(tableView: gutterTableView)
        Self.configure(tableView: codeTableView)
        gutterTableView.setAccessibilityLabel("JSON line numbers and folding controls")

        let gutter = NSTableColumn(identifier: .jsonGutter)
        gutter.title = "Line"
        gutter.width = 72
        gutter.minWidth = 72
        gutter.maxWidth = 72
        gutter.resizingMask = []
        gutterTableView.addTableColumn(gutter)

        let code = NSTableColumn(identifier: .jsonCode)
        code.title = "JSON"
        code.width = 1_200
        code.minWidth = 700
        code.maxWidth = 12_000
        code.resizingMask = [.userResizingMask]
        codeTableView.addTableColumn(code)

        gutterScrollView.documentView = gutterTableView
        gutterScrollView.hasVerticalScroller = false
        gutterScrollView.hasHorizontalScroller = false
        gutterScrollView.borderType = .noBorder
        gutterScrollView.drawsBackground = false
        gutterScrollView.linkedScrollView = codeScrollView

        codeScrollView.documentView = codeTableView
        codeScrollView.hasVerticalScroller = true
        codeScrollView.hasHorizontalScroller = true
        codeScrollView.autohidesScrollers = true
        codeScrollView.borderType = .noBorder
        codeScrollView.drawsBackground = false
        codeScrollView.setAccessibilityLabel("Raw snapshot JSON code viewer")

        separator.boxType = .separator
        for view in [gutterScrollView, separator, codeScrollView] {
            addSubview(view)
        }

        codeScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(codeBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: codeScrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        layoutScrollViews(in: bounds)
        updateDocumentFrames()
        synchronizeGutter()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftUI can resize an NSViewRepresentable without scheduling another
        // AppKit constraint pass. Keep the two synchronized scroll views tied
        // directly to the container's actual frame so neither viewport can
        // retain its 1-point construction-time height.
        layoutScrollViews(in: NSRect(origin: .zero, size: newSize))
    }

    private func layoutScrollViews(in rect: NSRect) {
        let gutterWidth = min(CGFloat(72), max(0, rect.width))
        let separatorWidth = min(CGFloat(1), max(0, rect.width - gutterWidth))
        let codeWidth = max(0, rect.width - gutterWidth - separatorWidth)

        gutterScrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: gutterWidth,
            height: rect.height
        )
        separator.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: separatorWidth,
            height: rect.height
        )
        codeScrollView.frame = NSRect(
            x: gutterWidth + separatorWidth,
            y: 0,
            width: codeWidth,
            height: rect.height
        )
    }

    func updateDocumentFrames() {
        let rowCount = codeTableView.numberOfRows
        // `rect(ofRow:)` can still be empty for a far-off row while a freshly
        // reloaded NSTableView is establishing its geometry. Computing the
        // height from the fixed row metrics keeps large expanded documents from
        // briefly receiving a zero-height document view (collapsed documents
        // only had one row, which hid this lifecycle edge case).
        let rowStride = codeTableView.rowHeight + codeTableView.intercellSpacing.height
        let documentHeight = CGFloat(rowCount) * rowStride
        let gutterWidth = max(72, gutterScrollView.contentSize.width)
        let codeColumnWidth = codeTableView.tableColumns.first?.width ?? 700
        let codeWidth = max(codeColumnWidth, codeScrollView.contentSize.width)
        let gutterSize = NSSize(width: gutterWidth, height: documentHeight)
        let codeSize = NSSize(width: codeWidth, height: documentHeight)
        if gutterTableView.frame.size != gutterSize {
            gutterTableView.setFrameSize(gutterSize)
        }
        if codeTableView.frame.size != codeSize {
            codeTableView.setFrameSize(codeSize)
        }
    }

    func synchronizeGutter() {
        let target = NSPoint(x: 0, y: codeScrollView.contentView.bounds.minY)
        guard gutterScrollView.contentView.bounds.origin != target else { return }
        gutterScrollView.contentView.scroll(to: target)
        gutterScrollView.reflectScrolledClipView(gutterScrollView.contentView)
    }

    @objc private func codeBoundsDidChange(_ notification: Notification) {
        synchronizeGutter()
    }

    private static func configure(tableView: NSTableView) {
        tableView.headerView = nil
        tableView.rowHeight = 21
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
    }
}

@MainActor
private final class JSONGutterScrollView: NSScrollView {
    weak var linkedScrollView: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        linkedScrollView?.scrollWheel(with: event)
    }
}

private struct JSONScrollAnchor {
    let lineNumber: Int
    let fallbackRow: Int
    let verticalOffset: CGFloat
    let horizontalOffset: CGFloat
}

@MainActor
private final class JSONGutterCellView: NSTableCellView {
    private let disclosureButton = NSButton()
    private let lineNumberLabel = NSTextField(labelWithString: "")
    private var lineNumber = 0
    private var onToggle: ((Int) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        updateBackgroundColor()

        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        lineNumberLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        lineNumberLabel.textColor = .tertiaryLabelColor
        lineNumberLabel.alignment = .right
        lineNumberLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureButton)
        addSubview(lineNumberLabel)
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            disclosureButton.heightAnchor.constraint(equalToConstant: 18),
            lineNumberLabel.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 1),
            lineNumberLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lineNumberLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    func configure(line: JSONOutlineVisibleLine, onToggle: @escaping (Int) -> Void) {
        lineNumber = line.lineNumber
        self.onToggle = onToggle
        lineNumberLabel.stringValue = line.lineNumber.formatted()
        lineNumberLabel.setAccessibilityLabel("Line \(line.lineNumber)")

        disclosureButton.isHidden = !line.isFoldable
        disclosureButton.image = line.isCollapsed
            ? NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            : NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        let sectionLineCount = line.isCollapsed
            ? line.hiddenLineCount
            : max(0, (line.closingLineNumber ?? line.lineNumber) - line.lineNumber)
        disclosureButton.setAccessibilityLabel(
            line.isCollapsed
                ? "Expand JSON section at line \(line.lineNumber), \(sectionLineCount) hidden lines"
                : "Collapse JSON section at line \(line.lineNumber), \(sectionLineCount) following lines"
        )
        disclosureButton.toolTip = line.isCollapsed ? "Expand section" : "Collapse section"
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        onToggle?(lineNumber)
    }

    private func updateBackgroundColor() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.24).cgColor
    }
}

@MainActor
private final class JSONCodeCellView: NSTableCellView {
    private let codeLabel = NSTextField()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        codeLabel.isEditable = false
        codeLabel.isSelectable = true
        codeLabel.isBezeled = false
        codeLabel.drawsBackground = false
        codeLabel.usesSingleLineMode = true
        codeLabel.lineBreakMode = .byClipping
        codeLabel.focusRingType = .none
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(codeLabel)

        NSLayoutConstraint.activate([
            codeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            codeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(line: JSONOutlineVisibleLine) {
        codeLabel.attributedStringValue = JSONSyntaxHighlighter.highlight(line.text)
        codeLabel.toolTip = line.text
        let foldDescription = line.isCollapsed ? ", \(line.hiddenLineCount) lines hidden" : ""
        codeLabel.setAccessibilityLabel("Line \(line.lineNumber)\(foldDescription): \(line.text.trimmingCharacters(in: .whitespaces))")
    }
}

@MainActor
private enum JSONSyntaxHighlighter {
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func highlight(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        let units = Array(source.utf16)
        var index = 0

        while index < units.count {
            switch units[index] {
            case 34: // String literal
                let start = index
                index += 1
                var escaped = false
                while index < units.count {
                    let unit = units[index]
                    if escaped {
                        escaped = false
                    } else if unit == 92 {
                        escaped = true
                    } else if unit == 34 {
                        index += 1
                        break
                    }
                    index += 1
                }
                var lookahead = index
                while lookahead < units.count, units[lookahead] == 32 || units[lookahead] == 9 {
                    lookahead += 1
                }
                let color: NSColor = lookahead < units.count && units[lookahead] == 58
                    ? .controlAccentColor
                    : .systemGreen
                output.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: index - start))

            case 45, 48...57: // Number
                let start = index
                index += 1
                while index < units.count, isNumberUnit(units[index]) { index += 1 }
                output.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: NSRange(location: start, length: index - start))

            case 116: // true
                index = colorKeyword("true", from: index, units: units, output: output, color: .systemOrange)
            case 102: // false
                index = colorKeyword("false", from: index, units: units, output: output, color: .systemOrange)
            case 110: // null
                index = colorKeyword("null", from: index, units: units, output: output, color: .systemRed)

            case 58, 44, 123, 125, 91, 93:
                output.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: index, length: 1))
                index += 1
            default:
                index += 1
            }
        }
        return output
    }

    private static func isNumberUnit(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || unit == 46 || unit == 69 || unit == 101 || unit == 43 || unit == 45
    }

    private static func colorKeyword(
        _ keyword: String,
        from index: Int,
        units: [UInt16],
        output: NSMutableAttributedString,
        color: NSColor
    ) -> Int {
        let keywordUnits = Array(keyword.utf16)
        let end = index + keywordUnits.count
        guard end <= units.count, Array(units[index..<end]) == keywordUnits else { return index + 1 }
        output.addAttribute(.foregroundColor, value: color, range: NSRange(location: index, length: keywordUnits.count))
        return end
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let jsonGutter = NSUserInterfaceItemIdentifier("json-gutter")
    static let jsonCode = NSUserInterfaceItemIdentifier("json-code")
}
