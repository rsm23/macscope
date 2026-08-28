import Foundation
import Testing
@testable import MacScope

@Suite("Global shortcut configuration")
struct GlobalShortcutSettingsTests {
    @Test("Default global shortcuts are unique and round trip")
    func defaultsAreUniqueAndCodable() throws {
        let defaults = GlobalShortcutAction.allCases.map(\.defaultConfiguration)
        let signatures = defaults.map { "\($0.modifier.rawValue):\($0.keyCode)" }
        #expect(Set(signatures).count == signatures.count)

        for value in defaults {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(GlobalShortcutConfiguration.self, from: data) == value)
            #expect(!value.displayLabel.isEmpty)
        }
    }
}
