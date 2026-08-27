import CoreFoundation
import Foundation

public enum MacOSFeatureCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case appearance = "Appearance & Desktop"
    case finder = "Finder"
    case dock = "Dock & Mission Control"
    case windows = "Windows & Spaces"
    case keyboard = "Keyboard & Text"
    case pointer = "Trackpad & Mouse"
    case menuBar = "Menu Bar & Control Center"
    case capture = "Screenshots & Recording"
    case files = "Files, Disks & Network"
    case applications = "Built-in Apps"
    case developer = "Developer"
    case accessibility = "Accessibility"
    case security = "Security & Login"

    public var id: String { rawValue }
}

public enum MacOSFeatureTier: String, CaseIterable, Codable, Hashable, Sendable {
    case recommended
    case advanced
    case experimental
    case restricted
}

public enum MacOSFeatureRestart: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case finder
    case dock
    case systemUIServer
    case controlCenter
    case application
    case logout

    public var displayName: String {
        switch self {
        case .none: "Applies immediately"
        case .finder: "Restarts Finder"
        case .dock: "Restarts Dock"
        case .systemUIServer: "Restarts SystemUIServer"
        case .controlCenter: "Restarts Control Center"
        case .application: "Relaunch the affected app"
        case .logout: "Log out to apply completely"
        }
    }
}

public enum MacOSFeaturePreferenceValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case decimal(Double)
    case string(String)

    public var displayValue: String {
        switch self {
        case .boolean(let value): value ? "true" : "false"
        case .integer(let value): value.formatted()
        case .decimal(let value): value.formatted(.number.precision(.fractionLength(0...3)))
        case .string(let value): value
        }
    }

    fileprivate var defaultsArguments: [String] {
        switch self {
        case .boolean(let value): ["-bool", value ? "true" : "false"]
        case .integer(let value): ["-int", String(value)]
        case .decimal(let value): ["-float", String(value)]
        case .string(let value): ["-string", value]
        }
    }

    fileprivate static func propertyListValue(_ value: Any) -> Self? {
        if let value = value as? String { return .string(value) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .boolean(number.boolValue)
        }
        let double = number.doubleValue
        if double.rounded() == double { return .integer(number.intValue) }
        return .decimal(double)
    }

    func normalized(for expected: Self) -> Self {
        switch expected {
        case .boolean:
            switch self {
            case .boolean: return self
            case .integer(let number): return .boolean(number != 0)
            case .decimal(let number): return .boolean(number != 0)
            case .string(let text):
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1", "on": return .boolean(true)
                case "false", "no", "0", "off": return .boolean(false)
                default: return self
                }
            }
        case .integer:
            switch self {
            case .boolean(let flag): return .integer(flag ? 1 : 0)
            case .decimal(let number) where number.rounded() == number: return .integer(Int(number))
            case .string(let text):
                return Int(text).map(Self.integer) ?? self
            default: return self
            }
        case .decimal:
            switch self {
            case .integer(let number): return .decimal(Double(number))
            case .string(let text):
                return Double(text).map(Self.decimal) ?? self
            default: return self
            }
        case .string:
            return self
        }
    }
}

public struct MacOSFeaturePreference: Codable, Hashable, Sendable {
    public let domain: String
    public let key: String
    public let enabledValue: MacOSFeaturePreferenceValue
    public let disabledValue: MacOSFeaturePreferenceValue
    public let defaultValue: MacOSFeaturePreferenceValue
    public let restart: MacOSFeatureRestart
    public let restartTarget: String?

    public init(
        domain: String,
        key: String,
        enabledValue: MacOSFeaturePreferenceValue,
        disabledValue: MacOSFeaturePreferenceValue,
        defaultValue: MacOSFeaturePreferenceValue,
        restart: MacOSFeatureRestart = .none,
        restartTarget: String? = nil
    ) {
        self.domain = domain
        self.key = key
        self.enabledValue = enabledValue
        self.disabledValue = disabledValue
        self.defaultValue = defaultValue
        self.restart = restart
        self.restartTarget = restartTarget
    }
}

public enum MacOSFeatureMechanism: Codable, Hashable, Sendable {
    case preference(MacOSFeaturePreference)
    case manual(reason: String, settingsURL: String?)
    case restricted(reason: String)
}

public struct MacOSFeatureDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let category: MacOSFeatureCategory
    public let icon: String
    public let tier: MacOSFeatureTier
    public let minimumOSMajor: Int
    public let maximumOSMajor: Int?
    public let mechanism: MacOSFeatureMechanism
    public let provenance: String
    public let sourceURL: String?

    public init(
        id: String,
        title: String,
        summary: String,
        category: MacOSFeatureCategory,
        icon: String,
        tier: MacOSFeatureTier,
        minimumOSMajor: Int = 14,
        maximumOSMajor: Int? = nil,
        mechanism: MacOSFeatureMechanism,
        provenance: String,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.icon = icon
        self.tier = tier
        self.minimumOSMajor = minimumOSMajor
        self.maximumOSMajor = maximumOSMajor
        self.mechanism = mechanism
        self.provenance = provenance
        self.sourceURL = sourceURL
    }
}

public enum MacOSFeatureEffectiveState: String, CaseIterable, Codable, Hashable, Sendable {
    case enabled
    case disabled
    case unknown
}

public struct MacOSFeatureStatus: Identifiable, Codable, Hashable, Sendable {
    public var id: String { descriptor.id }
    public let descriptor: MacOSFeatureDescriptor
    public let state: MacOSFeatureEffectiveState
    public let availability: DataAvailability
    public let storedValue: MacOSFeaturePreferenceValue?
    public let detail: String?

    public init(
        descriptor: MacOSFeatureDescriptor,
        state: MacOSFeatureEffectiveState,
        availability: DataAvailability,
        storedValue: MacOSFeaturePreferenceValue?,
        detail: String? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.availability = availability
        self.storedValue = storedValue
        self.detail = detail
    }
}

public struct MacOSFeatureChange: Codable, Hashable, Sendable {
    public let descriptorID: String
    public let previousStoredValue: MacOSFeaturePreferenceValue?
    public let enabled: Bool
    public let note: String?

    public init(
        descriptorID: String,
        previousStoredValue: MacOSFeaturePreferenceValue?,
        enabled: Bool,
        note: String? = nil
    ) {
        self.descriptorID = descriptorID
        self.previousStoredValue = previousStoredValue
        self.enabled = enabled
        self.note = note
    }
}

public enum MacOSFeatureError: LocalizedError, Sendable {
    case unknownFeature
    case manual(String)
    case restricted(String)
    case unsupportedOS
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownFeature: "The selected macOS feature is not in MacScope's allowlist."
        case .manual(let reason): reason
        case .restricted(let reason): reason
        case .unsupportedOS: "This preference is not supported on this macOS version."
        case .writeFailed(let detail): detail
        }
    }
}

public enum MacOSFeatureCatalog {
    public static let globalDomain = "NSGlobalDomain"

    /// A deliberately explicit allowlist. Entries are data, never user-provided
    /// command fragments, and every write is reduced to one typed `defaults`
    /// value. Unknown and obsolete preferences remain visible as such instead
    /// of being reported as enabled.
    public static let all: [MacOSFeatureDescriptor] = [
        bool("appearance.auto", "Automatic light and dark appearance", "Switch appearance automatically using the schedule configured by macOS.", .appearance, "circle.lefthalf.filled", domain: globalDomain, key: "AppleInterfaceStyleSwitchesAutomatically", default: false),
        bool("appearance.menu-bar-autohide", "Automatically hide the menu bar", "Keeps the menu bar hidden until the pointer reaches the top edge.", .appearance, "menubar.rectangle", domain: globalDomain, key: "_HIHideMenuBar", default: false, restart: .systemUIServer),
        stringToggle("appearance.scrollbars", "Always show scroll bars", "Shows scroll bars continuously instead of only while scrolling.", .appearance, "scroll", domain: globalDomain, key: "AppleShowScrollBars", enabled: "Always", disabled: "Automatic", default: "Automatic"),
        bool("appearance.smooth-scroll", "Smooth scrolling", "Animates document scrolling in apps that honor the global AppKit preference.", .appearance, "waveform.path", domain: globalDomain, key: "NSScrollAnimationEnabled", default: true),
        bool("appearance.window-animations", "Window animations", "Enables standard AppKit window opening and resizing animations.", .appearance, "macwindow", domain: globalDomain, key: "NSAutomaticWindowAnimationsEnabled", default: true),
        bool("appearance.animated-focus-ring", "Animated keyboard focus ring", "Animates the focus ring when keyboard focus moves between controls.", .appearance, "circle.dashed", domain: globalDomain, key: "NSUseAnimatedFocusRing", default: true, tier: .advanced),
        bool("appearance.expand-save", "Expanded Save dialogs", "Opens Save dialogs with the file browser expanded.", .appearance, "rectangle.expand.vertical", domain: globalDomain, key: "NSNavPanelExpandedStateForSaveMode", default: false),
        bool("appearance.expand-save-v2", "Expanded Save dialogs in modern apps", "Sets the companion preference used by newer AppKit Save dialogs.", .appearance, "rectangle.expand.vertical", domain: globalDomain, key: "NSNavPanelExpandedStateForSaveMode2", default: false),
        bool("appearance.expand-print", "Expanded Print dialogs", "Opens Print dialogs with advanced controls expanded.", .appearance, "printer", domain: globalDomain, key: "PMPrintingExpandedStateForPrint", default: false),
        bool("appearance.expand-print-v2", "Expanded Print dialogs in modern apps", "Sets the companion preference used by newer Print dialogs.", .appearance, "printer.fill", domain: globalDomain, key: "PMPrintingExpandedStateForPrint2", default: false),

        bool("finder.hidden-files", "Show hidden files", "Shows dotfiles and other normally hidden items. Finder restarts to apply it.", .finder, "eye", domain: "com.apple.finder", key: "AppleShowAllFiles", default: false, restart: .finder),
        bool("finder.desktop-icons", "Show desktop icons", "Shows files and mounted items on the desktop. Finder restarts to apply it.", .finder, "desktopcomputer", domain: "com.apple.finder", key: "CreateDesktop", default: true, restart: .finder),
        bool("finder.extensions", "Show all filename extensions", "Displays filename extensions for every file type.", .finder, "doc.text.magnifyingglass", domain: globalDomain, key: "AppleShowAllExtensions", default: false, restart: .finder),
        bool("finder.path-bar", "Show path bar", "Displays the current folder path at the bottom of Finder windows.", .finder, "point.bottomleft.forward.to.point.topright.scurvepath", domain: "com.apple.finder", key: "ShowPathbar", default: false, restart: .finder),
        bool("finder.status-bar", "Show status bar", "Displays item counts and available storage at the bottom of Finder windows.", .finder, "info.circle", domain: "com.apple.finder", key: "ShowStatusBar", default: false, restart: .finder),
        bool("finder.posix-title", "Show full POSIX path in window title", "Uses the current folder's complete path in Finder window titles.", .finder, "textformat.abc", domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", default: false, restart: .finder, tier: .advanced),
        bool("finder.quit-menu", "Allow quitting Finder", "Adds Quit Finder to the Finder menu. Desktop icons disappear while Finder is quit.", .finder, "power", domain: "com.apple.finder", key: "QuitMenuItem", default: false, restart: .finder, tier: .advanced),
        bool("finder.extension-warning", "Warn before changing a file extension", "Keeps Finder's confirmation when a filename extension changes.", .finder, "exclamationmark.triangle", domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", default: true, restart: .finder),
        bool("finder.empty-trash-warning", "Warn before emptying Trash", "Requires confirmation before Finder permanently empties the Trash.", .finder, "trash", domain: "com.apple.finder", key: "WarnOnEmptyTrash", default: true, restart: .finder),
        bool("finder.remove-old-trash", "Remove Trash items after 30 days", "Allows Finder to automatically remove items that have remained in Trash for 30 days.", .finder, "trash.slash", domain: "com.apple.finder", key: "FXRemoveOldTrashItems", default: false, restart: .finder),
        bool("finder.hard-disks-desktop", "Show internal disks on desktop", "Shows mounted internal storage devices on the desktop.", .finder, "internaldrive", domain: "com.apple.finder", key: "ShowHardDrivesOnDesktop", default: false, restart: .finder),
        bool("finder.external-disks-desktop", "Show external disks on desktop", "Shows mounted external storage devices on the desktop.", .finder, "externaldrive", domain: "com.apple.finder", key: "ShowExternalHardDrivesOnDesktop", default: true, restart: .finder),
        bool("finder.removable-desktop", "Show removable media on desktop", "Shows optical discs, cards, and other removable media on the desktop.", .finder, "opticaldiscdrive", domain: "com.apple.finder", key: "ShowRemovableMediaOnDesktop", default: true, restart: .finder),
        bool("finder.servers-desktop", "Show connected servers on desktop", "Shows mounted network servers on the desktop.", .finder, "server.rack", domain: "com.apple.finder", key: "ShowMountedServersOnDesktop", default: false, restart: .finder),
        bool("finder.disable-animations", "Disable Finder animations", "Reduces Finder window and Get Info animations.", .finder, "hare", domain: "com.apple.finder", key: "DisableAllAnimations", default: false, restart: .finder, tier: .advanced),
        bool("finder.spring-loading", "Spring-load folders", "Opens folders when files are dragged and held over them.", .finder, "folder.badge.gearshape", domain: globalDomain, key: "com.apple.springing.enabled", default: true),
        bool("finder.save-local", "Save new documents locally", "Makes local storage the default instead of iCloud in apps that honor this preference.", .finder, "folder", domain: globalDomain, key: "NSDocumentSaveNewDocumentsToCloud", enabled: false, default: true, tier: .advanced),

        bool("dock.autohide", "Automatically hide the Dock", "Hides the Dock until the pointer reaches its screen edge.", .dock, "dock.rectangle", domain: "com.apple.dock", key: "autohide", default: false, restart: .dock),
        bool("dock.magnification", "Dock magnification", "Magnifies Dock icons around the pointer.", .dock, "plus.magnifyingglass", domain: "com.apple.dock", key: "magnification", default: false, restart: .dock),
        bool("dock.launch-animation", "Animate opening applications", "Makes Dock icons bounce while applications launch.", .dock, "app.badge", domain: "com.apple.dock", key: "launchanim", default: true, restart: .dock),
        bool("dock.minimize-to-app", "Minimize windows into application icon", "Groups minimized windows with their application's Dock icon.", .dock, "rectangle.compress.vertical", domain: "com.apple.dock", key: "minimize-to-application", default: false, restart: .dock),
        bool("dock.recents", "Show recent applications in Dock", "Shows a recent-applications section at the end of the Dock.", .dock, "clock.arrow.circlepath", domain: "com.apple.dock", key: "show-recents", default: true, restart: .dock),
        bool("dock.running-indicators", "Show open-application indicators", "Shows a dot below applications that are currently running.", .dock, "circle.fill", domain: "com.apple.dock", key: "show-process-indicators", default: true, restart: .dock),
        bool("dock.hidden-apps", "Dim hidden applications", "Makes hidden application icons translucent in the Dock.", .dock, "eye.slash", domain: "com.apple.dock", key: "showhidden", default: false, restart: .dock, tier: .advanced),
        bool("dock.static-only", "Show only running applications", "Hides pinned applications that are not running.", .dock, "bolt.horizontal.circle", domain: "com.apple.dock", key: "static-only", default: false, restart: .dock, tier: .experimental),
        bool("dock.spring-load", "Spring-load Dock items", "Opens Dock targets when a dragged item is held over them.", .dock, "arrow.down.app", domain: "com.apple.dock", key: "enable-spring-load-actions-on-all-items", default: false, restart: .dock, tier: .advanced),
        bool("dock.single-app", "Single-application mode", "Hides other applications when one is selected from the Dock.", .dock, "rectangle.on.rectangle.slash", domain: "com.apple.dock", key: "single-app", default: false, restart: .dock, tier: .experimental),
        stringToggle("dock.scale-effect", "Use Scale minimize effect", "Uses the Scale effect when minimizing instead of Genie.", .dock, "arrow.down.right.and.arrow.up.left", domain: "com.apple.dock", key: "mineffect", enabled: "scale", disabled: "genie", default: "genie", restart: .dock),
        bool("dock.group-mission-control", "Group windows by application", "Groups windows by application in Mission Control.", .dock, "square.stack.3d.up", domain: "com.apple.dock", key: "expose-group-apps", default: false, restart: .dock),
        bool("dock.mru-spaces", "Rearrange Spaces by recent use", "Automatically reorders Spaces based on their most recent use.", .dock, "rectangle.3.group", domain: "com.apple.dock", key: "mru-spaces", default: true, restart: .dock),
        bool("dock.displays-separate-spaces", "Displays have separate Spaces", "Gives each display its own independent set of Spaces. Logging out may be required.", .dock, "display.2", domain: "com.apple.spaces", key: "spans-displays", enabled: false, default: false, restart: .logout, tier: .advanced),
        bool("dock.dashboard-overlay", "Dashboard as overlay", "Uses the legacy Dashboard as an overlay where supported.", .dock, "gauge.with.dots.needle.50percent", domain: "com.apple.dock", key: "dashboard-in-overlay", default: false, restart: .dock, maximumOSMajor: 14, tier: .experimental),

        bool("windows.click-desktop", "Click wallpaper to show desktop", "Moves windows aside when the desktop wallpaper is clicked.", .windows, "macwindow.on.rectangle", domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", default: true),
        bool("windows.tiling-margins", "Leave margins around tiled windows", "Keeps a visible gap around windows tiled by macOS.", .windows, "rectangle.inset.filled", domain: globalDomain, key: "EnableTiledWindowMargins", default: true, minimumOSMajor: 15),
        bool("windows.tile-edge-drag", "Tile windows by dragging to edges", "Shows macOS tiling targets when a window reaches a screen edge.", .windows, "rectangle.split.2x1", domain: globalDomain, key: "EnableTilingByEdgeDrag", default: true, minimumOSMajor: 15),
        bool("windows.tile-option", "Option-drag window tiling", "Shows additional tiling targets while dragging with the Option key.", .windows, "option", domain: globalDomain, key: "EnableTilingOptionAccelerator", default: true, minimumOSMajor: 15),
        bool("windows.top-edge-fill", "Fill screen from top edge", "Allows dragging a window to the top edge to fill the screen.", .windows, "arrow.up.to.line", domain: globalDomain, key: "EnableTopTilingByEdgeDrag", default: true, minimumOSMajor: 15),
        bool("windows.stage-manager", "Stage Manager", "Enables the system Stage Manager workspace.", .windows, "squares.leading.rectangle", domain: "com.apple.WindowManager", key: "GloballyEnabled", default: false, tier: .advanced),
        bool("windows.stage-manager-widgets", "Show widgets in Stage Manager", "Keeps desktop widgets visible while Stage Manager is active.", .windows, "widget.small", domain: "com.apple.WindowManager", key: "StageManagerHideWidgets", enabled: false, default: false, tier: .advanced),
        bool("windows.restore", "Restore windows when reopening apps", "Keeps application windows available for the next launch.", .windows, "arrow.counterclockwise.square", domain: globalDomain, key: "NSQuitAlwaysKeepsWindows", default: true),

        bool("keyboard.press-hold", "Press-and-hold accent menu", "Shows accented-character choices when a letter key is held. Disable it for key repeat instead.", .keyboard, "character.cursor.ibeam", domain: globalDomain, key: "ApplePressAndHoldEnabled", default: true),
        integerToggle("keyboard.full-access", "Full keyboard access for controls", "Lets Tab move focus through buttons and other interface controls.", .keyboard, "keyboard", domain: globalDomain, key: "AppleKeyboardUIMode", enabled: 3, disabled: 0, default: 0, tier: .advanced),
        bool("keyboard.auto-capitalization", "Automatic capitalization", "Capitalizes sentences automatically in compatible text fields.", .keyboard, "textformat.size.larger", domain: globalDomain, key: "NSAutomaticCapitalizationEnabled", default: true),
        bool("keyboard.smart-dashes", "Smart dashes", "Replaces double hyphens with typographic dashes while typing.", .keyboard, "minus", domain: globalDomain, key: "NSAutomaticDashSubstitutionEnabled", default: true),
        bool("keyboard.double-space-period", "Period with double-space", "Inserts a period after two spaces in compatible text fields.", .keyboard, "textformat", domain: globalDomain, key: "NSAutomaticPeriodSubstitutionEnabled", default: true),
        bool("keyboard.smart-quotes", "Smart quotes", "Replaces straight quotation marks with typographic quotes.", .keyboard, "quote.opening", domain: globalDomain, key: "NSAutomaticQuoteSubstitutionEnabled", default: true),
        bool("keyboard.autocorrect", "Automatic spelling correction", "Corrects likely spelling mistakes in compatible text fields.", .keyboard, "checkmark.circle", domain: globalDomain, key: "NSAutomaticSpellingCorrectionEnabled", default: true),
        bool("keyboard.continuous-spell", "Check spelling while typing", "Underlines spelling mistakes in compatible text fields.", .keyboard, "character.book.closed", domain: globalDomain, key: "NSAllowContinuousSpellChecking", default: true),
        bool("keyboard.fn-standard", "Use F1, F2, etc. as standard keys", "Requires holding Fn to use the keys' media and system actions.", .keyboard, "f.square", domain: globalDomain, key: "com.apple.keyboard.fnState", default: false),
        bool("keyboard.sound-feedback", "Keyboard volume feedback sound", "Plays feedback when the system sound volume changes.", .keyboard, "speaker.wave.2", domain: globalDomain, key: "com.apple.sound.beep.feedback", default: true, tier: .advanced),

        bool("pointer.natural-scroll", "Natural scrolling", "Moves content in the same direction as the fingers on a trackpad or mouse surface.", .pointer, "arrow.up.and.down", domain: globalDomain, key: "com.apple.swipescrolldirection", default: true),
        bool("pointer.tap-click", "Tap to click", "Uses a light one-finger tap as a primary click on supported trackpads.", .pointer, "hand.tap", domain: "com.apple.AppleMultitouchTrackpad", key: "Clicking", default: false, restart: .logout, tier: .advanced),
        bool("pointer.three-finger-drag", "Three-finger drag", "Moves windows and selections by dragging with three fingers.", .pointer, "hand.draw", domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadThreeFingerDrag", default: false, restart: .logout, tier: .advanced),
        bool("pointer.secondary-click", "Trackpad secondary click", "Enables the configured two-finger or corner secondary click.", .pointer, "cursorarrow.click.2", domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadRightClick", default: true, restart: .logout, tier: .advanced),
        bool("pointer.momentum", "Trackpad momentum scrolling", "Lets scrolling continue briefly after the fingers lift.", .pointer, "wind", domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadMomentumScroll", default: true, restart: .logout, tier: .advanced),
        bool("pointer.pinch", "Pinch to zoom", "Enables pinch gestures in compatible apps.", .pointer, "arrow.up.left.and.arrow.down.right", domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadPinch", default: true, restart: .logout, tier: .advanced),
        bool("pointer.rotate", "Rotate gesture", "Enables two-finger rotation in compatible apps.", .pointer, "rotate.right", domain: "com.apple.AppleMultitouchTrackpad", key: "TrackpadRotate", default: true, restart: .logout, tier: .advanced),
        bool("pointer.linear-mouse", "Disable mouse acceleration", "Uses linear pointer movement for supported mice on modern macOS.", .pointer, "cursorarrow.motionlines", domain: globalDomain, key: "com.apple.mouse.linear", default: false, minimumOSMajor: 14, tier: .advanced),
        bool("pointer.swipe-navigation", "Swipe between pages", "Uses horizontal scrolling gestures to navigate in compatible apps.", .pointer, "arrow.left.arrow.right", domain: globalDomain, key: "AppleEnableSwipeNavigateWithScrolls", default: true),

        bool("menubar.clock-seconds", "Show seconds in menu bar clock", "Adds seconds to the menu bar clock.", .menuBar, "clock", domain: "com.apple.menuextra.clock", key: "ShowSeconds", default: false, restart: .systemUIServer),
        bool("menubar.clock-weekday", "Show day of week in menu bar", "Adds the abbreviated weekday to the menu bar clock.", .menuBar, "calendar", domain: "com.apple.menuextra.clock", key: "ShowDayOfWeek", default: true, restart: .systemUIServer),
        bool("menubar.clock-24h", "Use 24-hour menu bar clock", "Shows menu bar time using a 24-hour clock.", .menuBar, "24.circle", domain: "com.apple.menuextra.clock", key: "Show24Hour", default: false, restart: .systemUIServer),
        bool("menubar.battery-percent", "Show battery percentage", "Shows the remaining battery percentage in the menu bar.", .menuBar, "battery.75percent", domain: "com.apple.controlcenter", key: "BatteryShowPercentage", default: false, restart: .controlCenter),
        bool("menubar.blink-time-separators", "Blink clock separators", "Blinks the menu bar clock separators where supported.", .menuBar, "coloncurrencysign.circle", domain: "com.apple.menuextra.clock", key: "FlashDateSeparators", default: false, restart: .systemUIServer, tier: .experimental),

        bool("capture.thumbnail", "Show floating screenshot thumbnail", "Displays a temporary thumbnail after taking a screenshot.", .capture, "photo.on.rectangle", domain: "com.apple.screencapture", key: "show-thumbnail", default: true, restart: .systemUIServer),
        bool("capture.shadow", "Include window shadows", "Includes the drop shadow when capturing an individual window.", .capture, "square.on.square.squareshape.controlhandles", domain: "com.apple.screencapture", key: "disable-shadow", enabled: false, default: false, restart: .systemUIServer),
        bool("capture.date", "Include date in screenshot filenames", "Adds the capture date and time to generated screenshot filenames.", .capture, "calendar.badge.clock", domain: "com.apple.screencapture", key: "include-date", default: true, restart: .systemUIServer),
        bool("capture.display-uuid", "Include display identity in filenames", "Adds the display identifier when screenshots are taken from multiple displays.", .capture, "display", domain: "com.apple.screencapture", key: "display-uuid", default: false, restart: .systemUIServer, tier: .advanced),
        bool("capture.location-selection", "Remember last screenshot selection", "Keeps the previous selection region for the next screenshot.", .capture, "viewfinder", domain: "com.apple.screencapture", key: "last-selection-display", default: true, restart: .systemUIServer, tier: .experimental),

        bool("files.no-network-ds-store", "Avoid .DS_Store on network volumes", "Prevents Finder from writing metadata files to network shares.", .files, "network.slash", domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", default: false, restart: .finder),
        bool("files.no-usb-ds-store", "Avoid .DS_Store on USB volumes", "Prevents Finder from writing metadata files to removable USB storage.", .files, "externaldrive.badge.xmark", domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", default: false, restart: .finder),
        bool("files.no-external-ds-store", "Avoid .DS_Store on external volumes", "Prevents Finder from writing metadata files to other external storage.", .files, "externaldrive.badge.minus", domain: "com.apple.desktopservices", key: "DSDontWriteExternalStores", default: false, restart: .finder, tier: .advanced),
        bool("files.airdrop-all-interfaces", "AirDrop over every network interface", "Allows AirDrop discovery over additional interfaces where the OS still supports it.", .files, "airplayaudio", domain: "com.apple.NetworkBrowser", key: "BrowseAllInterfaces", default: false, restart: .finder, tier: .experimental),
        bool("files.no-new-disk-backup-prompt", "Do not offer new disks for Time Machine", "Suppresses the prompt to use newly attached disks for backups.", .files, "externaldrive.badge.timemachine", domain: "com.apple.TimeMachine", key: "DoNotOfferNewDisksForBackup", default: false, tier: .advanced),
        bool("files.print-quit", "Quit printer app after jobs finish", "Closes the printer queue application when all print jobs complete.", .files, "printer.dotmatrix", domain: "com.apple.print.PrintingPrefs", key: "Quit When Finished", default: false, tier: .advanced),

        bool("apps.safari-develop", "Safari Develop menu", "Shows Safari's Develop menu with web inspection tools.", .applications, "safari", domain: "com.apple.Safari", key: "IncludeDevelopMenu", default: false, restart: .application, tier: .advanced),
        bool("apps.safari-full-url", "Show full website address in Safari", "Shows the full URL instead of only the website domain.", .applications, "link", domain: "com.apple.Safari", key: "ShowFullURLInSmartSearchField", default: false, restart: .application),
        bool("apps.safari-status", "Safari status bar", "Shows a destination preview when hovering over links.", .applications, "rectangle.bottomthird.inset.filled", domain: "com.apple.Safari", key: "ShowOverlayStatusBar", default: false, restart: .application),
        bool("apps.safari-safe-downloads", "Open safe downloads automatically", "Allows Safari to open selected downloaded file types. Review this before enabling.", .applications, "arrow.down.doc", domain: "com.apple.Safari", key: "AutoOpenSafeDownloads", default: false, restart: .application, tier: .advanced),
        bool("apps.safari-search-suggestions", "Safari search suggestions", "Sends typed search text to the configured search provider for suggestions.", .applications, "text.magnifyingglass", domain: "com.apple.Safari", key: "SuppressSearchSuggestions", enabled: false, default: false, restart: .application, tier: .advanced),
        bool("apps.textedit-rich", "New TextEdit documents use rich text", "Creates formatted RTF documents instead of plain-text documents by default.", .applications, "doc.richtext", domain: "com.apple.TextEdit", key: "RichText", default: true, restart: .application),
        bool("apps.textedit-smart-quotes", "TextEdit smart quotes", "Uses typographic quotation marks in TextEdit.", .applications, "quote.opening", domain: "com.apple.TextEdit", key: "SmartQuotes", default: true, restart: .application),
        bool("apps.textedit-smart-dashes", "TextEdit smart dashes", "Uses typographic dashes in TextEdit.", .applications, "minus.forwardslash.plus", domain: "com.apple.TextEdit", key: "SmartDashes", default: true, restart: .application),
        bool("apps.mail-reply-animation", "Mail reply animations", "Animates the composer when replying to a message.", .applications, "arrowshape.turn.up.left", domain: "com.apple.mail", key: "DisableReplyAnimations", enabled: false, default: false, restart: .application, tier: .advanced),
        bool("apps.mail-send-animation", "Mail send animations", "Animates messages as they are sent.", .applications, "paperplane", domain: "com.apple.mail", key: "DisableSendAnimations", enabled: false, default: false, restart: .application, tier: .advanced),
        bool("apps.mail-copy-address-name", "Include names when copying Mail addresses", "Copies both the contact name and address from Mail's address fields.", .applications, "person.text.rectangle", domain: "com.apple.mail", key: "AddressesIncludeNameOnPasteboard", default: true, restart: .application, tier: .advanced),
        integerToggle("apps.activitymonitor-dock", "Activity Monitor CPU Dock icon", "Shows live CPU history in Activity Monitor's Dock icon.", .applications, "waveform.path.ecg.rectangle", domain: "com.apple.ActivityMonitor", key: "IconType", enabled: 5, disabled: 0, default: 0, restart: .application, tier: .experimental),

        bool("developer.webkit-inspector", "WebKit developer extras", "Enables contextual Web Inspector commands in WebKit views that honor the global preference.", .developer, "hammer", domain: globalDomain, key: "WebKitDeveloperExtras", default: false, restart: .application, tier: .advanced),
        bool("developer.safari-internal-debug", "Safari internal debug menu", "Enables Safari's undocumented internal debug menu where supported.", .developer, "ladybug", domain: "com.apple.Safari", key: "IncludeInternalDebugMenu", default: false, restart: .application, tier: .experimental),
        bool("developer.diskutility-debug", "Disk Utility debug menu", "Shows additional diagnostic commands in Disk Utility on versions that still expose them.", .developer, "internaldrive.fill", domain: "com.apple.DiskUtility", key: "DUDebugMenuEnabled", default: false, restart: .application, tier: .experimental),
        bool("developer.diskutility-advanced-images", "Disk Utility advanced image options", "Shows additional disk-image formats and options where supported.", .developer, "opticaldisc", domain: "com.apple.DiskUtility", key: "advanced-image-options", default: false, restart: .application, tier: .experimental),
        bool("developer.xcode-line-numbers", "Xcode line numbers", "Shows line numbers in Xcode source editors.", .developer, "number", domain: "com.apple.dt.Xcode", key: "DVTTextShowLineNumbers", default: true, restart: .application, tier: .advanced),
        bool("developer.terminal-secure-input", "Terminal secure keyboard entry", "Requests protected keyboard input while Terminal is active. This can affect global hotkeys.", .developer, "terminal", domain: "com.apple.Terminal", key: "SecureKeyboardEntry", default: false, restart: .application, tier: .advanced),

        bool("accessibility.reduce-motion", "Reduce motion", "Reduces interface movement and animation across macOS.", .accessibility, "figure.walk.motion", domain: "com.apple.universalaccess", key: "reduceMotion", default: false),
        bool("accessibility.reduce-transparency", "Reduce transparency", "Replaces translucent backgrounds with more opaque surfaces.", .accessibility, "circle.dotted", domain: "com.apple.universalaccess", key: "reduceTransparency", default: false),
        bool("accessibility.increase-contrast", "Increase contrast", "Increases separation and border contrast in the interface.", .accessibility, "circle.lefthalf.striped.horizontal", domain: "com.apple.universalaccess", key: "increaseContrast", default: false),
        bool("accessibility.differentiate-color", "Differentiate without color", "Adds shapes or labels so status is not communicated by color alone.", .accessibility, "eye.circle", domain: "com.apple.universalaccess", key: "differentiateWithoutColor", default: false),
        bool("accessibility.flash-screen", "Flash screen for alert sounds", "Flashes the screen when macOS plays an alert sound.", .accessibility, "light.beacon.max", domain: globalDomain, key: "com.apple.sound.beep.flash", default: false),

        restricted("security.gatekeeper", "Disable Gatekeeper", "MacScope never disables application signature and notarization checks.", .security, "checkmark.shield", "This would weaken a core macOS security boundary and is intentionally not offered."),
        restricted("security.sip", "Disable System Integrity Protection", "SIP can only be managed from Recovery and should remain enabled.", .security, "lock.shield", "MacScope does not bypass or weaken System Integrity Protection."),
        restricted("security.quarantine", "Disable downloaded-file quarantine", "Quarantine metadata protects users before opening downloaded software.", .security, "exclamationmark.shield", "MacScope does not remove the system quarantine safety check globally."),
        restricted("security.tcc", "Bypass privacy permissions", "TCC controls access to protected personal data and sensors.", .security, "hand.raised", "MacScope respects TCC and cannot grant itself or other apps protected access."),
        restricted("security.loginwindow-root", "Root login-window preferences", "System login-window policy is managed by macOS, administrators, or device management.", .security, "person.badge.key", "System-wide login policy requires administrator or MDM authority and is not changed from this catalog."),
        restricted("security.software-update", "Disable automatic security updates", "Rapid Security Responses and system data updates should remain enabled.", .security, "arrow.triangle.2.circlepath", "MacScope does not disable automatic security and system-data updates.")
    ] + manualEntries

    /// First-party macOS controls for which Apple exposes no supported general
    /// writer. They remain searchable and documented, but MacScope sends the
    /// user to System Settings instead of guessing at private preference keys.
    private static let manualEntries: [MacOSFeatureDescriptor] = [
        manual("manual.appearance.liquid-glass", "Liquid Glass appearance", "Choose clear or tinted Liquid Glass on supported macOS versions.", .appearance, "drop.halffull", minimumOSMajor: 26),
        manual("manual.appearance.accent-color", "Accent color", "Choose the color used for buttons, selections, and other controls.", .appearance, "paintpalette"),
        manual("manual.appearance.highlight-color", "Text highlight color", "Choose the color used when text is selected.", .appearance, "highlighter"),
        manual("manual.appearance.sidebar-size", "Sidebar icon size", "Choose small, medium, or large icons in app sidebars.", .appearance, "sidebar.left"),
        manual("manual.appearance.icon-style", "App icon style", "Choose default, dark, clear, or tinted app icons where supported.", .appearance, "app.dashed", minimumOSMajor: 26),
        manual("manual.appearance.widget-style", "Widget style", "Choose automatic, monochrome, or full-color widgets.", .appearance, "widget.medium"),
        manual("manual.appearance.wallpaper-tint", "Wallpaper tint in windows", "Allow windows to pick up color from the desktop wallpaper.", .appearance, "paintbrush.pointed"),
        manual("manual.appearance.click-scrollbar", "Scroll-bar click behavior", "Choose whether a click jumps by one page or to the clicked position.", .appearance, "scroll"),

        manual("manual.finder.new-window-target", "New Finder window location", "Choose the folder opened by new Finder windows.", .finder, "folder.badge.plus"),
        manual("manual.finder.search-scope", "Default Finder search scope", "Search the whole Mac, the current folder, or the last-used scope.", .finder, "magnifyingglass"),
        manual("manual.finder.icloud-remove-warning", "Warn before removing from iCloud Drive", "Keep Finder's safeguard before removing downloaded iCloud items.", .finder, "icloud.and.arrow.down"),
        manual("manual.finder.folders-first", "Keep folders on top", "Place folders before files when Finder windows are sorted by name.", .finder, "folder.fill"),
        manual("manual.finder.desktop-folders-first", "Keep desktop folders on top", "Place folders before files on the desktop.", .finder, "desktopcomputer.and.arrow.down"),
        manual("manual.finder.sidebar-items", "Finder sidebar items", "Choose which favorites, iCloud locations, devices, and tags appear.", .finder, "sidebar.leading"),
        manual("manual.finder.tags", "Finder sidebar tags", "Choose which file tags are visible in the Finder sidebar.", .finder, "tag"),
        manual("manual.finder.open-new-tabs", "Open folders in tabs", "Prefer tabs when opening folders while a Finder window is active.", .finder, "macwindow.on.rectangle"),
        manual("manual.finder.calculate-sizes", "Calculate all folder sizes", "Show folder sizes in list view; this can increase storage I/O.", .finder, "sum"),
        manual("manual.finder.icon-previews", "Show icon previews", "Generate content previews for files in Finder icon view.", .finder, "photo.on.rectangle"),
        manual("manual.finder.item-info", "Show item information", "Show image dimensions, item counts, and other details below icons.", .finder, "info.square"),
        manual("manual.finder.preview-column", "Show Finder preview column", "Display a preview and metadata column in column view.", .finder, "rectangle.righthalf.inset.filled"),

        manual("manual.dock.size", "Dock size", "Adjust the base size of Dock icons.", .dock, "dock.rectangle"),
        manual("manual.dock.position", "Dock position", "Place the Dock on the left, bottom, or right edge.", .dock, "rectangle.bottomthird.inset.filled"),
        manual("manual.dock.magnified-size", "Dock magnified size", "Adjust how large Dock icons become under the pointer.", .dock, "plus.magnifyingglass"),
        manual("manual.windows.titlebar-double-click", "Title-bar double-click action", "Choose Fill, Zoom, Minimize, or no action.", .windows, "rectangle.topthird.inset.filled"),
        manual("manual.windows.prefer-tabs", "Prefer tabs when opening documents", "Choose never, always, or only in full screen.", .windows, "rectangle.stack"),
        manual("manual.windows.ask-save", "Ask to keep changes when closing documents", "Require an explicit decision before discarding document changes.", .windows, "questionmark.square"),
        manual("manual.windows.default-browser", "Default web browser", "Choose which installed browser opens web links.", .windows, "globe"),
        manual("manual.windows.desktop-widgets", "Show desktop widgets", "Show or hide widgets on the desktop.", .windows, "widget.small"),
        manual("manual.windows.iphone-widgets", "Use iPhone widgets", "Allow compatible widgets from a nearby signed-in iPhone.", .windows, "iphone"),
        manual("manual.windows.stage-recents", "Stage Manager recent applications", "Show or hide the recent-applications strip.", .windows, "clock.arrow.circlepath"),
        manual("manual.windows.stage-grouping", "Stage Manager window grouping", "Show all windows from an app or one window at a time.", .windows, "square.3.layers.3d"),
        manual("manual.windows.switch-space", "Switch to an app's open Space", "Move to the Space containing an application's open windows.", .windows, "arrow.right.square"),
        manual("manual.windows.mission-top", "Mission Control at screen top", "Open Mission Control when a window is dragged to the top edge.", .windows, "arrow.up.to.line.compact"),
        manual("manual.windows.mission-shortcuts", "Mission Control shortcuts", "Configure keyboard and mouse shortcuts for Mission Control.", .windows, "keyboard.badge.ellipsis"),
        manual("manual.windows.hotcorner-tl", "Top-left Hot Corner", "Assign a system action and optional modifier keys.", .windows, "arrow.up.left.square"),
        manual("manual.windows.hotcorner-tr", "Top-right Hot Corner", "Assign a system action and optional modifier keys.", .windows, "arrow.up.right.square"),
        manual("manual.windows.hotcorner-bl", "Bottom-left Hot Corner", "Assign a system action and optional modifier keys.", .windows, "arrow.down.left.square"),
        manual("manual.windows.hotcorner-br", "Bottom-right Hot Corner", "Assign a system action and optional modifier keys.", .windows, "arrow.down.right.square"),

        manual("manual.keyboard.repeat-rate", "Key repeat rate", "Adjust how quickly a held key repeats.", .keyboard, "repeat"),
        manual("manual.keyboard.repeat-delay", "Delay until repeat", "Adjust how long a key must be held before repeating.", .keyboard, "timer"),
        manual("manual.keyboard.brightness", "Keyboard brightness", "Adjust backlight brightness on supported built-in keyboards.", .keyboard, "keyboard.badge.ellipsis"),
        manual("manual.keyboard.auto-brightness", "Automatic keyboard brightness", "Adjust keyboard backlight automatically in low light.", .keyboard, "sun.min"),
        manual("manual.keyboard.backlight-timeout", "Keyboard backlight timeout", "Turn the keyboard backlight off after a chosen idle duration.", .keyboard, "moon.zzz"),
        manual("manual.keyboard.dictation", "Dictation", "Configure on-device or server-assisted dictation, language, and shortcut.", .keyboard, "mic"),
        manual("manual.keyboard.input-shortcuts", "Input source shortcuts", "Configure shortcuts for switching keyboard input sources.", .keyboard, "globe.badge.chevron.backward"),
        manual("manual.keyboard.text-replacements", "Text replacements", "Manage shortcuts that expand into longer text.", .keyboard, "text.badge.plus"),
        manual("manual.keyboard.spotlight-shortcut", "Spotlight keyboard shortcut", "Configure the global shortcut that opens Spotlight.", .keyboard, "magnifyingglass.circle"),

        manual("manual.pointer.tracking-speed", "Pointer tracking speed", "Adjust how far the pointer moves for mouse or trackpad motion.", .pointer, "cursorarrow.motionlines"),
        manual("manual.pointer.force-click", "Force Click and haptic feedback", "Enable pressure-sensitive clicking on supported trackpads.", .pointer, "hand.point.up.braille"),
        manual("manual.pointer.lookup", "Look up and data detectors", "Choose the gesture used to look up words and detected data.", .pointer, "text.magnifyingglass"),
        manual("manual.pointer.smart-zoom", "Smart zoom", "Double-tap to zoom compatible content.", .pointer, "plus.magnifyingglass"),
        manual("manual.pointer.fullscreen-swipe", "Swipe between full-screen apps", "Choose the gesture for moving between full-screen apps and Spaces.", .pointer, "rectangle.3.group"),
        manual("manual.pointer.notification-gesture", "Notification Center gesture", "Choose the trackpad gesture used to reveal notifications.", .pointer, "bell"),
        manual("manual.pointer.app-expose", "App Exposé gesture", "Choose the gesture that reveals all windows for the current app.", .pointer, "square.grid.3x3"),
        manual("manual.pointer.show-desktop", "Show Desktop gesture", "Choose the gesture that moves windows aside.", .pointer, "rectangle.dashed"),
        manual("manual.pointer.silent-click", "Silent clicking", "Reduce trackpad click sound on supported hardware.", .pointer, "speaker.slash"),
        manual("manual.pointer.click-pressure", "Trackpad click pressure", "Choose light, medium, or firm click pressure.", .pointer, "gauge.with.needle"),
        manual("manual.pointer.pointer-size", "Pointer size and colors", "Adjust cursor size, outline color, and fill color.", .pointer, "cursorarrow"),
        manual("manual.pointer.shake-locate", "Shake pointer to locate", "Temporarily enlarge the pointer after rapid movement.", .pointer, "cursorarrow.rays"),

        manual("manual.capture.location", "Screenshot save location", "Choose the folder where screenshots and recordings are saved.", .capture, "folder.badge.arrow.down"),
        manual("manual.capture.pointer", "Show pointer in screenshots", "Include the pointer in compatible screenshot modes.", .capture, "cursorarrow"),
        manual("manual.capture.clicks", "Show clicks in screen recordings", "Visualize pointer clicks in new recordings.", .capture, "cursorarrow.click"),
        manual("manual.capture.microphone", "Screen recording microphone", "Choose no microphone or a specific input device.", .capture, "mic"),
        manual("manual.capture.timer", "Screenshot timer", "Choose no delay, five seconds, or ten seconds.", .capture, "timer"),
        manual("manual.capture.hdr", "HDR screenshots and recordings", "Choose SDR or HDR capture on supported displays and macOS versions.", .capture, "sun.max", minimumOSMajor: 26),

        manual("manual.accessibility.invert", "Invert colors", "Invert display colors while preserving supported media.", .accessibility, "circle.lefthalf.filled.inverse"),
        manual("manual.accessibility.voiceover", "VoiceOver", "Configure the built-in screen reader and its activation shortcut.", .accessibility, "speaker.wave.3"),
        manual("manual.accessibility.color-filters", "Color filters", "Apply grayscale, color-blindness filters, or a custom tint.", .accessibility, "camera.filters"),
        manual("manual.accessibility.zoom", "Accessibility Zoom", "Configure full-screen, split-screen, or picture-in-picture zoom.", .accessibility, "plus.magnifyingglass"),
        manual("manual.accessibility.hover-text", "Hover Text", "Show a large high-contrast version of text under the pointer.", .accessibility, "textformat.size.larger"),
        manual("manual.accessibility.spoken-content", "Spoken Content", "Configure selection, hover, and typing feedback speech.", .accessibility, "text.bubble"),
        manual("manual.accessibility.live-captions", "Live Captions", "Generate captions for compatible audio where supported.", .accessibility, "captions.bubble"),
        manual("manual.accessibility.background-sounds", "Background Sounds", "Play balanced noise, ocean, rain, or stream sounds.", .accessibility, "waveform"),
        manual("manual.accessibility.voice-control", "Voice Control", "Control the Mac and dictate text using spoken commands.", .accessibility, "waveform.badge.mic"),
        manual("manual.accessibility.sticky-keys", "Sticky Keys", "Press modifier keys sequentially instead of simultaneously.", .accessibility, "command"),
        manual("manual.accessibility.slow-keys", "Slow Keys", "Require keys to be held for a chosen acceptance delay.", .accessibility, "tortoise"),
        manual("manual.accessibility.mouse-keys", "Mouse Keys", "Control the pointer with the keyboard or numeric keypad.", .accessibility, "keyboard"),
        manual("manual.accessibility.switch-control", "Switch Control", "Control macOS using one or more adaptive switches.", .accessibility, "switch.2"),
        manual("manual.accessibility.head-pointer", "Head Pointer and Dwell Control", "Control the pointer using head movement and dwell actions.", .accessibility, "person.crop.circle"),

        manual("manual.security.password-wake", "Require password after sleep", "Choose how quickly macOS requires authentication after sleep or the screen saver.", .security, "lock"),
        manual("manual.security.screen-saver", "Screen saver inactivity timer", "Choose when the screen saver starts after inactivity.", .security, "sparkles.tv"),
        manual("manual.security.touch-id", "Touch ID uses", "Choose whether enrolled fingerprints can unlock, authorize purchases, or autofill passwords.", .security, "touchid"),
        manual("manual.security.watch-unlock", "Unlock with Apple Watch", "Allow a nearby authenticated Apple Watch to unlock the Mac.", .security, "applewatch"),
        manual("manual.security.location", "Location Services", "Review system and per-app access to approximate or precise location.", .security, "location"),
        manual("manual.security.analytics", "Analytics and diagnostics sharing", "Review which diagnostic information is shared with Apple and developers.", .security, "chart.bar.doc.horizontal"),
        manual("manual.security.advertising", "Personalized advertising", "Control Apple advertising personalization.", .security, "megaphone"),
        manual("manual.security.camera", "Camera permissions", "Review which applications can use connected cameras.", .security, "camera"),
        manual("manual.security.microphone", "Microphone permissions", "Review which applications can capture microphone audio.", .security, "mic"),
        manual("manual.security.screen-recording", "Screen and system audio recording permissions", "Review which applications can capture screen or system audio.", .security, "record.circle"),
        manual("manual.security.accessibility", "Accessibility permissions", "Review applications permitted to control the Mac through Accessibility.", .security, "figure.roll"),
        manual("manual.security.automation", "Automation permissions", "Review which applications may send Apple Events to other apps.", .security, "gearshape.2"),
        manual("manual.security.full-disk", "Full Disk Access", "Review applications permitted to read protected files and backups.", .security, "externaldrive.badge.checkmark"),
        manual("manual.security.input-monitoring", "Input Monitoring", "Review applications permitted to observe keyboard and pointing-device input.", .security, "keyboard.badge.eye"),
        manual("manual.security.lockdown", "Lockdown Mode", "Use Apple's strongest optional protection against highly sophisticated attacks.", .security, "lock.shield"),
        manual("manual.security.find-my", "Find My Mac", "Configure device location and recovery through the signed-in Apple Account.", .security, "location.viewfinder"),
        manual("manual.security.firewall", "Application Firewall", "Enable the built-in firewall and review incoming-connection rules.", .security, "firewall"),
        manual("manual.security.filevault", "FileVault", "Review full-disk encryption status and recovery options.", .security, "lock.square.stack"),
        manual("manual.security.airdrop", "AirDrop discoverability", "Choose Receiving Off, Contacts Only, or Everyone for a limited period.", .security, "airplayaudio"),
        manual("manual.security.handoff", "Handoff and Universal Clipboard", "Continue activities and copy content between signed-in nearby devices.", .security, "arrow.left.arrow.right.circle"),
        manual("manual.security.airplay-receiver", "AirPlay Receiver", "Allow selected nearby users to stream media to this Mac.", .security, "airplayvideo"),
        manual("manual.security.iphone-mirroring", "iPhone Mirroring access", "Review which iPhones can be mirrored and notification access.", .security, "iphone.gen3"),
        manual("manual.security.file-sharing", "File Sharing", "Review shared folders, users, and SMB access.", .security, "folder.badge.person.crop"),
        manual("manual.security.screen-sharing", "Screen Sharing", "Review remote screen-control access and allowed users.", .security, "rectangle.connected.to.line.below"),
        manual("manual.security.internet-sharing", "Internet Sharing", "Share one network connection through another interface.", .security, "network"),
        manual("manual.security.content-caching", "Content Caching", "Cache Apple software and iCloud content for devices on the local network.", .security, "externaldrive.fill.badge.icloud"),

        manual("manual.power.optimized-charging", "Optimized battery charging", "Reduce battery aging by learning and delaying full charge when appropriate.", .appearance, "battery.100percent.bolt"),
        manual("manual.power.low-power", "Low Power Mode", "Reduce energy use and background activity on supported Macs.", .appearance, "leaf"),
        manual("manual.power.sleep-timers", "Display and system sleep timers", "Choose separate idle sleep behavior on battery and power adapter.", .appearance, "moon.zzz"),
        manual("manual.power.wake-network", "Wake for network access", "Allow selected network activity to wake this Mac.", .files, "network.badge.shield.half.filled"),
        manual("manual.display.true-tone", "True Tone", "Adapt display color and intensity to ambient lighting.", .appearance, "sun.haze"),
        manual("manual.display.night-shift", "Night Shift", "Schedule a warmer display color temperature.", .appearance, "moon.stars"),
        manual("manual.display.mode", "Display resolution, refresh rate, and HDR", "Configure each connected display using modes supported by its hardware.", .appearance, "display"),
        manual("manual.hardware.bluetooth", "Bluetooth power and devices", "Manage Bluetooth state, pairing, and connected peripherals.", .files, "personalhotspot"),
        manual("manual.hardware.sound-output", "Sound input and output devices", "Choose audio devices, volume, balance, and alert sound.", .files, "speaker.wave.2")
    ]

    public static func descriptor(id: String) -> MacOSFeatureDescriptor? {
        all.first { $0.id == id }
    }

    private static func bool(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ category: MacOSFeatureCategory,
        _ icon: String,
        domain: String,
        key: String,
        enabled: Bool = true,
        default defaultValue: Bool,
        restart: MacOSFeatureRestart = .none,
        restartTarget: String? = nil,
        minimumOSMajor: Int = 14,
        maximumOSMajor: Int? = nil,
        tier: MacOSFeatureTier = .recommended,
        sourceURL: String? = nil
    ) -> MacOSFeatureDescriptor {
        MacOSFeatureDescriptor(
            id: id,
            title: title,
            summary: summary,
            category: category,
            icon: icon,
            tier: tier,
            minimumOSMajor: minimumOSMajor,
            maximumOSMajor: maximumOSMajor,
            mechanism: .preference(MacOSFeaturePreference(
                domain: domain,
                key: key,
                enabledValue: .boolean(enabled),
                disabledValue: .boolean(!enabled),
                defaultValue: .boolean(defaultValue),
                restart: restart,
                restartTarget: restartTarget
            )),
            provenance: "macOS defaults database; runtime-verified",
            sourceURL: sourceURL
        )
    }

    private static func stringToggle(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ category: MacOSFeatureCategory,
        _ icon: String,
        domain: String,
        key: String,
        enabled: String,
        disabled: String,
        default defaultValue: String,
        restart: MacOSFeatureRestart = .none,
        tier: MacOSFeatureTier = .recommended
    ) -> MacOSFeatureDescriptor {
        MacOSFeatureDescriptor(
            id: id,
            title: title,
            summary: summary,
            category: category,
            icon: icon,
            tier: tier,
            mechanism: .preference(MacOSFeaturePreference(
                domain: domain,
                key: key,
                enabledValue: .string(enabled),
                disabledValue: .string(disabled),
                defaultValue: .string(defaultValue),
                restart: restart
            )),
            provenance: "macOS defaults database; runtime-verified"
        )
    }

    private static func integerToggle(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ category: MacOSFeatureCategory,
        _ icon: String,
        domain: String,
        key: String,
        enabled: Int,
        disabled: Int,
        default defaultValue: Int,
        restart: MacOSFeatureRestart = .none,
        tier: MacOSFeatureTier = .recommended
    ) -> MacOSFeatureDescriptor {
        MacOSFeatureDescriptor(
            id: id,
            title: title,
            summary: summary,
            category: category,
            icon: icon,
            tier: tier,
            mechanism: .preference(MacOSFeaturePreference(
                domain: domain,
                key: key,
                enabledValue: .integer(enabled),
                disabledValue: .integer(disabled),
                defaultValue: .integer(defaultValue),
                restart: restart
            )),
            provenance: "macOS defaults database; runtime-verified"
        )
    }

    private static func restricted(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ category: MacOSFeatureCategory,
        _ icon: String,
        _ reason: String
    ) -> MacOSFeatureDescriptor {
        MacOSFeatureDescriptor(
            id: id,
            title: title,
            summary: summary,
            category: category,
            icon: icon,
            tier: .restricted,
            mechanism: .restricted(reason: reason),
            provenance: "MacScope security policy"
        )
    }

    private static func manual(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ category: MacOSFeatureCategory,
        _ icon: String,
        minimumOSMajor: Int = 14
    ) -> MacOSFeatureDescriptor {
        MacOSFeatureDescriptor(
            id: id,
            title: title,
            summary: summary,
            category: category,
            icon: icon,
            tier: .advanced,
            minimumOSMajor: minimumOSMajor,
            mechanism: .manual(
                reason: "Apple exposes this control in System Settings but no supported general-purpose writer. MacScope will not guess at a private preference key.",
                settingsURL: "x-apple.systempreferences:"
            ),
            provenance: "Apple System Settings; manual control"
        )
    }
}

public actor MacOSFeatureManager {
    private let catalog: [MacOSFeatureDescriptor]
    private let operatingSystemMajor: Int

    public init(
        catalog: [MacOSFeatureDescriptor] = MacOSFeatureCatalog.all,
        operatingSystemMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        self.catalog = catalog
        self.operatingSystemMajor = operatingSystemMajor
    }

    public func refresh() async -> [MacOSFeatureStatus] {
        let preferences = catalog.compactMap { descriptor -> MacOSFeaturePreference? in
            guard case .preference(let preference) = descriptor.mechanism,
                  isSupported(descriptor) else { return nil }
            return preference
        }
        let domains = Array(Set(preferences.map(\.domain)))
        let valuesByDomain = await readDomains(domains)

        return catalog.map { descriptor in
            guard isSupported(descriptor) else {
                return MacOSFeatureStatus(
                    descriptor: descriptor,
                    state: .unknown,
                    availability: .unsupported,
                    storedValue: nil,
                    detail: "Not available on macOS \(operatingSystemMajor)."
                )
            }
            switch descriptor.mechanism {
            case .manual(let reason, _):
                return MacOSFeatureStatus(
                    descriptor: descriptor,
                    state: .unknown,
                    availability: .degraded,
                    storedValue: nil,
                    detail: reason
                )
            case .restricted(let reason):
                return MacOSFeatureStatus(
                    descriptor: descriptor,
                    state: .unknown,
                    availability: .restricted,
                    storedValue: nil,
                    detail: reason
                )
            case .preference(let preference):
                guard let domainValues = valuesByDomain[preference.domain] else {
                    return MacOSFeatureStatus(
                        descriptor: descriptor,
                        state: .unknown,
                        availability: .degraded,
                        storedValue: nil,
                        detail: "macOS did not allow this preference domain to be read."
                    )
                }
                let stored = domainValues[preference.key]
                let effective = stored.map { $0.normalized(for: preference.enabledValue) } ?? preference.defaultValue
                let state: MacOSFeatureEffectiveState
                if effective == preference.enabledValue { state = .enabled }
                else if effective == preference.disabledValue { state = .disabled }
                else { state = .unknown }
                return MacOSFeatureStatus(
                    descriptor: descriptor,
                    state: state,
                    availability: state == .unknown ? .unmapped : .available,
                    storedValue: stored,
                    detail: stored == nil ? "Using the macOS default value." : nil
                )
            }
        }
    }

    public func setEnabled(_ enabled: Bool, descriptorID: String) async throws -> MacOSFeatureChange {
        guard let descriptor = catalog.first(where: { $0.id == descriptorID }) else {
            throw MacOSFeatureError.unknownFeature
        }
        guard isSupported(descriptor) else { throw MacOSFeatureError.unsupportedOS }
        guard case .preference(let preference) = descriptor.mechanism else {
            if case .manual(let reason, _) = descriptor.mechanism { throw MacOSFeatureError.manual(reason) }
            if case .restricted(let reason) = descriptor.mechanism { throw MacOSFeatureError.restricted(reason) }
            throw MacOSFeatureError.unknownFeature
        }
        let previous = await readDomain(preference.domain)?[preference.key]
        let desired = enabled ? preference.enabledValue : preference.disabledValue
        try await write(desired, preference: preference)
        guard await readDomain(preference.domain)?[preference.key] == desired else {
            try? await restoreStoredValue(previous, preference: preference)
            throw MacOSFeatureError.writeFailed(
                "macOS did not retain the requested value. The previous preference was restored."
            )
        }
        let note = await applyRestart(preference)
        return MacOSFeatureChange(
            descriptorID: descriptorID,
            previousStoredValue: previous,
            enabled: enabled,
            note: note
        )
    }

    public func restore(_ change: MacOSFeatureChange) async throws {
        guard let descriptor = catalog.first(where: { $0.id == change.descriptorID }),
              case .preference(let preference) = descriptor.mechanism else {
            throw MacOSFeatureError.unknownFeature
        }
        try await restoreStoredValue(change.previousStoredValue, preference: preference)
        guard await readDomain(preference.domain)?[preference.key] == change.previousStoredValue else {
            throw MacOSFeatureError.writeFailed("macOS did not retain the restored preference value.")
        }
        _ = await applyRestart(preference)
    }

    private func isSupported(_ descriptor: MacOSFeatureDescriptor) -> Bool {
        guard operatingSystemMajor >= descriptor.minimumOSMajor else { return false }
        if let maximum = descriptor.maximumOSMajor, operatingSystemMajor > maximum { return false }
        return true
    }

    private func readDomains(_ domains: [String]) async -> [String: [String: MacOSFeaturePreferenceValue]] {
        await withTaskGroup(of: (String, [String: MacOSFeaturePreferenceValue]?).self) { group in
            for domain in domains {
                group.addTask { (domain, await Self.exportDomain(domain)) }
            }
            var result: [String: [String: MacOSFeaturePreferenceValue]] = [:]
            for await (domain, values) in group {
                if let values { result[domain] = values }
            }
            return result
        }
    }

    private func readDomain(_ domain: String) async -> [String: MacOSFeaturePreferenceValue]? {
        await Self.exportDomain(domain)
    }

    private static func exportDomain(_ domain: String) async -> [String: MacOSFeaturePreferenceValue]? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-features-\(UUID().uuidString)")
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let result = await CommandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["export", domain, fileURL.path],
            timeout: 4
        )
        guard result.exitCode == 0,
              let data = try? Data(contentsOf: fileURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any] else { return nil }
        return dictionary.reduce(into: [:]) { result, pair in
            if let value = MacOSFeaturePreferenceValue.propertyListValue(pair.value) {
                result[pair.key] = value
            }
        }
    }

    private func write(_ value: MacOSFeaturePreferenceValue, preference: MacOSFeaturePreference) async throws {
        let result = await CommandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["write", preference.domain, preference.key] + value.defaultsArguments,
            timeout: 4
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacOSFeatureError.writeFailed(detail.isEmpty ? "macOS rejected the preference change." : detail)
        }
    }

    private func restoreStoredValue(
        _ value: MacOSFeaturePreferenceValue?,
        preference: MacOSFeaturePreference
    ) async throws {
        if let value {
            try await write(value, preference: preference)
            return
        }
        let result = await CommandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["delete", preference.domain, preference.key],
            timeout: 4
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacOSFeatureError.writeFailed(
                detail.isEmpty ? "Could not restore the macOS default." : detail
            )
        }
    }

    private func applyRestart(_ preference: MacOSFeaturePreference) async -> String? {
        let target: String?
        switch preference.restart {
        case .finder: target = "Finder"
        case .dock: target = "Dock"
        case .systemUIServer: target = "SystemUIServer"
        case .controlCenter: target = "ControlCenter"
        case .none, .application, .logout: target = nil
        }
        guard let target else { return nil }
        let allowedTargets = Set(["Finder", "Dock", "SystemUIServer", "ControlCenter"])
        guard allowedTargets.contains(target) else {
            return "The preference was saved, but its restart target was not allowlisted."
        }
        let result = await CommandRunner.run(
            executable: "/usr/bin/killall",
            arguments: [target],
            timeout: 4
        )
        guard result.exitCode == 0 else {
            return "The preference was saved, but \(target) could not be restarted. It will apply after the next login or relaunch."
        }
        return nil
    }
}
