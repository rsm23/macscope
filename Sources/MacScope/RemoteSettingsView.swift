import AppKit
import CoreImage.CIFilterBuiltins
import MacScopeMCPBridge
import SwiftUI

struct RemoteSettingsView: View {
    let model: AppModel

    @AppStorage(MacScopeRemoteControlClient.enabledKey) private var enabled = false
    @AppStorage(MacScopeRemoteControlClient.relayURLKey) private var relayURL = ""
    @AppStorage(MacScopeRemoteControlClient.macNameKey) private var macName = ""
    @AppStorage(MacScopeRemoteControlClient.allowUtilityWritesKey) private var allowUtilityWrites = false
    @AppStorage(MacScopeRemoteControlClient.allowDestructiveUtilitiesKey) private var allowDestructiveUtilities = false
    @AppStorage(MacScopeRemoteControlClient.allowFeatureHubWritesKey) private var allowFeatureHubWrites = false
    @AppStorage(MacScopeRemoteControlClient.allowMacOSFeatureWritesKey) private var allowMacOSFeatureWrites = false
    @AppStorage(MacScopeRemoteControlClient.notifyAlertsKey) private var notifyAlerts = true
    @AppStorage(MacScopeRemoteControlClient.notifyPresenceKey) private var notifyPresence = true
    @AppStorage(MacScopeRemoteControlClient.notifyCommandsKey) private var notifyCommands = true
    @State private var allowedUtilityActions: Set<String> = []
    @State private var confirmsReset = false

    private var remote: MacScopeRemoteControlClient { model.remoteControl }

    var body: some View {
        SettingsPage(
            title: "Remote control",
            subtitle: "Monitor and control this Mac from paired iPhone and Android devices.",
            icon: "iphone.and.arrow.forward"
        ) {
            SettingsSection(title: "Connection") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsToggleRow(
                        title: "Enable remote access",
                        detail: "MacScope creates an outbound encrypted connection. No inbound port is opened on this Mac.",
                        icon: "network.badge.shield.half.filled",
                        isOn: $enabled
                    )
                    .onChange(of: enabled) { _, value in remote.setEnabled(value) }

                    SettingsDivider()

                    HStack(spacing: 16) {
                        SettingsRowLabel(
                            title: "Connection status",
                            detail: remote.lastError ?? statusDetail,
                            icon: remote.status.isConnected ? "checkmark.circle.fill" : "circle.dotted"
                        )
                        Spacer(minLength: 20)
                        Label(remote.status.title, systemImage: remote.status.isConnected ? "bolt.horizontal.circle.fill" : "bolt.slash.circle")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(remote.status.isConnected ? .green : .secondary)
                        Button("Reconnect", systemImage: "arrow.clockwise") { remote.reconnect() }
                            .disabled(!enabled)
                            .macScopeGlassButton()
                    }

                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRowLabel(
                            title: "Cloudflare relay",
                            detail: "Use the workers.dev URL printed after deploying the relay. Only HTTPS is accepted in production.",
                            icon: "cloud"
                        )
                        TextField("https://macscope-relay.example.workers.dev", text: $relayURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                        TextField("Mac name shown on mobile", text: $macName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: macName) { _, _ in remote.publishSettingsChanged() }
                    }
                    .padding(.vertical, 14)
                }
            }

            SettingsSection(title: "Pair a device") {
                HStack(alignment: .top, spacing: 20) {
                    Group {
                        if let url = remote.pairingURL, let image = QRCode.image(for: url.absoluteString) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 164, height: 164)
                                .padding(10)
                                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .accessibilityLabel("Remote pairing QR code")
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.quaternary)
                                .frame(width: 184, height: 184)
                                .overlay {
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 48, weight: .light))
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(remote.members.isEmpty ? "Create the owner" : "Invite another member")
                            .font(.headline)
                        Text("Pairing links are single-use and expire after ten minutes. Treat the QR code like a temporary password.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = remote.pairingURL {
                            Text(url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        if let expires = remote.pairingExpiresAt {
                            Label("Expires \(expires.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(expires > .now ? Color.secondary : Color.red)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { inviteButtons }
                            VStack(alignment: .leading, spacing: 8) { inviteButtons }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsSection(title: "Local authorization") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsToggleRow(
                        title: "Utility execution",
                        detail: "Operators and owners may prepare allowlisted utility actions.",
                        icon: "wrench.and.screwdriver",
                        isOn: $allowUtilityWrites
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Destructive utilities",
                        detail: "Allow file moves, deletion, uninstall, and other destructive actions after device authentication.",
                        icon: "exclamationmark.triangle",
                        isOn: $allowDestructiveUtilities
                    )
                    .disabled(!allowUtilityWrites)
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "MacScope modules",
                        detail: "Allow operators and owners to enable or disable Feature Hub modules.",
                        icon: "square.grid.3x3",
                        isOn: $allowFeatureHubWrites
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "macOS feature preferences",
                        detail: "Allow supported preference changes through the existing expiring prepare, apply, and undo flow.",
                        icon: "switch.2",
                        isOn: $allowMacOSFeatureWrites
                    )
                }
                .onChange(of: allowUtilityWrites) { _, _ in remote.publishSettingsChanged() }
                .onChange(of: allowDestructiveUtilities) { _, _ in remote.publishSettingsChanged() }
                .onChange(of: allowFeatureHubWrites) { _, _ in remote.publishSettingsChanged() }
                .onChange(of: allowMacOSFeatureWrites) { _, _ in remote.publishSettingsChanged() }
            }

            SettingsSection(title: "Utility action allowlist") {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(MacScopeMCPUtilityCatalog.actions.enumerated()), id: \.element.id) { index, action in
                            Toggle(isOn: Binding(
                                get: { allowedUtilityActions.contains(action.id) },
                                set: { isAllowed in
                                    if isAllowed { allowedUtilityActions.insert(action.id) }
                                    else { allowedUtilityActions.remove(action.id) }
                                    MacScopeRemoteControlClient.setAllowedUtilityActionIDs(allowedUtilityActions)
                                    remote.publishSettingsChanged()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.title).font(.callout.weight(.medium))
                                    Text("\(action.module.rawValue) · \(action.remoteRisk.rawValue.replacingOccurrences(of: "_", with: " "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 9)
                            if index < MacScopeMCPUtilityCatalog.actions.count - 1 { SettingsDivider() }
                        }
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Allowed actions",
                        detail: "\(allowedUtilityActions.count) of \(MacScopeMCPUtilityCatalog.actions.count) actions may be prepared remotely. Unknown and unselected actions are blocked.",
                        icon: "checklist.checked"
                    )
                }
                .padding(.vertical, 8)
                .disabled(!allowUtilityWrites)
            }

            SettingsSection(title: "Members and devices") {
                if remote.members.isEmpty {
                    ContentUnavailableView(
                        "No paired members",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Scan the owner QR code from the MacScope mobile app.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(remote.members.enumerated()), id: \.element.id) { index, member in
                            HStack(spacing: 14) {
                                Image(systemName: member.role == .owner ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                    .font(.title2)
                                    .foregroundStyle(member.role == .owner ? MacScopeTheme.accent : .secondary)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.displayName).font(.headline)
                                    Text("\(member.role.rawValue.capitalized) · \(member.deviceCount) device\(member.deviceCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if member.role != .owner || remote.members.count > 1 {
                                    Button("Revoke", role: .destructive) {
                                        Task { await remote.revokeMember(member.id) }
                                    }
                                    .macScopeGlassButton()
                                }
                            }
                            .padding(.vertical, 12)
                            if index < remote.members.count - 1 { SettingsDivider() }
                        }
                    }
                }
            }

            SettingsSection(title: "Notification policy") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsToggleRow(
                        title: "Usage alerts",
                        detail: "Allow paired devices to subscribe to configured usage-alert pushes.",
                        icon: "exclamationmark.gauge",
                        isOn: $notifyAlerts
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Online and offline",
                        detail: "Allow pushes when this Mac disconnects or reconnects.",
                        icon: "network",
                        isOn: $notifyPresence
                    )
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Command results",
                        detail: "Allow completion and failure pushes without including command arguments.",
                        icon: "checkmark.circle",
                        isOn: $notifyCommands
                    )
                }
                .onChange(of: notifyAlerts) { _, _ in Task { await remote.updateNotificationPolicy() } }
                .onChange(of: notifyPresence) { _, _ in Task { await remote.updateNotificationPolicy() } }
                .onChange(of: notifyCommands) { _, _ in Task { await remote.updateNotificationPolicy() } }
            }

            SettingsSection(title: "Recent remote activity") {
                if remote.audit.isEmpty {
                    Text("Command metadata will appear here. Live telemetry and command arguments are never stored in the audit log.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(remote.audit.prefix(20).enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 12) {
                                Image(systemName: item.outcome == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(item.outcome == "completed" ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.actionID).font(.callout.monospaced())
                                    Text("\(item.actorName) · \(item.risk.rawValue.replacingOccurrences(of: "_", with: " "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            if index < min(remote.audit.count, 20) - 1 { SettingsDivider() }
                        }
                    }
                }
            }

            SettingsSection(title: "Reset") {
                HStack(spacing: 16) {
                    SettingsRowLabel(
                        title: "Reset remote access",
                        detail: "Revoke every mobile session, rotate the Mac identity, and remove the credentials from Keychain.",
                        icon: "trash"
                    )
                    Spacer(minLength: 20)
                    Button("Reset…", role: .destructive) { confirmsReset = true }
                        .macScopeGlassButton()
                }
            }
        }
        .task {
            allowedUtilityActions = MacScopeRemoteControlClient.allowedUtilityActionIDs()
            remote.startIfEnabled()
            await remote.refreshControlPlane()
        }
        .confirmationDialog(
            "Reset all remote access?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset and revoke every device", role: .destructive) {
                Task { await remote.resetRemoteAccess() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Every mobile device will need to pair again.")
        }
    }

    @ViewBuilder private var inviteButtons: some View {
        Button(remote.members.isEmpty ? "Create Owner QR" : "Owner", systemImage: "person.badge.key") {
            Task { await remote.refreshPairing(role: .owner) }
        }
        .macScopeGlassButton(prominent: remote.members.isEmpty)
        if !remote.members.isEmpty {
            Button("Operator", systemImage: "hand.raised.fingers.spread") {
                Task { await remote.refreshPairing(role: .operator) }
            }
            .macScopeGlassButton()
            Button("Viewer", systemImage: "eye") {
                Task { await remote.refreshPairing(role: .viewer) }
            }
            .macScopeGlassButton()
        }
    }

    private var statusDetail: String {
        guard let environmentID = remote.environmentID else {
            return "Enable remote access after entering the relay URL to create this Mac's environment."
        }
        return "Environment \(environmentID.prefix(12))… · metrics stream only while a mobile dashboard is open."
    }
}

private enum QRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
