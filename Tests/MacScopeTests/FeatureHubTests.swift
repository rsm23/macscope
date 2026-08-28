import Testing
@testable import MacScope

@Suite("Feature hub configuration")
struct FeatureHubTests {
    @Test("Everything enables every optional module and keeps Sound available")
    func everythingPreset() {
        let stored = UtilityFeatureStore.apply(.everything)
        #expect(UtilityFeatureStore.enabledModules(from: stored) == Set(UtilityFeatureModule.allCases))
        #expect(UtilityTab.enabled(from: stored) == UtilityTab.allCases)
        #expect(UtilityTab.enabled(from: stored).contains(.sound))
    }

    @Test("Battery and quiet removes background-heavy modules")
    func batteryAndQuietPreset() {
        let stored = UtilityFeatureStore.apply(.batteryAndQuiet)
        #expect(UtilityFeatureStore.enabledModules(from: stored) == [.notes, .power])
        #expect(UtilityTab.enabled(from: stored) == [.sound, .notes, .power])
    }

    @Test("Individual toggles round trip through stable storage")
    func individualToggleRoundTrip() {
        var stored = UtilityFeatureStore.apply(.everything)
        stored = UtilityFeatureStore.setEnabled(false, module: .capture, stored: stored)
        stored = UtilityFeatureStore.setEnabled(false, module: .windows, stored: stored)
        #expect(!UtilityFeatureStore.isEnabled(.capture, stored: stored))
        #expect(!UtilityFeatureStore.isEnabled(.windows, stored: stored))
        #expect(UtilityFeatureStore.isEnabled(.clipboard, stored: stored))

        stored = UtilityFeatureStore.setEnabled(true, module: .capture, stored: stored)
        #expect(UtilityFeatureStore.isEnabled(.capture, stored: stored))
        #expect(!UtilityFeatureStore.isEnabled(.windows, stored: stored))
    }

    @Test("Unknown stored identifiers do not hide valid modules")
    func ignoresUnknownIdentifiers() {
        #expect(UtilityFeatureStore.disabledModules(from: "future-module") == [])
        #expect(UtilityFeatureStore.enabledModules(from: "future-module") == Set(UtilityFeatureModule.allCases))
    }
}
