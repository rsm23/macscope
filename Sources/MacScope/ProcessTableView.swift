import AppKit
import MacScopeCore
import SwiftUI

enum ProcessSortField: String, CaseIterable, Sendable {
    case name
    case pid
    case cpuPercent
    case residentMemory
    case threads
    case bytesRead
    case bytesWritten
    case state

    var defaultAscending: Bool {
        switch self {
        case .name, .pid, .state: true
        case .cpuPercent, .residentMemory, .threads, .bytesRead, .bytesWritten: false
        }
    }
}

struct ProcessSortRule: Equatable, Sendable {
    var field: ProcessSortField
    var ascending: Bool

    static let defaultRule = ProcessSortRule(field: .cpuPercent, ascending: false)

    func areInIncreasingOrder(_ lhs: ProcessTableRow, _ rhs: ProcessTableRow) -> Bool {
        let primaryOrder: ComparisonResult
        switch field {
        case .name:
            primaryOrder = lhs.name.localizedStandardCompare(rhs.name)
        case .pid:
            primaryOrder = Self.compare(lhs.pid, rhs.pid)
        case .cpuPercent:
            primaryOrder = Self.compare(lhs.cpuPercent, rhs.cpuPercent)
        case .residentMemory:
            primaryOrder = Self.compare(lhs.residentMemory, rhs.residentMemory)
        case .threads:
            primaryOrder = Self.compare(lhs.threads, rhs.threads)
        case .bytesRead:
            primaryOrder = Self.compare(lhs.bytesRead, rhs.bytesRead)
        case .bytesWritten:
            primaryOrder = Self.compare(lhs.bytesWritten, rhs.bytesWritten)
        case .state:
            primaryOrder = lhs.state.localizedStandardCompare(rhs.state)
        }

        if primaryOrder != .orderedSame {
            return ascending ? primaryOrder == .orderedAscending : primaryOrder == .orderedDescending
        }

        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.pid < rhs.pid
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

struct ProcessTableRow: Identifiable, Hashable, Sendable {
    let node: ProcessTreeNode
    let depth: Int
    let isExpanded: Bool
    let usesGroupTotals: Bool

    var id: ProcessTreeNode.ID { node.id }
    var process: ProcessSnapshot { node.process }
    var name: String { node.name }
    var pid: Int32 { node.pid }
    var cpuPercent: Double { usesGroupTotals ? node.cpuPercent : node.process.cpuPercent }
    var residentMemory: UInt64 { usesGroupTotals ? node.residentMemory : node.process.residentMemory }
    var threads: Int32 { node.threads }
    var bytesRead: UInt64 { node.bytesRead }
    var bytesWritten: UInt64 { node.bytesWritten }
    var state: String { node.state }
    var descendantCount: Int { node.descendantCount }
    var hasChildren: Bool { node.children != nil }

    var groupTotalsHelp: String {
        guard usesGroupTotals else { return "Value reported by this process" }
        return "Combined value for this process and \(descendantCount) descendant process\(descendantCount == 1 ? "" : "es"). Resident memory is summed and may count shared pages more than once."
    }
}

/// An AppKit-backed process table. NSTableView creates views only for visible rows,
/// which keeps live telemetry updates independent from the size of the process list.
struct ProcessVirtualizedTable: NSViewRepresentable {
    let rows: [ProcessTableRow]
    @Binding var selection: Set<Int32>
    let sortRule: ProcessSortRule
    let disclosureEnabled: Bool
    let onSort: (ProcessSortRule) -> Void
    let onToggleExpansion: (Int32) -> Void
    let onAction: (ProcessActionKind, ProcessSnapshot) -> Void

    init(
        rows: [ProcessTableRow],
        selection: Binding<Set<Int32>>,
        sortRule: ProcessSortRule,
        disclosureEnabled: Bool = true,
        onSort: @escaping (ProcessSortRule) -> Void,
        onToggleExpansion: @escaping (Int32) -> Void,
        onAction: @escaping (ProcessActionKind, ProcessSnapshot) -> Void
    ) {
        self.rows = rows
        _selection = selection
        self.sortRule = sortRule
        self.disclosureEnabled = disclosureEnabled
        self.onSort = onSort
        self.onToggleExpansion = onToggleExpansion
        self.onAction = onAction
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.backgroundColor = .clear

        Self.addColumn(.name, title: "Process", width: 270, minimumWidth: 170, maximumWidth: 1_000, to: tableView)
        Self.addColumn(.pid, title: "PID", width: 60, minimumWidth: 52, maximumWidth: 85, to: tableView)
        Self.addColumn(.cpuPercent, title: "CPU", width: 72, minimumWidth: 62, maximumWidth: 110, to: tableView)
        Self.addColumn(.residentMemory, title: "Memory", width: 95, minimumWidth: 78, maximumWidth: 150, to: tableView)
        Self.addColumn(.threads, title: "Threads", width: 70, minimumWidth: 62, maximumWidth: 105, to: tableView)
        Self.addColumn(.bytesRead, title: "Read", width: 85, minimumWidth: 72, maximumWidth: 140, to: tableView)
        Self.addColumn(.bytesWritten, title: "Written", width: 85, minimumWidth: 72, maximumWidth: 140, to: tableView)
        Self.addColumn(.state, title: "State", width: 80, minimumWidth: 70, maximumWidth: 150, to: tableView)

        let menu = NSMenu(title: "Process")
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.connect(tableView: tableView, scrollView: scrollView)
        context.coordinator.apply(rows: rows, selection: selection, sortRule: sortRule)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows, selection: selection, sortRule: sortRule)
    }

    private static func addColumn(
        _ field: ProcessSortField,
        title: String,
        width: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        to tableView: NSTableView
    ) {
        let identifier = NSUserInterfaceItemIdentifier(field.rawValue)
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minimumWidth
        column.maxWidth = maximumWidth
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: field.defaultAscending)
        tableView.addTableColumn(column)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ProcessVirtualizedTable

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var rows: [ProcessTableRow] = []
        private var rowIDs: [Int32] = []
        private var suppressSelectionCallback = false
        private var suppressSortCallback = false
        private var contextProcess: ProcessSnapshot?

        init(parent: ProcessVirtualizedTable) {
            self.parent = parent
        }

        func connect(tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
            guard rowIndex >= 0, rowIndex < rows.count, let tableColumn,
                  let field = ProcessSortField(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }

            let row = rows[rowIndex]
            if field == .name {
                let identifier = NSUserInterfaceItemIdentifier("process-name-cell")
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ProcessNameCellView)
                    ?? ProcessNameCellView(identifier: identifier)
                cell.configure(
                    row: row,
                    disclosureEnabled: parent.disclosureEnabled,
                    onToggle: parent.onToggleExpansion
                )
                return cell
            }

            let identifier = NSUserInterfaceItemIdentifier("process-\(field.rawValue)-cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ProcessMetricCellView)
                ?? ProcessMetricCellView(identifier: identifier)
            cell.configure(text: Self.text(for: field, row: row), field: field, row: row)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback, let tableView else { return }
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { index in
                rows.indices.contains(index) ? rows[index].id : nil
            })
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressSortCallback,
                  let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let field = ProcessSortField(rawValue: key) else { return }

            let rule = ProcessSortRule(field: field, ascending: descriptor.ascending)
            if rule != parent.sortRule {
                parent.onSort(rule)
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  rows.indices.contains(tableView.clickedRow) else {
                contextProcess = nil
                return
            }

            contextProcess = rows[tableView.clickedRow].process
            menu.addItem(Self.menuItem(title: "Terminate", action: #selector(terminate(_:)), target: self))
            menu.addItem(Self.menuItem(title: "Force Quit", action: #selector(forceQuit(_:)), target: self))
            menu.addItem(.separator())
            menu.addItem(Self.menuItem(title: "Stop", action: #selector(stop(_:)), target: self))
            menu.addItem(Self.menuItem(title: "Resume", action: #selector(resume(_:)), target: self))
        }

        @objc private func terminate(_ sender: Any?) { perform(.terminate) }
        @objc private func forceQuit(_ sender: Any?) { perform(.kill) }
        @objc private func stop(_ sender: Any?) { perform(.stop) }
        @objc private func resume(_ sender: Any?) { perform(.resume) }

        func apply(rows newRows: [ProcessTableRow], selection: Set<Int32>, sortRule: ProcessSortRule) {
            guard let tableView else { return }
            let newIDs = newRows.map(\.id)
            // A live metric sort commonly changes only row order. NSTableView's
            // row count and identity set are still valid in that case, so a full
            // reload would needlessly destroy accessibility/selection objects and
            // interrupt an in-progress scroll or click. Reserve structural reloads
            // for actual process/group membership changes.
            let structureChanged = newIDs.count != rowIDs.count || Set(newIDs) != Set(rowIDs)
            let anchor = structureChanged ? captureScrollAnchor() : nil

            rows = newRows
            rowIDs = newIDs
            updateSortIndicator(sortRule, in: tableView)

            if structureChanged {
                tableView.reloadData()
                restoreScrollAnchor(anchor)
            } else {
                reloadVisibleRows(in: tableView)
            }
            restoreSelection(selection, in: tableView)
        }

        private func perform(_ kind: ProcessActionKind) {
            guard let contextProcess else { return }
            parent.onAction(kind, contextProcess)
        }

        private func captureScrollAnchor() -> ScrollAnchor? {
            guard let tableView, let scrollView, !rows.isEmpty else { return nil }
            let visibleRect = tableView.visibleRect
            let topRow = tableView.row(at: NSPoint(x: visibleRect.minX + 1, y: visibleRect.minY + 1))
            guard rows.indices.contains(topRow) else { return nil }
            let rowRect = tableView.rect(ofRow: topRow)
            return ScrollAnchor(id: rows[topRow].id, fallbackRow: topRow, offset: rowRect.minY - scrollView.contentView.bounds.minY)
        }

        private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
            guard let anchor, let tableView, let scrollView, !rows.isEmpty else { return }
            let targetRow = rowIDs.firstIndex(of: anchor.id) ?? min(anchor.fallbackRow, rows.count - 1)
            let rowRect = tableView.rect(ofRow: targetRow)
            let documentHeight = tableView.bounds.height
            let viewportHeight = scrollView.contentView.bounds.height
            let maximumY = max(0, documentHeight - viewportHeight)
            let targetY = min(max(0, rowRect.minY - anchor.offset), maximumY)
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }
            let start = max(0, visibleRange.location)
            let end = min(rows.count, visibleRange.location + visibleRange.length)
            guard start < end else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: start..<end),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }

        private func restoreSelection(_ selectedIDs: Set<Int32>, in tableView: NSTableView) {
            let indexes = IndexSet(rowIDs.indices.filter { selectedIDs.contains(rowIDs[$0]) })
            guard indexes != tableView.selectedRowIndexes else { return }
            suppressSelectionCallback = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            suppressSelectionCallback = false
        }

        private func updateSortIndicator(_ sortRule: ProcessSortRule, in tableView: NSTableView) {
            guard tableView.sortDescriptors.first?.key != sortRule.field.rawValue
                    || tableView.sortDescriptors.first?.ascending != sortRule.ascending else { return }
            suppressSortCallback = true
            tableView.sortDescriptors = [NSSortDescriptor(key: sortRule.field.rawValue, ascending: sortRule.ascending)]
            suppressSortCallback = false
        }

        private static func text(for field: ProcessSortField, row: ProcessTableRow) -> String {
            switch field {
            case .name: row.name
            case .pid: row.pid.formatted()
            case .cpuPercent: "\(row.cpuPercent.formatted(.number.precision(.fractionLength(0...1))))%"
            case .residentMemory: ByteCountFormatter.macScope(row.residentMemory)
            case .threads: row.threads.formatted()
            case .bytesRead: ByteCountFormatter.macScope(row.bytesRead)
            case .bytesWritten: ByteCountFormatter.macScope(row.bytesWritten)
            case .state: row.state
            }
        }

        private static func menuItem(title: String, action: Selector, target: AnyObject) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            return item
        }
    }
}

private struct ScrollAnchor {
    let id: Int32
    let fallbackRow: Int
    let offset: CGFloat
}

@MainActor
private final class ProcessNameCellView: NSTableCellView {
    private let disclosureButton = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let childBadge = NSTextField(labelWithString: "")
    private var depth = 0
    private var representedProcessID: Int32?
    private var toggleAction: ((Int32) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        pathLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        childBadge.font = .systemFont(ofSize: 9, weight: .medium)
        childBadge.textColor = .secondaryLabelColor
        childBadge.alignment = .center
        childBadge.wantsLayer = true
        childBadge.layer?.cornerRadius = 7
        childBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.10).cgColor

        addSubview(disclosureButton)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(pathLabel)
        addSubview(childBadge)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(row: ProcessTableRow, disclosureEnabled: Bool, onToggle: @escaping (Int32) -> Void) {
        depth = row.depth
        representedProcessID = row.id
        toggleAction = onToggle

        disclosureButton.isHidden = !row.hasChildren
        disclosureButton.isEnabled = disclosureEnabled
        disclosureButton.image = NSImage(
            systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: row.isExpanded ? "Collapse process group" : "Expand process group"
        )
        disclosureButton.toolTip = disclosureEnabled
            ? (row.isExpanded ? "Collapse child processes" : "Show child processes")
            : "Matching process groups are expanded while filtering"

        iconView.image = GenericProcessIcons.icon(for: row.process.executablePath)
        nameLabel.stringValue = row.name
        pathLabel.stringValue = row.process.executablePath ?? "Details restricted"
        childBadge.isHidden = row.descendantCount == 0
        childBadge.stringValue = "\(row.descendantCount) child\(row.descendantCount == 1 ? "" : "ren")"
        toolTip = row.usesGroupTotals ? row.groupTotalsHelp : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let indentation = CGFloat(depth) * 14
        let leading = indentation + 2
        disclosureButton.frame = NSRect(x: leading, y: 11, width: 16, height: 18)
        iconView.frame = NSRect(x: leading + 21, y: 10, width: 20, height: 20)

        let textLeading = leading + 48
        let trailing: CGFloat = 6
        let availableWidth = max(0, bounds.width - textLeading - trailing)
        let badgeWidth = childBadge.isHidden ? 0 : min(86, childBadge.intrinsicContentSize.width + 12)
        let badgeSpacing: CGFloat = childBadge.isHidden ? 0 : 6
        let nameWidth = max(20, availableWidth - badgeWidth - badgeSpacing)
        nameLabel.frame = NSRect(x: textLeading, y: 20, width: nameWidth, height: 16)
        pathLabel.frame = NSRect(x: textLeading, y: 5, width: availableWidth, height: 13)
        childBadge.frame = NSRect(x: textLeading + nameWidth + badgeSpacing, y: 20, width: badgeWidth, height: 15)
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let representedProcessID else { return }
        toggleAction?(representedProcessID)
    }
}

@MainActor
private final class ProcessMetricCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(text: String, field: ProcessSortField, row: ProcessTableRow) {
        label.stringValue = text
        label.alignment = field == .state ? .left : .right
        label.textColor = field == .state ? .secondaryLabelColor : .labelColor
        let weight: NSFont.Weight = row.usesGroupTotals && (field == .cpuPercent || field == .residentMemory)
            ? .semibold
            : .regular
        label.font = field == .state
            ? .systemFont(ofSize: 12, weight: weight)
            : .monospacedDigitSystemFont(ofSize: 12, weight: weight)
        toolTip = row.usesGroupTotals && (field == .cpuPercent || field == .residentMemory)
            ? row.groupTotalsHelp
            : nil
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 3, dy: 10)
    }
}

@MainActor
private enum GenericProcessIcons {
    private static let application = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
    private static let executable = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Executable")

    static func icon(for executablePath: String?) -> NSImage? {
        guard let executablePath else { return executable }
        let lowercased = executablePath.lowercased()
        return lowercased.contains(".app/") || lowercased.hasSuffix(".app") ? application : executable
    }
}
