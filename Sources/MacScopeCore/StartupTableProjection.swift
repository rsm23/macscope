import Foundation

public enum StartupSortField: String, CaseIterable, Sendable {
    case label
    case domain
    case runAtLoad
    case keepAlive
    case enabled
    case program
    case source

    public var defaultAscending: Bool {
        switch self {
        case .label, .domain, .program, .source:
            true
        case .runAtLoad, .keepAlive, .enabled:
            false
        }
    }
}

public struct StartupSortRule: Equatable, Sendable {
    public var field: StartupSortField
    public var ascending: Bool

    public static let defaultRule = StartupSortRule(field: .label, ascending: true)

    public init(field: StartupSortField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    public func areInIncreasingOrder(_ lhs: StartupItem, _ rhs: StartupItem) -> Bool {
        let primary: ComparisonResult
        switch field {
        case .label:
            primary = lhs.label.localizedStandardCompare(rhs.label)
        case .domain:
            primary = lhs.domain.rawValue.localizedStandardCompare(rhs.domain.rawValue)
        case .runAtLoad:
            primary = Self.compare(lhs.runAtLoad ? 1 : 0, rhs.runAtLoad ? 1 : 0)
        case .keepAlive:
            primary = Self.compare(lhs.keepAlive ? 1 : 0, rhs.keepAlive ? 1 : 0)
        case .enabled:
            primary = Self.compare(Self.enabledRank(lhs.isEnabled), Self.enabledRank(rhs.isEnabled))
        case .program:
            primary = (lhs.program ?? "").localizedStandardCompare(rhs.program ?? "")
        case .source:
            primary = lhs.sourcePath.localizedStandardCompare(rhs.sourcePath)
        }

        if primary != .orderedSame {
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }

        let labelOrder = lhs.label.localizedStandardCompare(rhs.label)
        if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private static func enabledRank(_ enabled: Bool?) -> Int {
        switch enabled {
        case true: 2
        case false: 1
        case nil: 0
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

public struct StartupDomainSummary: Equatable, Sendable {
    public let domain: StartupDomain
    public let total: Int
    public let enabled: Int
    public let disabled: Int
    public let unknown: Int

    public init(domain: StartupDomain, total: Int, enabled: Int, disabled: Int, unknown: Int) {
        self.domain = domain
        self.total = total
        self.enabled = enabled
        self.disabled = disabled
        self.unknown = unknown
    }
}

public struct StartupVisualSummary: Equatable, Sendable {
    public let total: Int
    public let runAtLoad: Int
    public let keepAlive: Int
    public let domains: [StartupDomainSummary]

    public static let empty = StartupVisualSummary(total: 0, runAtLoad: 0, keepAlive: 0, domains: [])

    public init(total: Int, runAtLoad: Int, keepAlive: Int, domains: [StartupDomainSummary]) {
        self.total = total
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.domains = domains
    }

    public func summary(for domain: StartupDomain) -> StartupDomainSummary {
        domains.first(where: { $0.domain == domain })
            ?? StartupDomainSummary(domain: domain, total: 0, enabled: 0, disabled: 0, unknown: 0)
    }
}

public struct StartupTablePresentation: Equatable, Sendable {
    public let rows: [StartupItem]
    public let summary: StartupVisualSummary

    public static let empty = StartupTablePresentation(rows: [], summary: .empty)

    public init(rows: [StartupItem], summary: StartupVisualSummary) {
        self.rows = rows
        self.summary = summary
    }
}

public enum StartupTableProjection {
    public static func build(
        items: [StartupItem],
        query: String,
        sortRule: StartupSortRule
    ) -> StartupTablePresentation {
        guard !Task.isCancelled else { return .empty }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [StartupItem]
        if normalizedQuery.isEmpty {
            filtered = items
        } else {
            var matches: [StartupItem] = []
            matches.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return .empty }
                if item.label.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.domain.rawValue.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.sourcePath.localizedCaseInsensitiveContains(normalizedQuery)
                    || (item.program?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                    || item.arguments.contains(where: { $0.localizedCaseInsensitiveContains(normalizedQuery) })
                    || Self.enabledText(item.isEnabled).localizedCaseInsensitiveContains(normalizedQuery) {
                    matches.append(item)
                }
            }
            filtered = matches
        }

        guard !Task.isCancelled else { return .empty }
        let rows = filtered.sorted(by: sortRule.areInIncreasingOrder)
        guard !Task.isCancelled else { return .empty }
        return StartupTablePresentation(
            rows: rows,
            summary: summary(for: items)
        )
    }

    private static func summary(for items: [StartupItem]) -> StartupVisualSummary {
        var totals = Dictionary(uniqueKeysWithValues: StartupDomain.allCases.map { domain in
            (domain, (total: 0, enabled: 0, disabled: 0, unknown: 0))
        })
        var runAtLoad = 0
        var keepAlive = 0

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return .empty }
            var domain = totals[item.domain] ?? (0, 0, 0, 0)
            domain.total += 1
            switch item.isEnabled {
            case true: domain.enabled += 1
            case false: domain.disabled += 1
            case nil: domain.unknown += 1
            }
            totals[item.domain] = domain
            if item.runAtLoad { runAtLoad += 1 }
            if item.keepAlive { keepAlive += 1 }
        }

        return StartupVisualSummary(
            total: items.count,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            domains: StartupDomain.allCases.map { domain in
                let counts = totals[domain] ?? (0, 0, 0, 0)
                return StartupDomainSummary(
                    domain: domain,
                    total: counts.total,
                    enabled: counts.enabled,
                    disabled: counts.disabled,
                    unknown: counts.unknown
                )
            }
        )
    }

    private static func enabledText(_ enabled: Bool?) -> String {
        switch enabled {
        case true: "enabled yes"
        case false: "disabled no"
        case nil: "unknown"
        }
    }
}

public enum StartupSelection {
    /// Retains a logical selection through filtering, sorting, and refreshed
    /// payload values. It clears only when the source definition disappears.
    public static func retained(_ selection: StartupItem.ID?, in items: [StartupItem]) -> StartupItem.ID? {
        guard let selection else { return nil }
        return items.contains(where: { $0.id == selection }) ? selection : nil
    }
}
