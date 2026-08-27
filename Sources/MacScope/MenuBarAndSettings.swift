import AppKit
import MacScopeCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("samplingProfile") private var samplingProfile = SamplingProfile.balanced.rawValue
    @AppStorage("processHistoryEnabled") private var processHistoryEnabled = false
    @AppStorage("expertModeEnabled") private var expertModeEnabled = false
    @AppStorage("redactExports") private var redactExports = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var helperStatus = "Checking…"
    @State private var mcpConfigurationStatus: String?
    @State private var mcpConnections: [MCPClientSession] = []
    @State private var mcpConnectionError: String?

    private var helperService: SMAppService {
        .daemon(plistName: "local.taskmanager.MacScope.Helper.plist")
    }

    var body: some View {
        TabView {
            SettingsPage(
                title: "Sampling",
                subtitle: "Balance update frequency with battery and CPU impact.",
                icon: "waveform.path.ecg"
            ) {
                SettingsSamplingGraphic(
                    profile: SamplingProfile(rawValue: samplingProfile) ?? .balanced,
                    isRunning: model.isRunning
                )

                SettingsSection(title: "Collection") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Sampling profile",
                                detail: "Controls how frequently live collectors refresh.",
                                icon: "dial.medium"
                            )
                            Spacer(minLength: 20)
                            Picker("Sampling profile", selection: $samplingProfile) {
                                Text("Low impact").tag(SamplingProfile.lowImpact.rawValue)
                                Text("Balanced").tag(SamplingProfile.balanced.rawValue)
                                Text("Maximum").tag(SamplingProfile.maximum.rawValue)
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: samplingProfile) { _, value in
                            if let profile = SamplingProfile(rawValue: value) { model.setProfile(profile) }
                        }

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Launch at login",
                            detail: "Start monitoring automatically after you sign in.",
                            icon: "power",
                            isOn: $launchAtLogin
                        )
                        .onChange(of: launchAtLogin) { _, enabled in configureLogin(enabled) }

                        SettingsDivider()

                        HStack(spacing: 16) {
                            SettingsRowLabel(
                                title: "Live status",
                                detail: model.isRunning ? "Collectors are actively sampling this Mac." : "Telemetry collection is currently paused.",
                                icon: model.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle"
                            )
                            Spacer(minLength: 20)
                            Label(model.isRunning ? "Sampling" : "Paused", systemImage: model.isRunning ? "circle.fill" : "pause.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(model.isRunning ? .green : .orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gear") }

            SettingsPage(
                title: "Privacy & data",
                subtitle: "MacScope keeps telemetry local and gives you control over retained details.",
                icon: "hand.raised.fill"
            ) {
                SettingsSection(title: "Local history") {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsToggleRow(
                            title: "Store encrypted process history",
                            detail: "Off by default. When enabled, history is encrypted with an AES-256 key stored in Keychain.",
                            icon: "clock.arrow.circlepath",
                            isOn: $processHistoryEnabled
                        )
                        .onChange(of: processHistoryEnabled) { _, enabled in model.setProcessHistoryEnabled(enabled) }

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Redact sensitive export fields",
                            detail: "Hide usernames, paths, addresses, identifiers, and command arguments by default.",
                            icon: "eye.slash",
                            isOn: $redactExports
                        )
                    }
                }

                SettingsSection(title: "Data boundary") {
                    Label {
                        Text("MacScope does not upload telemetry or expose a network-facing API. Exported files stay under your control.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(MacScopeTheme.cyan)
                    }
                }
            }
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            UsageAlertsSettingsView(model: model)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }

            SettingsPage(
                title: "Permissions & helper",
                subtitle: "Manage privileged telemetry and expert system actions.",
                icon: "lock.shield.fill"
            ) {
                SettingsSection(title: "Advanced controls") {
                    SettingsToggleRow(
                        title: "Expert Mode",
                        detail: "Enables typed process and launchd operations. SIP and TCC restrictions are always respected.",
                        icon: "wrench.and.screwdriver",
                        isOn: $expertModeEnabled
                    )
                }

                SettingsSection(title: "Privileged helper") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: helperService.status == .enabled ? "checkmark.shield.fill" : "lock.shield")
                                .font(.title2)
                                .foregroundStyle(helperService.status == .enabled ? .green : .orange)
                                .frame(width: 38, height: 38)
                                .background((helperService.status == .enabled ? Color.green : .orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(helperService.status == .enabled ? "Helper installed" : "Helper not active")
                                    .font(.headline)
                                Text(helperStatus)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("Check", systemImage: "arrow.clockwise") { checkHelper() }
                                .macScopeGlassButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        HStack(spacing: 10) {
                            if helperService.status == .enabled {
                                Button("Remove Helper", systemImage: "trash", role: .destructive) {
                                    configureHelper(enabled: false)
                                }
                                .tint(.red)
                                .macScopeGlassButton()
                            } else {
                                Button("Install Helper", systemImage: "square.and.arrow.down") {
                                    configureHelper(enabled: true)
                                }
                                .macScopeGlassButton(prominent: true)
                            }
                            Spacer()
                            Button("Open Login Items", systemImage: "gear") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .macScopeGlassButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                SettingsSection(title: "AI agent access") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.title2)
                                .foregroundStyle(mcpServerIsBundled ? .green : .orange)
                                .frame(width: 38, height: 38)
                                .background((mcpServerIsBundled ? Color.green : .orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mcpServerIsBundled ? "MCP server ready" : "MCP server unavailable")
                                    .font(.headline)
                                Text(mcpServerIsBundled
                                     ? "Local stdio server with redacted read access by default."
                                     : "Build the packaged MacScope app to bundle the MCP executable.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let mcpConfigurationStatus {
                                Label(mcpConfigurationStatus, systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        Text("Read-only configuration exposes all supported telemetry and feature states. Write-enabled configuration additionally permits expiring, preflighted, reversible changes to MacScope's typed feature allowlist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                mcpConfigurationButtons
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                mcpConfigurationButtons
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        MCPConnectionsView(
                            sessions: mcpConnections,
                            errorMessage: mcpConnectionError
                        )
                    }
                }
            }
            .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 700, height: 560)
        .task {
            checkHelper()
            await monitorMCPConnections()
        }
    }

    private func configureLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func checkHelper() {
        helperStatus = helperService.status == .enabled ? "Registered — connecting…" : helperService.status.displayName
        let connection = NSXPCConnection(machServiceName: privilegedMachServiceName, options: .privileged)
        let connectionBox = XPCConnectionBox(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedTelemetryXPC.self)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in helperStatus = error.localizedDescription }
        }) as? PrivilegedTelemetryXPC else {
            helperStatus = "Unavailable"
            connectionBox.value.invalidate()
            return
        }
        proxy.handshake { version, message in
            Task { @MainActor in helperStatus = "v\(version): \(message)" }
            connectionBox.value.invalidate()
        }
    }

    private func configureHelper(enabled: Bool) {
        do {
            if enabled {
                try helperService.register()
                helperStatus = helperService.status == .enabled ? "Registered — connecting…" : "Approval required in Login Items"
                checkHelper()
            } else {
                try helperService.unregister()
                helperStatus = "Removed"
            }
        } catch {
            helperStatus = error.localizedDescription
        }
    }

    @ViewBuilder private var mcpConfigurationButtons: some View {
        Button("Copy Read-Only Config", systemImage: "doc.on.doc") {
            copyMCPConfiguration(featureWrites: false)
        }
        .disabled(!mcpServerIsBundled)
        .macScopeGlassButton(prominent: true)

        Button("Copy Write-Enabled Config", systemImage: "switch.2") {
            copyMCPConfiguration(featureWrites: true)
        }
        .disabled(!mcpServerIsBundled)
        .macScopeGlassButton()

        Button("Documentation", systemImage: "book.closed") {
            openMCPDocumentation()
        }
        .disabled(mcpDocumentationURL == nil)
        .macScopeGlassButton()
    }

    private var mcpServerURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MacScopeMCPServer")
    }

    private var mcpDocumentationURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("MacScope-MCP-Server.md")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var mcpServerIsBundled: Bool {
        guard let mcpServerURL else { return false }
        return FileManager.default.isExecutableFile(atPath: mcpServerURL.path)
    }

    private func copyMCPConfiguration(featureWrites: Bool) {
        guard let mcpServerURL, mcpServerIsBundled else { return }
        var server: [String: Any] = ["command": mcpServerURL.path]
        server["args"] = featureWrites ? ["--allow-feature-writes"] : []
        let document: [String: Any] = ["mcpServers": ["macscope": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mcpConfigurationStatus = featureWrites ? "Write config copied" : "Read-only config copied"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            mcpConfigurationStatus = nil
        }
    }

    private func openMCPDocumentation() {
        guard let mcpDocumentationURL else { return }
        NSWorkspace.shared.open(mcpDocumentationURL)
    }

    @MainActor
    private func monitorMCPConnections() async {
        do {
            let registry = try MCPConnectionRegistry()
            while !Task.isCancelled {
                mcpConnections = await registry.activeSessions()
                mcpConnectionError = nil
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            mcpConnections = []
            mcpConnectionError = error.localizedDescription
        }
    }
}

private struct MCPConnectionsView: View {
    let sessions: [MCPClientSession]
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected MCP clients")
                        .font(.subheadline.weight(.semibold))
                    Text("Live clients that completed a handshake with MacScope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(sessions.isEmpty ? Color.secondary.opacity(0.45) : Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(sessions.count) connected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sessions.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "cable.connector.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No clients connected")
                            .font(.callout.weight(.medium))
                        Text("Configured clients appear here after their MCP handshake completes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        MCPConnectionRow(session: session)
                        if index < sessions.count - 1 { SettingsDivider() }
                    }
                }
            }
        }
    }
}

private struct MCPConnectionRow: View {
    let session: MCPClientSession

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MacScopeTheme.accent.opacity(0.1))
                Image(systemName: "terminal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacScopeTheme.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if session.displayName != session.clientName {
                        Text(session.clientName)
                    }
                    Text("v\(session.clientVersion)")
                    Text("•")
                    Text("PID \(session.serverPID)")
                    Text("•")
                    Text("MCP \(session.protocolVersion)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(policyLabel)
                    .font(.caption.weight(.medium))
                Text("Active \(relativeActivity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayName), \(policyLabel), connected")
    }

    private var policyLabel: String {
        var policies: [String] = []
        if session.policy.experimentalFeatureWrites {
            policies.append("Experimental controls")
        } else if session.policy.featureWrites {
            policies.append("Feature controls")
        }
        if session.policy.sensitiveReads { policies.append("Sensitive reads") }
        return policies.isEmpty ? "Read only" : policies.joined(separator: " · ")
    }

    private var relativeActivity: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(session.lastActivityAt)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let content: Content

    init(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: icon)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(MacScopeTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(MacScopeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 2)
            }
            Card { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(MacScopeTheme.accent)
                .frame(width: 32, height: 32)
                .background(MacScopeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowLabel(title: title, detail: detail, icon: icon)
                .layoutPriority(1)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 12)
    }
}

private struct SettingsSamplingGraphic: View {
    let profile: SamplingProfile
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 18) {
            Gauge(value: isRunning ? profile.visualIntensity : 0, in: 0...1) {
                Text("Sampling")
            } currentValueLabel: {
                Image(systemName: isRunning ? "waveform.path.ecg" : "pause.fill")
                    .foregroundStyle(isRunning ? MacScopeTheme.accent : .orange)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(isRunning ? MacScopeTheme.accent : .orange)
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isRunning ? "Live sampling" : "Sampling paused").font(.headline)
                    Spacer()
                    Text(profile.intervalLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(SamplingProfile.allCases) { candidate in
                    HStack(spacing: 8) {
                        Text(candidate.displayName)
                            .font(.caption)
                            .foregroundStyle(candidate == profile ? .primary : .secondary)
                            .frame(width: 72, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(candidate == profile ? MacScopeTheme.accent.gradient : Color.secondary.opacity(0.14).gradient)
                                .frame(width: proxy.size.width * candidate.visualIntensity)
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(12)
        .macScopeGlassSurface(cornerRadius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName) sampling, \(profile.intervalLabel), \(isRunning ? "running" : "paused")")
    }
}

private extension SamplingProfile {
    var displayName: String {
        switch self {
        case .lowImpact: "Low impact"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        }
    }

    var intervalLabel: String {
        switch self {
        case .lowImpact: "Every 5 s"
        case .balanced: "Every 1 s"
        case .maximum: "Every 0.5 s"
        }
    }

    var visualIntensity: Double {
        switch self {
        case .lowImpact: 0.25
        case .balanced: 0.58
        case .maximum: 1
        }
    }
}

private extension SMAppService.Status {
    var displayName: String {
        switch self {
        case .notRegistered: "Not installed"
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required in Login Items"
        case .notFound: "Bundled helper not found"
        @unknown default: "Unknown"
        }
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}
