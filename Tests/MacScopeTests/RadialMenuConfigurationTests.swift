import Foundation
import Testing
@testable import MacScope

@Test func radialProfilesKeepIndependentActionsTargetsAndThemes() {
    var actionsJSON = ""
    var workActions = RadialMenuProfile.work.defaultActions
    workActions[0] = .customItem
    actionsJSON = RadialMenuConfigurationStore.replacing(
        profile: .work,
        actions: workActions,
        json: actionsJSON
    )
    #expect(RadialMenuConfigurationStore.actions(profile: .work, json: actionsJSON)[0] == .customItem)
    #expect(RadialMenuConfigurationStore.actions(profile: .media, json: actionsJSON) == RadialMenuProfile.media.defaultActions)

    let target = RadialMenuTarget(
        url: URL(string: "https://example.com")!,
        title: "Example",
        iconData: Data([0x00, 0x01, 0x02])
    )
    let targetsJSON = RadialMenuConfigurationStore.replacingTarget(
        profile: .work,
        index: 0,
        target: target,
        json: ""
    )
    #expect(RadialMenuConfigurationStore.target(profile: .work, index: 0, json: targetsJSON) == target)
    #expect(RadialMenuConfigurationStore.target(profile: .media, index: 0, json: targetsJSON) == nil)

    let shortcut = GlobalShortcutConfiguration(
        enabled: true,
        keyCode: 12,
        keyLabel: "Q",
        modifier: .commandOption
    )
    let shortcutsJSON = RadialMenuConfigurationStore.replacingShortcut(
        profile: .work,
        index: 2,
        shortcut: shortcut,
        json: ""
    )
    #expect(RadialMenuConfigurationStore.shortcut(profile: .work, index: 2, json: shortcutsJSON) == shortcut)

    let themesJSON = RadialMenuConfigurationStore.replacingTheme(
        profile: .work,
        theme: .purple,
        json: ""
    )
    #expect(RadialMenuConfigurationStore.theme(profile: .work, json: themesJSON) == .purple)
    #expect(RadialMenuConfigurationStore.theme(profile: .system, json: themesJSON) == .accent)
}
