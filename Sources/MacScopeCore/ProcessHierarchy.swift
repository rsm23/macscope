import Foundation

/// A process and the child processes that belong to it in the live process tree.
public struct ProcessTreeNode: Identifiable, Hashable, Sendable {
    public var id: ProcessSnapshot.ID { process.id }
    public let process: ProcessSnapshot
    public let children: [ProcessTreeNode]?
    public let cpuPercent: Double
    public let residentMemory: UInt64
    public let descendantCount: Int

    public init(process: ProcessSnapshot, children: [ProcessTreeNode]? = nil) {
        let children = children?.isEmpty == true ? nil : children
        self.process = process
        self.children = children
        self.cpuPercent = children?.reduce(process.cpuPercent) { $0 + $1.cpuPercent } ?? process.cpuPercent
        self.residentMemory = children?.reduce(process.residentMemory) {
            Self.saturatingAdd($0, $1.residentMemory)
        } ?? process.residentMemory
        self.descendantCount = children?.reduce(0) { $0 + 1 + $1.descendantCount } ?? 0
    }

    public var name: String { process.name }
    public var pid: Int32 { process.pid }
    public var threads: Int32 { process.threads }
    public var bytesRead: UInt64 { process.bytesRead }
    public var bytesWritten: UInt64 { process.bytesWritten }
    public var state: String { process.state }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

public enum ProcessHierarchy {
    /// Builds a stable forest from PPID relationships. Processes whose parent is
    /// launchd remain top-level groups so the entire Mac is not hidden beneath PID 1.
    public static func build(from processes: [ProcessSnapshot], matching query: String = "") -> [ProcessTreeNode] {
        var processByPID: [Int32: ProcessSnapshot] = [:]
        for process in processes {
            processByPID[process.pid] = process
        }

        let uniqueProcesses = processByPID.values.sorted(by: processOrder)
        let rootIDs = Set(uniqueProcesses.lazy.filter { process in
            process.pid <= 1
                || process.parentPID <= 1
                || process.parentPID == process.pid
                || processByPID[process.parentPID] == nil
        }.map(\.pid))

        let childrenByParent = Dictionary(grouping: uniqueProcesses, by: \.parentPID)
        var visited = Set<Int32>()

        func makeNode(_ process: ProcessSnapshot) -> ProcessTreeNode {
            visited.insert(process.pid)
            let childProcesses = (childrenByParent[process.pid] ?? [])
                .filter { !rootIDs.contains($0.pid) && !visited.contains($0.pid) }
                .sorted(by: processOrder)
            let children = childProcesses.map(makeNode)
            return ProcessTreeNode(process: process, children: children)
        }

        var forest: [ProcessTreeNode] = []
        for process in uniqueProcesses where rootIDs.contains(process.pid) && !visited.contains(process.pid) {
            forest.append(makeNode(process))
        }

        // Malformed or cyclic relationships may not produce a natural root. Keep
        // every process visible by promoting the first unvisited member to a group.
        for process in uniqueProcesses where !visited.contains(process.pid) {
            forest.append(makeNode(process))
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return forest }
        return forest.compactMap { filteredNode($0, matching: normalizedQuery) }
    }

    /// Captures the current preorder position of every process. Apply these
    /// ranks to later snapshots to keep a live table visually stable.
    public static func stableRanks(for nodes: [ProcessTreeNode]) -> [ProcessSnapshot.ID: Int] {
        var ranks: [ProcessSnapshot.ID: Int] = [:]
        var nextRank = 0

        func visit(_ node: ProcessTreeNode) {
            ranks[node.id] = nextRank
            nextRank += 1
            node.children?.forEach(visit)
        }

        nodes.forEach(visit)
        return ranks
    }

    /// Restores the captured sibling order recursively while retaining the
    /// newest process samples. Newly launched processes follow ranked rows.
    public static func applyingStableOrder(
        to nodes: [ProcessTreeNode],
        ranks: [ProcessSnapshot.ID: Int]
    ) -> [ProcessTreeNode] {
        let refreshed = nodes.map { node in
            ProcessTreeNode(
                process: node.process,
                children: node.children.map { applyingStableOrder(to: $0, ranks: ranks) }
            )
        }

        return refreshed.enumerated().sorted { lhs, rhs in
            let lhsRank = ranks[lhs.element.id]
            let rhsRank = ranks[rhs.element.id]
            switch (lhsRank, rhsRank) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func filteredNode(_ node: ProcessTreeNode, matching query: String) -> ProcessTreeNode? {
        if matches(node.process, query: query) {
            return node
        }

        let matchingChildren = node.children?.compactMap { filteredNode($0, matching: query) } ?? []
        guard !matchingChildren.isEmpty else { return nil }
        return ProcessTreeNode(process: node.process, children: matchingChildren)
    }

    private static func matches(_ process: ProcessSnapshot, query: String) -> Bool {
        process.name.localizedCaseInsensitiveContains(query)
            || String(process.pid).localizedCaseInsensitiveContains(query)
            || String(process.parentPID).localizedCaseInsensitiveContains(query)
            || String(process.userID).localizedCaseInsensitiveContains(query)
            || process.state.localizedCaseInsensitiveContains(query)
            || (process.executablePath?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private static func processOrder(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        return nameOrder == .orderedSame ? lhs.pid < rhs.pid : nameOrder == .orderedAscending
    }
}
