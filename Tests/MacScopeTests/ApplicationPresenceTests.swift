import AppKit
import Testing
@testable import MacScope

@MainActor
@Test("Closing the main window enters menu-bar-only mode and reopening restores the Dock")
func mainWindowPresenceTransitionsActivationPolicy() {
    var appliedPolicies: [NSApplication.ActivationPolicy] = []
    let controller = ApplicationPresenceController { policy in
        appliedPolicies.append(policy)
        return true
    }

    controller.mainWindowDidClose()
    controller.mainWindowWillOpen()

    #expect(appliedPolicies == [.accessory, .regular])
}
