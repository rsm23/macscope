import AppKit
import Foundation
import MacScopeCore
import Observation

@MainActor
@Observable
final class QuickToggleService {
    private(set) var showsHiddenFiles = false
    private(set) var showsDesktopIcons = true
    private(set) var isRefreshing = false
    private(set) var isApplying = false
    private(set) var statusMessage: String?

    private let featureManager = MacOSFeatureManager()

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let statuses = await featureManager.refresh()
            if let hidden = statuses.first(where: { $0.id == "finder.hidden-files" }) {
                showsHiddenFiles = hidden.state == .enabled
            }
            if let desktop = statuses.first(where: { $0.id == "finder.desktop-icons" }) {
                showsDesktopIcons = desktop.state == .enabled
            }
            isRefreshing = false
        }
    }

    func setShowsHiddenFiles(_ enabled: Bool) {
        apply(enabled, descriptorID: "finder.hidden-files", success: enabled ? "Hidden files are visible." : "Hidden files are concealed.")
    }

    func setShowsDesktopIcons(_ enabled: Bool) {
        apply(enabled, descriptorID: "finder.desktop-icons", success: enabled ? "Desktop icons are visible." : "Desktop icons are hidden.")
    }

    func toggleAppearance() {
        runAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
            success: "System appearance toggled."
        )
    }

    func emptyTrash() {
        runAppleScript(
            "tell application \"Finder\" to empty trash",
            success: "Trash emptied."
        )
    }

    func ejectRemovableVolumes() {
        guard !isApplying else { return }
        isApplying = true
        statusMessage = "Ejecting removable volumes…"
        Task {
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey],
                options: [.skipHiddenVolumes]
            ) ?? []
            var ejected = 0
            var failures: [String] = []
            for url in urls where url.path != "/" {
                let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey])
                guard values?.volumeIsEjectable == true || values?.volumeIsRemovable == true else { continue }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    ejected += 1
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            if !failures.isEmpty {
                statusMessage = "Could not eject: \(failures.joined(separator: ", "))."
            } else if ejected == 0 {
                statusMessage = "No ejectable volumes are mounted."
            } else {
                statusMessage = "Ejected \(ejected) removable volume\(ejected == 1 ? "" : "s")."
            }
            isApplying = false
        }
    }

    private func apply(_ enabled: Bool, descriptorID: String, success: String) {
        guard !isApplying else { return }
        isApplying = true
        Task {
            do {
                _ = try await featureManager.setEnabled(enabled, descriptorID: descriptorID)
                statusMessage = success
            } catch {
                statusMessage = error.localizedDescription
            }
            let statuses = await featureManager.refresh()
            showsHiddenFiles = statuses.first(where: { $0.id == "finder.hidden-files" })?.state == .enabled
            showsDesktopIcons = statuses.first(where: { $0.id == "finder.desktop-icons" })?.state == .enabled
            isApplying = false
        }
    }

    private func runAppleScript(_ source: String, success: String) {
        guard !isApplying else { return }
        isApplying = true
        Task {
            let result = await CommandRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: 15
            )
            if result.exitCode == 0 {
                statusMessage = success
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                statusMessage = detail.isEmpty
                    ? "macOS did not allow this action. Review Automation permission for MacScope."
                    : detail
            }
            isApplying = false
        }
    }
}
