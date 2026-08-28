import AVFoundation
import Testing
import UserNotifications
@testable import MacScope

struct PermissionCenterTests {
    @Test("Permission checklist covers every utility authorization")
    func permissionInventory() {
        #expect(MacScopePermissionID.allCases == [
            .accessibility,
            .inputMonitoring,
            .screenRecording,
            .microphone,
            .camera,
            .notifications,
            .automation,
            .fullDiskAccess
        ])
        #expect(MacScopePermissionID.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(MacScopePermissionID.allCases.allSatisfy { !$0.utilitySummary.isEmpty })
        #expect(MacScopePermissionID.allCases.allSatisfy { $0.settingsURL != nil })
    }

    @Test("Permission statuses expose the correct recovery action")
    func permissionActions() {
        #expect(MacScopePermissionStatus.allowed.actionLabel == "Review…")
        #expect(MacScopePermissionStatus.notAllowed.actionLabel == "Request Access")
        #expect(MacScopePermissionStatus.notDetermined.actionLabel == "Request Access")
        #expect(MacScopePermissionStatus.denied.actionLabel == "Open Settings")
        #expect(MacScopePermissionStatus.restricted.actionLabel == "Open Settings")
        #expect(MacScopePermissionStatus.needsReview("Review").actionLabel == "Open Settings")
    }

    @Test("AV and notification statuses map without requesting access")
    func frameworkStatusMapping() {
        #expect(PermissionCenter.captureStatus(.authorized) == .allowed)
        #expect(PermissionCenter.captureStatus(.denied) == .denied)
        #expect(PermissionCenter.captureStatus(.restricted) == .restricted)
        #expect(PermissionCenter.captureStatus(.notDetermined) == .notDetermined)

        #expect(PermissionCenter.notificationPermissionStatus(.authorized) == .allowed)
        #expect(PermissionCenter.notificationPermissionStatus(.provisional) == .allowed)
        #expect(PermissionCenter.notificationPermissionStatus(.denied) == .denied)
        #expect(PermissionCenter.notificationPermissionStatus(.notDetermined) == .notDetermined)
    }

    @Test("Rejected direct requests open their matching Settings panes") @MainActor
    func rejectedRequestsFallBackToSettings() async {
        var openedSettings: [MacScopePermissionID] = []
        for id in [MacScopePermissionID.inputMonitoring, .screenRecording] {
            let center = PermissionCenter(
                permissions: [MacScopePermissionItem(id: id, status: .notAllowed)],
                accessRequester: { requestedID in
                    #expect(requestedID == id)
                    return false
                },
                settingsOpener: { openedID in
                    openedSettings.append(openedID)
                    return true
                },
                afterRequest: {}
            )

            await center.request(id)
        }

        #expect(openedSettings == [.inputMonitoring, .screenRecording])
    }

    @Test("A blocked permission opens Settings without repeating its prompt") @MainActor
    func blockedPermissionOpensSettings() async {
        var requested = false
        var openedSettings: [MacScopePermissionID] = []
        let center = PermissionCenter(
            permissions: [MacScopePermissionItem(id: .accessibility, status: .denied)],
            accessRequester: { _ in
                requested = true
                return false
            },
            settingsOpener: { id in
                openedSettings.append(id)
                return true
            },
            afterRequest: {}
        )

        await center.request(.accessibility)

        #expect(!requested)
        #expect(openedSettings == [.accessibility])
    }
}
