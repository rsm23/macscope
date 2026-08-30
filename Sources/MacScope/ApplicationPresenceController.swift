import AppKit

@MainActor
final class ApplicationPresenceController {
    static let shared = ApplicationPresenceController()

    private let applyPolicy: (NSApplication.ActivationPolicy) -> Bool

    init(
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = {
            NSApp.setActivationPolicy($0)
        }
    ) {
        self.applyPolicy = applyPolicy
    }

    func mainWindowDidClose() {
        _ = applyPolicy(.accessory)
    }

    func mainWindowWillOpen() {
        _ = applyPolicy(.regular)
    }
}
