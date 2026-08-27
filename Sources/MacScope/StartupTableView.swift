import AppKit
import MacScopeCore
import SwiftUI

/// AppKit's default accessibility table implementation creates mock cells for
/// every requested off-screen row. Some assistive clients request those cells
/// repeatedly after selection changes, defeating NSTableView virtualization.
/// Expose the header and currently visible native row views instead; the full
/// row count remains available from NSTableView and scrolling reveals the next
/// accessible rows without materializing the whole launchd catalog.
@MainActor
private final class StartupAccessibilityTableView: NSTableView {
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if let headerView {
            children.append(headerView)
        }
        children.append(contentsOf: visibleAccessibilityRows())
        return children
    }

    override func accessibilityRows() -> [any NSAccessibilityRow]? {
        visibleAccessibilityRows()
    }

    override func accessibilityVisibleRows() -> [any NSAccessibilityRow]? {
        visibleAccessibilityRows()
    }

    override func accessibilitySelectedRows() -> [any NSAccessibilityRow]? {
        selectedRowIndexes.compactMap { rowView(atRow: $0, makeIfNecessary: false) }
    }

    private func visibleAccessibilityRows() -> [NSTableRowView] {
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let lowerBound = max(range.location, 0)
        let upperBound = min(range.location + range.length, numberOfRows)
        guard lowerBound < upperBound else { return [] }
        return (lowerBound..<upperBound).compactMap {
            rowView(atRow: $0, makeIfNecessary: true)
        }
    }
}

@MainActor
private final class StartupAccessibleRowView: NSTableRowView {
    private var rowDescription = "Startup service"

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityLabel() -> String? { rowDescription }

    func configure(item: StartupItem) {
        let enabled = switch item.isEnabled {
        case true: "enabled"
        case false: "disabled"
        case nil: "enabled state unknown"
        }
        rowDescription = "\(item.label), \(item.domain.rawValue) domain, \(enabled), run at load \(item.runAtLoad ? "yes" : "no"), keep alive \(item.keepAlive ? "yes" : "no")"
    }
}

/// A native, virtualized table for the relatively large launchd definition
/// collection. AppKit creates only visible cells and preserves native row
/// highlighting while filtering and sorting happen outside the render pass.
struct StartupVirtualizedTable: NSViewRepresentable {
    let rows: [StartupItem]
    let rowsRevision: Int
    @Binding var selection: StartupItem.ID?
    let sortRule: StartupSortRule
    let onSort: (StartupSortRule) -> Void
    let onAction: (LaunchActionKind, StartupItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = StartupAccessibilityTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 32
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 7, height: 1)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("Startup services")

        Self.addColumn(.label, title: "Label", width: 275, minimumWidth: 180, maximumWidth: 900, to: tableView)
        Self.addColumn(.domain, title: "Domain", width: 78, minimumWidth: 70, maximumWidth: 120, to: tableView)
        Self.addColumn(.runAtLoad, title: "Run at load", width: 92, minimumWidth: 82, maximumWidth: 120, to: tableView)
        Self.addColumn(.keepAlive, title: "Keep alive", width: 84, minimumWidth: 76, maximumWidth: 115, to: tableView)
        Self.addColumn(.enabled, title: "Enabled", width: 80, minimumWidth: 72, maximumWidth: 110, to: tableView)
        Self.addColumn(.program, title: "Program", width: 245, minimumWidth: 150, maximumWidth: 800, to: tableView)
        Self.addColumn(.source, title: "Source", width: 320, minimumWidth: 180, maximumWidth: 1_200, to: tableView)
        Self.addColumn(.actions, title: "Actions", width: 68, minimumWidth: 62, maximumWidth: 80, to: tableView)

        let menu = NSMenu(title: "Startup service")
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityLabel("Startup services table")

        context.coordinator.connect(tableView: tableView, scrollView: scrollView)
        context.coordinator.apply(rows: rows, revision: rowsRevision, selection: selection, sortRule: sortRule)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows, revision: rowsRevision, selection: selection, sortRule: sortRule)
    }

    private static func addColumn(
        _ column: StartupTableColumn,
        title: String,
        width: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        to tableView: NSTableView
    ) {
        let identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        let tableColumn = NSTableColumn(identifier: identifier)
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minimumWidth
        tableColumn.maxWidth = maximumWidth
        tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        if let sortField = column.sortField {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: sortField.rawValue,
                ascending: sortField.defaultAscending
            )
        }
        tableView.addTableColumn(tableColumn)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: StartupVirtualizedTable

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var rows: [StartupItem] = []
        private var rowIDs: [StartupItem.ID] = []
        private var appliedRowsRevision: Int?
        private var suppressSelectionCallback = false
        private var suppressSortCallback = false
        private var contextItem: StartupItem?

        init(parent: StartupVirtualizedTable) {
            self.parent = parent
        }

        func connect(tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow rowIndex: Int) -> NSTableRowView? {
            guard rows.indices.contains(rowIndex) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("startup-accessible-row")
            let rowView = (tableView.makeView(withIdentifier: identifier, owner: nil) as? StartupAccessibleRowView)
                ?? StartupAccessibleRowView()
            rowView.identifier = identifier
            rowView.configure(item: rows[rowIndex])
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
            guard rows.indices.contains(rowIndex),
                  let tableColumn,
                  let column = StartupTableColumn(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }

            let item = rows[rowIndex]
            switch column {
            case .runAtLoad:
                return booleanCell(in: tableView, identifier: "startup-run-at-load", value: item.runAtLoad, label: "Run at load")
            case .keepAlive:
                return booleanCell(in: tableView, identifier: "startup-keep-alive", value: item.keepAlive, label: "Keep alive")
            case .actions:
                let identifier = NSUserInterfaceItemIdentifier("startup-actions-cell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? StartupActionCellView)
                    ?? StartupActionCellView(identifier: identifier)
                cell.configure(item: item) { [weak self] kind, selectedItem in
                    self?.selectAndPerform(kind, item: selectedItem)
                }
                return cell
            default:
                let identifier = NSUserInterfaceItemIdentifier("startup-\(column.rawValue)-cell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? StartupTextCellView)
                    ?? StartupTextCellView(identifier: identifier)
                cell.configure(
                    text: Self.text(for: column, item: item),
                    style: column.textStyle,
                    color: column == .label
                        ? .labelColor
                        : column == .enabled && item.isEnabled == false ? .systemOrange : .secondaryLabelColor
                )
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let tableView else { return }
            let selectedID = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].id : nil
            if parent.selection != selectedID {
                parent.selection = selectedID
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressSortCallback,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let field = StartupSortField(rawValue: key) else { return }

            let rule = StartupSortRule(field: field, ascending: descriptor.ascending)
            if rule != parent.sortRule {
                parent.onSort(rule)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, rows.indices.contains(tableView.clickedRow) else {
                contextItem = nil
                return
            }

            let clickedRow = tableView.clickedRow
            contextItem = rows[clickedRow]
            suppressSelectionCallback = true
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            suppressSelectionCallback = false
            parent.selection = contextItem?.id

            menu.addItem(Self.menuItem(title: "Enable…", action: #selector(enable(_:)), target: self))
            menu.addItem(Self.menuItem(title: "Disable…", action: #selector(disable(_:)), target: self))
        }

        func apply(
            rows newRows: [StartupItem],
            revision: Int,
            selection: StartupItem.ID?,
            sortRule: StartupSortRule
        ) {
            guard let tableView else { return }
            let rowsChanged = revision != appliedRowsRevision
            let anchor = rowsChanged ? captureScrollAnchor() : nil

            if rowsChanged {
                rows = newRows
                rowIDs = newRows.map(\.id)
                appliedRowsRevision = revision
            }
            updateSortIndicator(sortRule, in: tableView)

            if rowsChanged {
                let previousSuppression = suppressSelectionCallback
                suppressSelectionCallback = true
                tableView.reloadData()
                restoreScrollAnchor(anchor)
                restoreSelection(selection, in: tableView)
                suppressSelectionCallback = previousSuppression
            } else {
                restoreSelection(selection, in: tableView)
            }
        }

        @objc private func enable(_ sender: Any?) { performContextAction(.enable) }
        @objc private func disable(_ sender: Any?) { performContextAction(.disable) }

        private func performContextAction(_ kind: LaunchActionKind) {
            guard let contextItem else { return }
            selectAndPerform(kind, item: contextItem)
        }

        private func selectAndPerform(_ kind: LaunchActionKind, item: StartupItem) {
            parent.selection = item.id
            parent.onAction(kind, item)
        }

        private func booleanCell(
            in tableView: NSTableView,
            identifier rawIdentifier: String,
            value: Bool,
            label: String
        ) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier(rawIdentifier)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? StartupBooleanCellView)
                ?? StartupBooleanCellView(identifier: identifier)
            cell.configure(value: value, label: label)
            return cell
        }

        private func captureScrollAnchor() -> StartupScrollAnchor? {
            guard let tableView, let scrollView, !rows.isEmpty else { return nil }
            let visibleRect = tableView.visibleRect
            let topRow = tableView.row(at: NSPoint(x: visibleRect.minX + 1, y: visibleRect.minY + 1))
            guard rows.indices.contains(topRow) else { return nil }
            let rowRect = tableView.rect(ofRow: topRow)
            return StartupScrollAnchor(
                id: rows[topRow].id,
                fallbackRow: topRow,
                offset: rowRect.minY - scrollView.contentView.bounds.minY
            )
        }

        private func restoreScrollAnchor(_ anchor: StartupScrollAnchor?) {
            guard let anchor, let tableView, let scrollView, !rows.isEmpty else { return }
            let row = rowIDs.firstIndex(of: anchor.id) ?? min(anchor.fallbackRow, rows.count - 1)
            let rowRect = tableView.rect(ofRow: row)
            let maximumY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
            let targetY = min(max(0, rowRect.minY - anchor.offset), maximumY)
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func restoreSelection(_ selectedID: StartupItem.ID?, in tableView: NSTableView) {
            let selectedIndex = selectedID.flatMap { rowIDs.firstIndex(of: $0) }
            let indexes = selectedIndex.map { IndexSet(integer: $0) } ?? IndexSet()
            guard indexes != tableView.selectedRowIndexes else { return }
            let previousSuppression = suppressSelectionCallback
            suppressSelectionCallback = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            suppressSelectionCallback = previousSuppression
        }

        private func updateSortIndicator(_ sortRule: StartupSortRule, in tableView: NSTableView) {
            guard tableView.sortDescriptors.first?.key != sortRule.field.rawValue
                    || tableView.sortDescriptors.first?.ascending != sortRule.ascending else { return }
            suppressSortCallback = true
            tableView.sortDescriptors = [NSSortDescriptor(key: sortRule.field.rawValue, ascending: sortRule.ascending)]
            suppressSortCallback = false
        }

        private static func text(for column: StartupTableColumn, item: StartupItem) -> String {
            switch column {
            case .label: item.label
            case .domain: item.domain.rawValue.capitalized
            case .enabled:
                switch item.isEnabled {
                case true: "Yes"
                case false: "No"
                case nil: "Unknown"
                }
            case .program: item.program ?? "Not declared"
            case .source: item.sourcePath
            case .runAtLoad, .keepAlive, .actions: ""
            }
        }

        private static func menuItem(title: String, action: Selector, target: AnyObject) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            return item
        }
    }
}

private enum StartupTableColumn: String {
    case label
    case domain
    case runAtLoad
    case keepAlive
    case enabled
    case program
    case source
    case actions

    var sortField: StartupSortField? {
        StartupSortField(rawValue: rawValue)
    }

    var textStyle: StartupTextCellView.Style {
        switch self {
        case .label: .label
        case .program, .source: .monospaced
        default: .standard
        }
    }
}

private struct StartupScrollAnchor {
    let id: StartupItem.ID
    let fallbackRow: Int
    let offset: CGFloat
}

@MainActor
private final class StartupTextCellView: NSTableCellView {
    enum Style {
        case label
        case standard
        case monospaced
    }

    private let valueLabel = NSTextField(labelWithString: "")
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let standardFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let monospacedFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 1
        addSubview(valueLabel)
        textField = valueLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        valueLabel.frame = bounds.insetBy(dx: 5, dy: 5)
    }

    func configure(text: String, style: Style, color: NSColor) {
        if valueLabel.stringValue != text {
            valueLabel.stringValue = text
        }
        if valueLabel.toolTip != text {
            valueLabel.toolTip = text
        }
        if valueLabel.textColor != color {
            valueLabel.textColor = color
        }
        let font: NSFont = switch style {
        case .label:
            Self.labelFont
        case .standard:
            Self.standardFont
        case .monospaced:
            Self.monospacedFont
        }
        if valueLabel.font != font {
            valueLabel.font = font
        }
    }
}

@MainActor
private final class StartupBooleanCellView: NSTableCellView {
    private let indicatorView = NSImageView()
    private static let yesImage = NSImage(
        systemSymbolName: "checkmark",
        accessibilityDescription: "Yes"
    )
    private static let noImage = NSImage(
        systemSymbolName: "minus",
        accessibilityDescription: "No"
    )

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        indicatorView.imageScaling = .scaleProportionallyDown
        addSubview(indicatorView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        indicatorView.frame = NSRect(
            x: floor((bounds.width - 15) / 2),
            y: floor((bounds.height - 15) / 2),
            width: 15,
            height: 15
        )
    }

    func configure(value: Bool, label: String) {
        let image = value ? Self.yesImage : Self.noImage
        if indicatorView.image !== image {
            indicatorView.image = image
        }
        let tint: NSColor = value ? .systemGreen : .secondaryLabelColor
        if indicatorView.contentTintColor != tint {
            indicatorView.contentTintColor = tint
        }
    }
}

@MainActor
private final class StartupActionCellView: NSTableCellView {
    private let button = NSButton()
    private var item: StartupItem?
    private var onAction: ((LaunchActionKind, StartupItem) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Startup service actions")
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(showMenu(_:))
        addSubview(button)
        button.setAccessibilityLabel("Startup service actions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        button.frame = NSRect(
            x: floor((bounds.width - 26) / 2),
            y: floor((bounds.height - 24) / 2),
            width: 26,
            height: 24
        )
    }

    func configure(item: StartupItem, onAction: @escaping (LaunchActionKind, StartupItem) -> Void) {
        self.item = item
        self.onAction = onAction
        let toolTip = "Actions for \(item.label)"
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Startup service actions")
        let enable = NSMenuItem(title: "Enable…", action: #selector(enable(_:)), keyEquivalent: "")
        enable.target = self
        menu.addItem(enable)
        let disable = NSMenuItem(title: "Disable…", action: #selector(disable(_:)), keyEquivalent: "")
        disable.target = self
        menu.addItem(disable)
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY), in: sender)
    }

    @objc private func enable(_ sender: Any?) { perform(.enable) }
    @objc private func disable(_ sender: Any?) { perform(.disable) }

    private func perform(_ kind: LaunchActionKind) {
        guard let item else { return }
        onAction?(kind, item)
    }

}
