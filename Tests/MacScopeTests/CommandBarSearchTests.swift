import Testing
@testable import MacScope

@Suite("Command Bar search")
struct CommandBarSearchTests {
    @Test("Search matches every word across title and subtitle")
    func tokenizedSearch() {
        #expect(CommandBarService.matchesSearch(
            "report bug",
            title: "Report a bug",
            subtitle: "Review a diagnostic draft before opening it in Mail"
        ))
        #expect(CommandBarService.matchesSearch(
            "diagnostic bug",
            title: "Report a bug",
            subtitle: "Review a diagnostic draft before opening it in Mail"
        ))
    }

    @Test("Search remains case insensitive and rejects missing words")
    func caseAndMissingTokens() {
        #expect(CommandBarService.matchesSearch(
            "FEATURE MAIL",
            title: "Suggest a feature",
            subtitle: "Review an idea draft before opening it in Mail"
        ))
        #expect(!CommandBarService.matchesSearch(
            "feature github",
            title: "Suggest a feature",
            subtitle: "Review an idea draft before opening it in Mail"
        ))
    }
}
