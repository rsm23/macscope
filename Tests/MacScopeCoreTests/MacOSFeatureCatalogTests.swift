import Testing
@testable import MacScopeCore

@Suite("macOS feature catalog")
struct MacOSFeatureCatalogTests {
    @Test("Catalog is large, stable, and free of duplicate identifiers")
    func catalogIdentityAndScale() {
        let catalog = MacOSFeatureCatalog.all
        #expect(catalog.count >= 100)
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        #expect(Set(catalog.map(\.category)) == Set(MacOSFeatureCategory.allCases))
    }

    @Test("Every writable preference is typed and has an explicit inverse")
    func writablePreferencesAreTypedAndReversible() {
        for descriptor in MacOSFeatureCatalog.all {
            #expect(!descriptor.id.isEmpty)
            #expect(!descriptor.title.isEmpty)
            #expect(descriptor.minimumOSMajor >= 14)
            if let maximum = descriptor.maximumOSMajor {
                #expect(maximum >= descriptor.minimumOSMajor)
            }

            switch descriptor.mechanism {
            case .preference(let preference):
                #expect(!preference.domain.isEmpty)
                #expect(!preference.key.isEmpty)
                #expect(preference.enabledValue != preference.disabledValue)
                #expect(descriptor.tier != .restricted)
            case .manual(let reason, let settingsURL):
                #expect(!reason.isEmpty)
                #expect(settingsURL?.hasPrefix("x-apple.systempreferences:") == true)
                #expect(descriptor.tier != .restricted)
            case .restricted(let reason):
                #expect(descriptor.tier == .restricted)
                #expect(!reason.isEmpty)
            }
        }
    }

    @Test("Legacy Finder Boolean strings normalize without losing rollback representation")
    func legacyFinderBooleanStrings() {
        let storedTrue = MacOSFeaturePreferenceValue.string("YES")
        let storedFalse = MacOSFeaturePreferenceValue.string("0")
        #expect(storedTrue.normalized(for: .boolean(true)) == .boolean(true))
        #expect(storedFalse.normalized(for: .boolean(true)) == .boolean(false))
        #expect(storedTrue == .string("YES"))
    }

    @Test("Unsupported and restricted entries never become writable")
    func unavailableEntriesRemainUnavailable() async {
        let unsupported = MacOSFeatureDescriptor(
            id: "test.future",
            title: "Future feature",
            summary: "Test",
            category: .appearance,
            icon: "clock",
            tier: .advanced,
            minimumOSMajor: 999,
            mechanism: .preference(MacOSFeaturePreference(
                domain: "com.example.test",
                key: "Enabled",
                enabledValue: .boolean(true),
                disabledValue: .boolean(false),
                defaultValue: .boolean(false)
            )),
            provenance: "Test"
        )
        let restricted = MacOSFeatureDescriptor(
            id: "test.restricted",
            title: "Restricted feature",
            summary: "Test",
            category: .security,
            icon: "lock",
            tier: .restricted,
            mechanism: .restricted(reason: "Not allowed"),
            provenance: "Test"
        )
        let manager = MacOSFeatureManager(catalog: [unsupported, restricted], operatingSystemMajor: 26)
        let statuses = await manager.refresh()
        #expect(statuses.first { $0.id == unsupported.id }?.availability == .unsupported)
        #expect(statuses.first { $0.id == restricted.id }?.availability == .restricted)

        do {
            _ = try await manager.setEnabled(true, descriptorID: restricted.id)
            Issue.record("A restricted feature was unexpectedly writable")
        } catch let error as MacOSFeatureError {
            if case .restricted = error { } else {
                Issue.record("Expected a restricted error, received \(error)")
            }
        } catch {
            Issue.record("Expected MacOSFeatureError, received \(error)")
        }
    }
}
