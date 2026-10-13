import AppKit
import SwiftUI
import Testing
@testable import MacScope

@Suite("Quick Panel layout", .serialized)
struct MenuBarPanelLayoutTests {
    @Test("Preview tabs request the same window size", arguments: [ColorScheme.light, .dark])
    @MainActor
    func tabsPreservePanelSize(colorScheme: ColorScheme) {
        let model = AppModel(
            alertNotifications: UsageAlertNotificationController(center: nil),
            startsUtilityServer: false
        )
        let hostingView = NSHostingView(
            rootView: MenuBarPanel(model: model)
                .environment(\.colorScheme, colorScheme)
        )
        let overviewSize = hostingView.fittingSize
        #expect(overviewSize.width > 0 && overviewSize.height > 0)

        for tab in MenuBarPanelTab.allCases {
            let tabView = NSHostingView(
                rootView: MenuBarPanel(model: model, initialTab: tab)
                    .environment(\.colorScheme, colorScheme)
            )
            let size = tabView.fittingSize
            #expect(size.width == overviewSize.width, "\(tab.rawValue) width changed")
            #expect(size.height == overviewSize.height, "\(tab.rawValue) height changed")
        }
    }
}
