import Carbon
import CoreGraphics
import Foundation

extension Notification.Name {
    static let radialShortcutReleased = Notification.Name("MacScopeRadialShortcutReleased")
}

enum GlobalShortcutAction: String, CaseIterable, Identifiable, Codable {
    case commandBar
    case appSwitcher
    case quickPanel
    case radialMenu
    case sessionShelf
    case selectionScreenshot
    case fullScreenScreenshot
    case copyLatestScreenshot
    case cycleFrontAppWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandBar: "Command Bar"
        case .appSwitcher: "App & Window Switcher"
        case .quickPanel: "Quick Panel"
        case .radialMenu: "Radial Menu"
        case .sessionShelf: "Session Shelf"
        case .selectionScreenshot: "Selection Screenshot"
        case .fullScreenScreenshot: "Full-Screen Screenshot"
        case .copyLatestScreenshot: "Copy Latest Screenshot"
        case .cycleFrontAppWindow: "Cycle Front App Windows"
        }
    }

    var icon: String {
        switch self {
        case .commandBar: "command"
        case .appSwitcher: "square.stack.3d.up"
        case .quickPanel: "bolt.fill"
        case .radialMenu: "circle.hexagongrid.fill"
        case .sessionShelf: "tray.full"
        case .selectionScreenshot: "viewfinder"
        case .fullScreenScreenshot: "rectangle.inset.filled"
        case .copyLatestScreenshot: "doc.on.doc"
        case .cycleFrontAppWindow: "macwindow.on.rectangle"
        }
    }

    var defaultConfiguration: GlobalShortcutConfiguration {
        switch self {
        case .commandBar: .init(enabled: true, keyCode: UInt32(kVK_ANSI_P), keyLabel: "P", modifier: .commandShift)
        case .appSwitcher: .init(enabled: true, keyCode: UInt32(kVK_ANSI_A), keyLabel: "A", modifier: .commandShift)
        case .quickPanel: .init(enabled: true, keyCode: UInt32(kVK_ANSI_V), keyLabel: "V", modifier: .controlCommand)
        case .radialMenu: .init(enabled: true, keyCode: UInt32(kVK_Space), keyLabel: "Space", modifier: .controlOption)
        case .sessionShelf: .init(enabled: true, keyCode: UInt32(kVK_ANSI_S), keyLabel: "S", modifier: .controlOption)
        case .selectionScreenshot: .init(enabled: true, keyCode: UInt32(kVK_ANSI_4), keyLabel: "4", modifier: .controlOption)
        case .fullScreenScreenshot: .init(enabled: true, keyCode: UInt32(kVK_ANSI_3), keyLabel: "3", modifier: .controlOption)
        case .copyLatestScreenshot: .init(enabled: true, keyCode: UInt32(kVK_ANSI_C), keyLabel: "C", modifier: .controlOption)
        case .cycleFrontAppWindow: .init(enabled: true, keyCode: UInt32(kVK_ANSI_Grave), keyLabel: "`", modifier: .controlOption)
        }
    }
}

enum GlobalShortcutModifier: String, CaseIterable, Identifiable, Codable {
    case commandShift
    case controlOption
    case controlCommand
    case commandOption
    case controlShift
    case commandOptionShift

    var id: String { rawValue }
    var label: String {
        switch self {
        case .commandShift: "⌘⇧"
        case .controlOption: "⌃⌥"
        case .controlCommand: "⌃⌘"
        case .commandOption: "⌘⌥"
        case .controlShift: "⌃⇧"
        case .commandOptionShift: "⌘⌥⇧"
        }
    }

    var carbonValue: UInt32 {
        switch self {
        case .commandShift: UInt32(cmdKey | shiftKey)
        case .controlOption: UInt32(controlKey | optionKey)
        case .controlCommand: UInt32(controlKey | cmdKey)
        case .commandOption: UInt32(cmdKey | optionKey)
        case .controlShift: UInt32(controlKey | shiftKey)
        case .commandOptionShift: UInt32(cmdKey | optionKey | shiftKey)
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .commandShift: [.maskCommand, .maskShift]
        case .controlOption: [.maskControl, .maskAlternate]
        case .controlCommand: [.maskControl, .maskCommand]
        case .commandOption: [.maskCommand, .maskAlternate]
        case .controlShift: [.maskControl, .maskShift]
        case .commandOptionShift: [.maskCommand, .maskAlternate, .maskShift]
        }
    }
}

struct GlobalShortcutKey: Identifiable, Hashable {
    let keyCode: UInt32
    let label: String
    var id: UInt32 { keyCode }

    static let choices: [GlobalShortcutKey] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"), (kVK_ANSI_Grave, "`"), (kVK_Space, "Space")
        ]
        return letters.map { .init(keyCode: UInt32($0.0), label: $0.1) }
    }()
}

struct GlobalShortcutConfiguration: Codable, Equatable {
    var enabled: Bool
    var keyCode: UInt32
    var keyLabel: String
    var modifier: GlobalShortcutModifier

    var displayLabel: String { "\(modifier.label)\(keyLabel)" }
}

enum GlobalShortcutStore {
    static let didChangeNotification = Notification.Name("MacScopeGlobalShortcutsDidChange")

    static func configuration(for action: GlobalShortcutAction) -> GlobalShortcutConfiguration {
        let key = storageKey(action)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(GlobalShortcutConfiguration.self, from: data) else {
            return action.defaultConfiguration
        }
        return decoded
    }

    static func save(_ configuration: GlobalShortcutConfiguration, for action: GlobalShortcutAction) {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: storageKey(action))
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func conflicts() -> Set<GlobalShortcutAction> {
        var firstBySignature: [String: GlobalShortcutAction] = [:]
        var conflicts: Set<GlobalShortcutAction> = []
        for action in GlobalShortcutAction.allCases {
            let value = configuration(for: action)
            guard value.enabled else { continue }
            let signature = "\(value.modifier.rawValue):\(value.keyCode)"
            if let first = firstBySignature[signature] {
                conflicts.insert(first)
                conflicts.insert(action)
            } else {
                firstBySignature[signature] = action
            }
        }
        return conflicts
    }

    private static func storageKey(_ action: GlobalShortcutAction) -> String {
        "globalShortcut.\(action.rawValue)"
    }
}
