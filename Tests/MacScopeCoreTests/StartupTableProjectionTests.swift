import Testing
@testable import MacScopeCore

@Suite("Startup table projection")
struct StartupTableProjectionTests {
    @Test("Definition identity uses the source path when labels collide")
    func definitionIdentityIsUnique() {
        let agent = item(label: "com.example.shared", path: "/Library/LaunchAgents/shared.plist")
        let daemon = item(label: "com.example.shared", path: "/Library/LaunchDaemons/shared.plist")

        #expect(agent.id != daemon.id)
        #expect(agent.launchDomain == .gui)
        #expect(daemon.launchDomain == .system)
    }

    @Test("Filtering covers label, domain, program, arguments, state, and path")
    func filteringUsesEverySearchableField() {
        let items = [
            item(label: "com.example.alpha", path: "/Library/LaunchAgents/alpha.plist", program: "/usr/bin/alpha", arguments: ["--verbose"], enabled: true),
            item(label: "com.example.beta", path: "/System/Library/LaunchDaemons/beta.plist", program: "/usr/bin/beta", enabled: false, domain: .system)
        ]

        #expect(project(items, query: "alpha").map(\.label) == ["com.example.alpha"])
        #expect(project(items, query: "system").map(\.label) == ["com.example.beta"])
        #expect(project(items, query: "verbose").map(\.label) == ["com.example.alpha"])
        #expect(project(items, query: "disabled").map(\.label) == ["com.example.beta"])
        #expect(project(items, query: "LaunchDaemons").map(\.label) == ["com.example.beta"])
    }

    @Test("Every sort field is deterministic and uses stable tie breakers")
    func sortingIsDeterministic() {
        let alpha = item(label: "Alpha", path: "/a.plist", program: "/bin/z", runAtLoad: false, keepAlive: true, enabled: nil, domain: .user)
        let beta = item(label: "Beta", path: "/b.plist", program: "/bin/a", runAtLoad: true, keepAlive: false, enabled: true, domain: .system)
        let duplicate = item(label: "Alpha", path: "/c.plist", program: "/bin/m", runAtLoad: true, keepAlive: true, enabled: false, domain: .local)
        let items = [beta, duplicate, alpha]

        for field in StartupSortField.allCases {
            let rule = StartupSortRule(field: field, ascending: field.defaultAscending)
            let first = StartupTableProjection.build(items: items, query: "", sortRule: rule).rows.map(\.id)
            let second = StartupTableProjection.build(items: items.reversed(), query: "", sortRule: rule).rows.map(\.id)
            #expect(first == second)
        }
    }

    @Test("Visual counts are derived from the full collection, not the active filter")
    func summaryUsesAllDefinitions() {
        let items = [
            item(label: "Alpha", path: "/a.plist", runAtLoad: true, keepAlive: false, enabled: true, domain: .user),
            item(label: "Beta", path: "/b.plist", runAtLoad: false, keepAlive: true, enabled: false, domain: .system),
            item(label: "Gamma", path: "/c.plist", enabled: nil, domain: .system)
        ]
        let presentation = StartupTableProjection.build(items: items, query: "Alpha", sortRule: .defaultRule)

        #expect(presentation.rows.map(\.label) == ["Alpha"])
        #expect(presentation.summary.total == 3)
        #expect(presentation.summary.runAtLoad == 1)
        #expect(presentation.summary.keepAlive == 1)
        #expect(presentation.summary.summary(for: .system).total == 2)
        #expect(presentation.summary.summary(for: .system).disabled == 1)
        #expect(presentation.summary.summary(for: .system).unknown == 1)
    }

    @Test("Selection follows definition identity through sort, filter, and refreshed values")
    func selectionPersistsUntilDefinitionDisappears() {
        let original = item(label: "Beta", path: "/b.plist", program: "/bin/old", enabled: true)
        let other = item(label: "Alpha", path: "/a.plist")
        let selected = original.id

        let reversed = StartupTableProjection.build(
            items: [original, other],
            query: "",
            sortRule: StartupSortRule(field: .label, ascending: false)
        ).rows
        #expect(StartupSelection.retained(selected, in: reversed) == selected)

        let filtered = StartupTableProjection.build(items: [original, other], query: "Alpha", sortRule: .defaultRule).rows
        #expect(!filtered.contains(where: { $0.id == selected }))
        #expect(StartupSelection.retained(selected, in: [original, other]) == selected)

        let refreshed = item(label: "Beta", path: "/b.plist", program: "/bin/new", enabled: false)
        #expect(StartupSelection.retained(selected, in: [refreshed, other]) == selected)
        #expect(StartupSelection.retained(selected, in: [other]) == nil)
    }

    private func project(_ items: [StartupItem], query: String) -> [StartupItem] {
        StartupTableProjection.build(items: items, query: query, sortRule: .defaultRule).rows
    }

    private func item(
        label: String,
        path: String,
        program: String? = nil,
        arguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        enabled: Bool? = nil,
        domain: StartupDomain = .local
    ) -> StartupItem {
        StartupItem(
            label: label,
            domain: domain,
            sourcePath: path,
            program: program,
            arguments: arguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isEnabled: enabled,
            isLoaded: nil,
            availability: .available
        )
    }
}
