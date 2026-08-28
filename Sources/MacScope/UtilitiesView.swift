import AppKit
import AVFoundation
import MacScopeCore
import SwiftUI

enum UtilityTab: String, CaseIterable, Identifiable {
    case sound = "Sound"
    case capture = "Capture"
    case workspace = "Windows"
    case clipboard = "Clipboard"
    case notes = "Notes"
    case maintenance = "Maintain"
    case power = "Power"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sound: "speaker.wave.2"
        case .capture: "camera.viewfinder"
        case .workspace: "macwindow.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .maintenance: "wrench.and.screwdriver"
        case .power: "cup.and.saucer"
        }
    }
}

struct UtilitiesView: View {
    let mixer: AudioMixerService
    let musicBlocker: MusicAutoLaunchBlocker
    let workspace: WorkspaceUtilityService
    let snippetShelf: SnippetShelfService
    let clipboard: ClipboardHistoryService
    let maintenance: MaintenanceUtilityService
    let screenshots: ScreenshotService
    let keepAwake: KeepAwakeService
    let screenOCR: ScreenOCRService
    let colorPicker: ColorPickerService
    let screenRecorder: ScreenRecordingService
    let cameraPreview: CameraPreviewService
    let keyboardDebounce: KeyboardDebounceService
    let scrollDirection: ScrollDirectionService
    let mouseSideButtons: MouseSideButtonService
    let focusFollowsMouse: FocusFollowsMouseService
    let superKey: SuperKeyService
    let smoothScrolling: SmoothScrollingService
    let plainTextPaste: PlainTextPasteService
    let finderShortcuts: FinderShortcutService
    let scratchpad: ScratchpadService
    let media: MediaUtilityService
    let displayControl: DisplayControlService
    let cleaningMode: CleaningModeService
    @Binding var selectedTab: UtilityTab
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    var body: some View {
        ZStack {
            MacScopeTheme.contentBackground
                .ignoresSafeArea()

            Group {
                switch selectedTab {
                case .sound: SoundUtilityView(mixer: mixer, musicBlocker: musicBlocker, selectedTab: $selectedTab)
                case .capture:
                    CaptureUtilityView(
                        screenshots: screenshots,
                        ocr: screenOCR,
                        colorPicker: colorPicker,
                        recorder: screenRecorder,
                        camera: cameraPreview,
                        media: media,
                        selectedTab: $selectedTab
                    )
                case .workspace:
                    WorkspaceUtilityView(
                        service: workspace,
                        keyboardDebounce: keyboardDebounce,
                        scrollDirection: scrollDirection,
                        mouseSideButtons: mouseSideButtons,
                        focusFollowsMouse: focusFollowsMouse,
                        superKey: superKey,
                        smoothScrolling: smoothScrolling,
                        selectedTab: $selectedTab
                    )
                case .clipboard:
                    ClipboardUtilityView(
                        service: clipboard,
                        snippetShelf: snippetShelf,
                        plainTextPaste: plainTextPaste,
                        finderShortcuts: finderShortcuts,
                        selectedTab: $selectedTab
                    )
                case .notes: ScratchpadUtilityView(service: scratchpad, selectedTab: $selectedTab)
                case .maintenance:
                    MaintenanceUtilityView(
                        service: maintenance,
                        media: media,
                        selectedTab: $selectedTab
                    )
                case .power:
                    KeepAwakeUtilityView(
                        service: keepAwake,
                        displays: displayControl,
                        cleaningMode: cleaningMode,
                        selectedTab: $selectedTab
                    )
                }
            }
        }
        .navigationTitle("Utilities")
        .task {
            mixer.start()
            if UtilityFeatureStore.isEnabled(.capture, stored: disabledModules) { screenshots.refresh() }
            if UtilityFeatureStore.isEnabled(.clipboard, stored: disabledModules) { clipboard.restorePreference() }
            if UtilityFeatureStore.isEnabled(.power, stored: disabledModules) { keepAwake.restoreAutomations() }
        }
        .onDisappear {
            mixer.stop()
        }
        .onAppear { selectAvailableTab() }
        .onChange(of: disabledModules) { _, _ in selectAvailableTab() }
    }

    private func selectAvailableTab() {
        let tabs = UtilityTab.enabled(from: disabledModules)
        if !tabs.contains(selectedTab) { selectedTab = tabs.first ?? .sound }
    }

}

private struct UtilityTabPicker: View {
    @Binding var selection: UtilityTab
    @AppStorage(UtilityFeatureStore.disabledKey) private var disabledModules = ""

    var body: some View {
        HStack(spacing: 12) {
            Text("Utility")
                .font(.callout.weight(.medium))
            HStack(spacing: 2) {
                ForEach(UtilityTab.enabled(from: disabledModules)) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(selection == tab ? Color.white : Color.primary)
                            .frame(width: 62)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selection == tab ? MacScopeTheme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SoundUtilityView: View {
    let mixer: AudioMixerService
    let musicBlocker: MusicAutoLaunchBlocker
    @Binding var selectedTab: UtilityTab
    @State private var confirmsMusicBlocker = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Sound control",
                    subtitle: "Master output, device switching and independent per-app volume"
                )
                UtilityTabPicker(selection: $selectedTab)

                GlassGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("System output", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                        HStack(spacing: 12) {
                            Button {
                                mixer.toggleSystemMute()
                            } label: {
                                Image(systemName: mixer.systemMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .disabled(mixer.systemMuted == nil)

                            if let volume = mixer.systemVolume {
                                Slider(
                                    value: Binding(
                                        get: { mixer.systemVolume ?? volume },
                                        set: { mixer.setSystemVolume($0) }
                                    ),
                                    in: 0...1
                                )
                                Text("\(Int((mixer.systemVolume ?? volume) * 100))%")
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 48, alignment: .trailing)
                            } else {
                                Text("Volume is controlled by the selected hardware device.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !mixer.outputDevices.isEmpty {
                            Divider()
                            HStack {
                                Text("Output device").font(.callout.weight(.medium))
                                Spacer()
                                Picker("Output device", selection: Binding(
                                    get: { mixer.outputDevices.first(where: \AudioOutputDevice.isDefault)?.id ?? 0 },
                                    set: { id in
                                        if let device = mixer.outputDevices.first(where: { $0.id == id }) {
                                            mixer.selectOutput(device)
                                        }
                                    }
                                )) {
                                    ForEach(mixer.outputDevices) { device in
                                        Text(device.name).tag(device.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280)
                            }
                            HStack(spacing: 12) {
                                Toggle("Lower volume when headphones disconnect", isOn: Binding(
                                    get: { mixer.lowersVolumeAfterHeadphoneDisconnect },
                                    set: { mixer.setLowersVolumeAfterHeadphoneDisconnect($0) }
                                ))
                                Slider(value: Binding(
                                    get: { mixer.disconnectVolume },
                                    set: { mixer.disconnectVolume = $0 }
                                ), in: 0...0.75, step: 0.05)
                                .frame(maxWidth: 150)
                                .disabled(!mixer.lowersVolumeAfterHeadphoneDisconnect)
                                Text("\(Int(mixer.disconnectVolume * 100))%")
                                    .font(.caption.monospacedDigit()).frame(width: 38)
                                Button("Cycle Output", systemImage: "airplayaudio") { mixer.cycleOutput() }
                                    .macScopeGlassButton()
                            }
                            .font(.caption)
                        }
                    }
                }

                GlassGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "music.note.slash")
                            .font(.title2)
                            .foregroundStyle(musicBlocker.isEnabled ? MacScopeTheme.accent : .secondary)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Music auto-launch blocker").font(.headline)
                            Text("When enabled, MacScope asks Apple Music to quit whenever it launches.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { musicBlocker.isEnabled },
                            set: { enabled in
                                if enabled { confirmsMusicBlocker = true }
                                else { musicBlocker.setEnabled(false) }
                            }
                        ))
                        .labelsHidden()
                    }
                    if let message = musicBlocker.statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .confirmationDialog(
                    "Block Apple Music launches?",
                    isPresented: $confirmsMusicBlocker,
                    titleVisibility: .visible
                ) {
                    Button("Enable Music Blocker") { musicBlocker.setEnabled(true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Apple Music will be sent a normal quit request every time it launches, including launches you start yourself.")
                }

                GlassGroup {
                    HStack(spacing: 14) {
                        Button {
                            mixer.toggleInputMute()
                        } label: {
                            Image(systemName: mixer.inputMuted == true ? "mic.slash.fill" : "mic.fill")
                                .font(.title2)
                                .foregroundStyle(mixer.inputMuted == true ? .red : MacScopeTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .disabled(mixer.inputMuted == nil)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(mixer.inputMuted == true ? "Microphone muted" : "Microphone input")
                                .font(.headline)
                            Text("Mute every connected input or switch the default microphone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !mixer.inputDevices.isEmpty {
                            Picker("Input device", selection: Binding(
                                get: { mixer.inputDevices.first(where: \AudioInputDevice.isDefault)?.id ?? 0 },
                                set: { id in
                                    if let device = mixer.inputDevices.first(where: { $0.id == id }) {
                                        mixer.selectInput(device)
                                    }
                                }
                            )) {
                                ForEach(mixer.inputDevices) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
                            Button(mixer.pinnedInputUID == nil ? "Pin" : "Unpin", systemImage: mixer.pinnedInputUID == nil ? "pin" : "pin.slash") {
                                mixer.toggleInputPin()
                            }
                            .macScopeGlassButton(prominent: mixer.pinnedInputUID != nil)
                        }
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("App volume mixer").font(.headline)
                                Text("Apps appear after they establish an audio connection. Settings persist by bundle identifier.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { mixer.refresh() }
                                .macScopeGlassButton()
                        }
                        .padding(.bottom, 12)

                        if !mixer.isSupported {
                            UtilityNotice(
                                icon: "exclamationmark.triangle",
                                title: "Per-app audio needs macOS 14.4 or newer",
                                detail: "Master volume and output switching remain available."
                            )
                        } else if mixer.apps.isEmpty {
                            UtilityNotice(
                                icon: "waveform",
                                title: "No audio apps connected",
                                detail: "Start playback in an app, then refresh."
                            )
                        } else {
                            ForEach(mixer.apps) { app in
                                AppVolumeRow(app: app, mixer: mixer)
                                if app.id != mixer.apps.last?.id { Divider() }
                            }
                        }
                    }
                }

                if mixer.needsSystemAudioPermission {
                    UtilityNotice(
                        icon: "lock.trianglebadge.exclamationmark",
                        title: "System Audio Recording permission needed",
                        detail: "Open System Settings › Privacy & Security › Screen & System Audio Recording, enable MacScope, then relaunch it."
                    )
                }
                if let error = mixer.errorMessage {
                    UtilityErrorBanner(message: error)
                }
            }
            .padding(24)
        }
    }
}

private struct AppVolumeRow: View {
    let app: AudioMixerApp
    let mixer: AudioMixerService
    @State private var draftVolume: Double

    init(app: AudioMixerApp, mixer: AudioMixerService) {
        self.app = app
        self.mixer = mixer
        _draftVolume = State(initialValue: app.volume)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(app.isPlaying ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                Image(systemName: app.isPlaying ? "waveform.circle.fill" : "app.fill")
                    .foregroundStyle(app.isPlaying ? .green : .secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(app.isPlaying ? "Playing · pid \(app.pid)" : "Connected · pid \(app.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 165, alignment: .leading)

            Button {
                draftVolume = app.volume > 0.001 ? 0 : 1
                mixer.toggleMute(app)
            } label: {
                Image(systemName: app.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Slider(value: $draftVolume, in: 0...2) { editing in
                if !editing { mixer.setVolume(draftVolume, for: app) }
            }
            HStack(spacing: 2) {
                TextField("Volume", value: Binding(
                    get: { Int((draftVolume * 100).rounded()) },
                    set: { draftVolume = UtilitySupport.sanitizedAppVolume(Double($0) / 100) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .onSubmit { mixer.setVolume(draftVolume, for: app) }
                Text("%").foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
            .frame(width: 68)
            Picker("App output", selection: Binding<String?>(
                get: { app.outputDeviceUID },
                set: { uid in
                    mixer.setOutputDevice(
                        mixer.outputDevices.first(where: { $0.uid == uid }),
                        for: app
                    )
                }
            )) {
                Text("System output").tag(String?.none)
                ForEach(mixer.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Route only \(app.name) to another output")
            Button("Reset") {
                draftVolume = 1
                mixer.setVolume(1, for: app)
            }
            .buttonStyle(.link)
            .disabled(UtilitySupport.isUnityVolume(draftVolume))
        }
        .padding(.vertical, 10)
        .onChange(of: app.volume) { _, value in
            if abs(value - draftVolume) > 0.005 { draftVolume = value }
        }
    }
}

private struct WorkspaceUtilityView: View {
    let service: WorkspaceUtilityService
    let keyboardDebounce: KeyboardDebounceService
    let scrollDirection: ScrollDirectionService
    let mouseSideButtons: MouseSideButtonService
    let focusFollowsMouse: FocusFollowsMouseService
    let superKey: SuperKeyService
    let smoothScrolling: SmoothScrollingService
    @Binding var selectedTab: UtilityTab

    private let layoutColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Windows & applications",
                    subtitle: "Arrange the active window and jump between running apps without leaving MacScope"
                )
                UtilityTabPicker(selection: $selectedTab)

                if !service.accessibilityTrusted {
                    GlassGroup {
                        HStack(spacing: 14) {
                            UtilityNotice(
                                icon: "accessibility",
                                title: "Accessibility permission",
                                detail: "Window layouts need permission to move and resize windows from other apps."
                            )
                            Spacer()
                            Button("Request Access", systemImage: "gearshape") {
                                service.requestAccessibilityPermission()
                            }
                            .macScopeGlassButton(prominent: true)
                        }
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Window layouts", systemImage: "rectangle.3.group")
                                    .font(.headline)
                                Text("Target: \(service.frontmostApplication). Layouts use the primary display's usable area.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                service.restorePreviousLayout()
                            }
                            .macScopeGlassButton()
                            Button("Previous Display", systemImage: "arrow.left.to.line") {
                                service.moveActiveWindowToAdjacentDisplay(offset: -1)
                            }
                            .macScopeGlassButton()
                            Button("Next Display", systemImage: "arrow.right.to.line") {
                                service.moveActiveWindowToAdjacentDisplay(offset: 1)
                            }
                            .macScopeGlassButton()
                            Button("Refresh", systemImage: "arrow.clockwise") { service.refresh() }
                                .macScopeGlassButton()
                        }

                        LazyVGrid(columns: layoutColumns, spacing: 10) {
                            layoutButton("Left half", icon: "rectangle.lefthalf.filled", placement: .leftHalf)
                            layoutButton("Right half", icon: "rectangle.righthalf.filled", placement: .rightHalf)
                            layoutButton("Left third", icon: "rectangle.split.3x1.fill", placement: .leftThird)
                            layoutButton("Center third", icon: "rectangle.split.3x1", placement: .centerThird)
                            layoutButton("Right third", icon: "rectangle.split.3x1.fill", placement: .rightThird)
                            layoutButton("Top half", icon: "rectangle.tophalf.filled", placement: .topHalf)
                            layoutButton("Bottom half", icon: "rectangle.bottomhalf.filled", placement: .bottomHalf)
                            layoutButton("Top left", icon: "rectangle.topthird.inset.filled", placement: .topLeft)
                            layoutButton("Top right", icon: "rectangle.topthird.inset.filled", placement: .topRight)
                            layoutButton("Bottom left", icon: "rectangle.bottomthird.inset.filled", placement: .bottomLeft)
                            layoutButton("Bottom right", icon: "rectangle.bottomthird.inset.filled", placement: .bottomRight)
                            layoutButton("Maximize", icon: "arrow.up.left.and.arrow.down.right", placement: .maximize)
                            layoutButton("Centered 80%", icon: "rectangle.center.inset.filled", placement: .centered)
                        }

                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Edge snapping", systemImage: "rectangle.on.rectangle.angled")
                                    .font(.headline)
                                Text("Drag a window to a display edge or corner for a live placement preview, then release to snap it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { service.edgeSnapEnabled },
                                set: { service.setEdgeSnapEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        if let error = service.edgeSnapError {
                            UtilityErrorBanner(message: error)
                        }

                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Move and resize anywhere", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.headline)
                                Text("Hold Control–Option and drag with the left button to move. Add Shift, or drag with the right button, to resize.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { service.modifierWindowDragEnabled },
                                set: { service.setModifierWindowDragEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        if let error = service.modifierWindowDragError {
                            UtilityErrorBanner(message: error)
                        }

                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Green button maximize", systemImage: "macwindow.badge.plus")
                                    .font(.headline)
                                Text("Make the green window button fill the usable display without creating another Space; click it again to restore.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { service.greenButtonOverrideEnabled },
                                set: { service.setGreenButtonOverrideEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        if let error = service.greenButtonOverrideError {
                            UtilityErrorBanner(message: error)
                        }
                    }
                }

                GlassGroup {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Super key", systemImage: "command.square.fill").font(.headline)
                            Text("Hold Right Option to send ⌃⌥⇧⌘ with the next key; tap it alone for Escape.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { superKey.isEnabled },
                            set: { superKey.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                    }
                    if let error = superKey.errorMessage {
                        UtilityErrorBanner(message: error).padding(.top, 8)
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Mouse scroll direction", systemImage: "computermouse")
                                    .font(.headline)
                                Text("Invert mouse-wheel axes independently without changing trackpad natural scrolling.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if scrollDirection.isRunning {
                                Label("Active", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium)).foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 24) {
                            Toggle("Invert vertical", isOn: Binding(
                                get: { scrollDirection.invertVertical },
                                set: { scrollDirection.invertVertical = $0 }
                            ))
                            Toggle("Invert horizontal", isOn: Binding(
                                get: { scrollDirection.invertHorizontal },
                                set: { scrollDirection.invertHorizontal = $0 }
                            ))
                        }
                        HStack {
                            Toggle("Smooth discrete mouse-wheel scrolling", isOn: Binding(
                                get: { smoothScrolling.isEnabled },
                                set: { smoothScrolling.setEnabled($0) }
                            ))
                            Slider(value: Binding(
                                get: { smoothScrolling.intensity },
                                set: { smoothScrolling.intensity = $0 }
                            ), in: 0.5...2, step: 0.1)
                            .frame(maxWidth: 150)
                            .disabled(!smoothScrolling.isEnabled)
                            Text("\(smoothScrolling.intensity.formatted(.number.precision(.fractionLength(1))))×")
                                .font(.caption.monospacedDigit()).frame(width: 36)
                        }
                        if let error = smoothScrolling.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Mouse button shortcuts").font(.callout.weight(.medium))
                                Text("Buttons 4 and 5 navigate Back/Forward by default. Record any extra button with a keyboard shortcut to override it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { mouseSideButtons.isEnabled },
                                set: { mouseSideButtons.setEnabled($0) }
                            ))
                            .labelsHidden()
                        }
                        HStack {
                            if mouseSideButtons.isRecording {
                                Button("Cancel Recording", role: .cancel) { mouseSideButtons.cancelRecording() }
                                    .macScopeGlassButton()
                            } else {
                                Button("Record New Shortcut", systemImage: "record.circle") {
                                    mouseSideButtons.startRecording()
                                }
                                .macScopeGlassButton()
                            }
                            Button("Exclude Apps…", systemImage: "app.badge") {
                                mouseSideButtons.chooseExcludedApplications()
                            }
                            .macScopeGlassButton()
                            Spacer()
                            Text("Three-finger middle-click is not exposed by macOS public global-event APIs.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let status = mouseSideButtons.recordingStatus {
                            UtilityNotice(icon: "computermouse.fill", title: "Mouse shortcut recorder", detail: status)
                        }
                        if !mouseSideButtons.shortcuts.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(mouseSideButtons.shortcuts) { shortcut in
                                    HStack {
                                        Image(systemName: "computermouse")
                                            .foregroundStyle(MacScopeTheme.accent)
                                        Text(shortcut.label).font(.caption.monospaced())
                                        Spacer()
                                        Button(role: .destructive) { mouseSideButtons.removeShortcut(shortcut) } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 6)
                                    if shortcut.id != mouseSideButtons.shortcuts.last?.id { Divider() }
                                }
                            }
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !mouseSideButtons.excludedApplications.isEmpty {
                            HStack(spacing: 8) {
                                Text("Excluded:").font(.caption).foregroundStyle(.secondary)
                                ForEach(mouseSideButtons.excludedApplications) { app in
                                    Button {
                                        mouseSideButtons.removeExcludedApplication(app)
                                    } label: {
                                        Label(app.name, systemImage: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .help("Remove \(app.name) from exclusions")
                                }
                            }
                        }
                        if let error = mouseSideButtons.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                        if let error = scrollDirection.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Focus follows mouse").font(.callout.weight(.medium))
                                Text("After the pointer rests over another app, activate its window without clicking.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { focusFollowsMouse.isEnabled },
                                set: { focusFollowsMouse.setEnabled($0) }
                            ))
                            .labelsHidden()
                        }
                        HStack {
                            Text("Hover delay")
                            Slider(value: Binding(
                                get: { focusFollowsMouse.delayMilliseconds },
                                set: { focusFollowsMouse.delayMilliseconds = $0 }
                            ), in: 100...1_000, step: 50)
                            Text("\(Int(focusFollowsMouse.delayMilliseconds)) ms")
                                .font(.caption.monospacedDigit()).frame(width: 62)
                        }
                        .disabled(!focusFollowsMouse.isEnabled)
                        if let error = focusFollowsMouse.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Keyboard debounce", systemImage: "keyboard.badge.ellipsis")
                                    .font(.headline)
                                Text("Suppress accidental duplicate key-down events while preserving normal key repeat.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { keyboardDebounce.isEnabled },
                                set: { keyboardDebounce.setEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        HStack {
                            Text("Duplicate interval")
                            Slider(value: Binding(
                                get: { keyboardDebounce.intervalMilliseconds },
                                set: { keyboardDebounce.intervalMilliseconds = $0 }
                            ), in: 20...250, step: 5)
                            Text("\(Int(keyboardDebounce.intervalMilliseconds)) ms")
                                .font(.caption.monospacedDigit()).frame(width: 58)
                        }
                        if let error = keyboardDebounce.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Running applications", systemImage: "square.stack.3d.up")
                                .font(.headline)
                            Spacer()
                            Text("\(service.applications.count) apps")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(service.applications) { app in
                            HStack(spacing: 12) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.callout.weight(.medium))
                                    Text(app.isActive ? "Active" : app.isHidden ? "Hidden" : "Running")
                                        .font(.caption2)
                                        .foregroundStyle(app.isActive ? MacScopeTheme.accent : .secondary)
                                }
                                Spacer()
                                Button("Show") { service.activate(app) }
                                    .macScopeGlassButton(prominent: app.isActive)
                                Button(app.isHidden ? "Unhide" : "Hide") { service.toggleHidden(app) }
                                    .macScopeGlassButton()
                                Toggle("Quit on close", isOn: Binding(
                                    get: { service.quitsOnClose(app) },
                                    set: { service.setQuitOnClose($0, for: app) }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            }
                            if app.id != service.applications.last?.id { Divider() }
                        }
                    }
                }

                if let message = service.statusMessage {
                    UtilityNotice(icon: "info.circle", title: "Workspace", detail: message)
                }
            }
            .padding(24)
        }
        .task {
            service.refresh()
            keyboardDebounce.restorePreference()
            scrollDirection.restorePreference()
            mouseSideButtons.restorePreference()
            focusFollowsMouse.restorePreference()
            superKey.restorePreference()
            smoothScrolling.restorePreference()
        }
    }

    private func layoutButton(
        _ title: String,
        icon: String,
        placement: UtilitySupport.WindowPlacement
    ) -> some View {
        Button {
            service.arrange(placement)
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CaptureUtilityView: View {
    let screenshots: ScreenshotService
    let ocr: ScreenOCRService
    let colorPicker: ColorPickerService
    let recorder: ScreenRecordingService
    let camera: CameraPreviewService
    let media: MediaUtilityService
    @Binding var selectedTab: UtilityTab
    @State private var showsRecordingEditor = false
    @State private var scrollingOverlapPixels = 0
    @State private var automaticScrollingSteps = 6
    @AppStorage("utility.copyScreenshots") private var copyScreenshots = true
    @AppStorage("utility.screenshotDelay") private var screenshotDelay = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Capture tools",
                    subtitle: "Screenshots, recording, offline text recognition, color sampling and camera preview"
                )
                UtilityTabPicker(selection: $selectedTab)

                GlassGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Screenshots", systemImage: "camera.viewfinder")
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                            ForEach(ScreenshotMode.allCases) { mode in
                                Button {
                                    screenshots.capture(
                                        mode,
                                        copyToClipboard: copyScreenshots,
                                        delay: screenshotDelay
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Image(systemName: mode.icon).font(.title2)
                                        Text(mode.rawValue).font(.headline)
                                        Text(mode == .fullScreen ? "Capture immediately" : "Choose interactively")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                }
                                .buttonStyle(.plain)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .disabled(screenshots.isCapturing)
                            }
                        }

                        Divider()
                        HStack {
                            Toggle("Copy new captures to clipboard", isOn: $copyScreenshots)
                            Picker("Timer", selection: $screenshotDelay) {
                                Text("No timer").tag(0)
                                Text("3 seconds").tag(3)
                                Text("5 seconds").tag(5)
                                Text("10 seconds").tag(10)
                            }
                            .frame(width: 130)
                            if screenshots.countdownSeconds > 0 {
                                Text("Capturing in \(screenshots.countdownSeconds)…")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(MacScopeTheme.accent)
                            }
                            Spacer()
                            Button("Choose Folder…", systemImage: "folder") { screenshots.chooseCaptureFolder() }
                                .macScopeGlassButton()
                            Button("Open Folder", systemImage: "arrow.up.forward.app") { screenshots.openCaptureFolder() }
                                .macScopeGlassButton()
                        }
                        HStack {
                            Toggle("Dated subfolders", isOn: Binding(
                                get: { screenshots.organizesByDate },
                                set: { screenshots.organizesByDate = $0 }
                            ))
                            TextField("Filename prefix", text: Binding(
                                get: { screenshots.filenamePrefix },
                                set: { screenshots.filenamePrefix = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            Text("Date and time are appended automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            Toggle("Export at 1x", isOn: Binding(
                                get: { screenshots.exportsAt1x },
                                set: { screenshots.exportsAt1x = $0 }
                            ))
                            Text("Downsample Retina captures to logical-point resolution.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("After capture").font(.caption).foregroundStyle(.secondary)
                            Picker("After capture", selection: Binding(
                                get: { screenshots.postCaptureAction },
                                set: { screenshots.postCaptureAction = $0 }
                            )) {
                                ForEach(ScreenshotPostCaptureAction.allCases) { action in
                                    Text(action.rawValue).tag(action)
                                }
                            }
                            .labelsHidden().frame(width: 160)
                        }
                        Divider()
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Scrolling capture stitcher", systemImage: "rectangle.stack")
                                    .font(.callout.weight(.medium))
                                Text("Capture a long page in top-to-bottom segments, then choose them in that order to create one PNG.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("Overlap", value: $scrollingOverlapPixels, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 72)
                            Text("px overlap").font(.caption).foregroundStyle(.secondary)
                            Button(screenshots.isStitching ? "Stitching…" : "Choose Segments…", systemImage: "rectangle.stack.fill") {
                                screenshots.chooseScrollingSegments(
                                    overlapPixels: scrollingOverlapPixels,
                                    copyToClipboard: copyScreenshots
                                )
                            }
                            .disabled(screenshots.isStitching)
                            .macScopeGlassButton()
                        }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Automatic scrolling window", systemImage: "arrow.down.to.line.compact")
                                    .font(.callout.weight(.medium))
                                Text("After a 3-second handoff, captures the window under the pointer and scrolls between segments.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Segments", selection: $automaticScrollingSteps) {
                                Text("4 shots").tag(4)
                                Text("6 shots").tag(6)
                                Text("8 shots").tag(8)
                                Text("12 shots").tag(12)
                            }
                            .frame(width: 105)
                            Button(screenshots.isStitching ? "Capturing…" : "Start Auto Capture", systemImage: "play.fill") {
                                screenshots.captureAutomaticScrolling(
                                    steps: automaticScrollingSteps,
                                    overlapPixels: scrollingOverlapPixels,
                                    copyToClipboard: copyScreenshots
                                )
                            }
                            .disabled(screenshots.isStitching)
                            .macScopeGlassButton(prominent: true)
                        }
                    }
                }

                captureAssistantGrid

                recordingPanel

                cameraPanel

                if !screenshots.hasScreenRecordingPermission {
                    HStack {
                        UtilityNotice(
                            icon: "rectangle.inset.filled.badge.record",
                            title: "Screen Recording permission",
                            detail: "macOS requires this before MacScope can capture other apps."
                        )
                        Button("Request Permission") { screenshots.requestPermission() }
                            .macScopeGlassButton(prominent: true)
                    }
                }

                if !screenshots.captures.isEmpty {
                    GlassGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent captures").font(.headline)
                                Spacer()
                                Text(screenshots.captureFolder.path(percentEncoded: false))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                                ForEach(screenshots.captures.prefix(12)) { record in
                                    ScreenshotCard(record: record, service: screenshots)
                                }
                            }
                        }
                    }
                }

                if let error = screenshots.errorMessage { UtilityErrorBanner(message: error) }
                if let message = screenshots.statusMessage {
                    UtilityNotice(icon: "rectangle.stack", title: "Scrolling capture", detail: message)
                }
                if let error = ocr.errorMessage { UtilityErrorBanner(message: error) }
                if let error = recorder.errorMessage { UtilityErrorBanner(message: error) }
                if let message = recorder.statusMessage {
                    UtilityNotice(icon: "film", title: "Recording", detail: message)
                }
                if let error = camera.errorMessage { UtilityErrorBanner(message: error) }
            }
            .padding(24)
        }
        .onDisappear { camera.stop() }
    }

    private var captureAssistantGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            GlassGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Copy text from screen", systemImage: "text.viewfinder")
                        .font(.headline)
                    Text("Select an area and recognize its text locally with Vision. Nothing is uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(
                        ocr.isRecognizing ? "Recognizing…" : "Select Text Area",
                        systemImage: "viewfinder"
                    ) { ocr.recognizeSelection() }
                        .disabled(ocr.isRecognizing)
                        .macScopeGlassButton(prominent: true)

                    if !ocr.recognizedText.isEmpty {
                        TextEditor(text: .constant(ocr.recognizedText))
                            .font(.caption.monospaced())
                            .frame(minHeight: 92)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        Button("Copy Text", systemImage: "doc.on.doc") { ocr.copyText() }
                            .macScopeGlassButton()
                    }
                    ForEach(ocr.recognizedCodes, id: \.self) { code in
                        VStack(alignment: .leading, spacing: 6) {
                            Label("QR code", systemImage: "qrcode")
                                .font(.caption.weight(.semibold))
                            Text(code).font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Copy") { ocr.copyCode(code) }.buttonStyle(.link)
                                if let url = URL(string: code), url.scheme == "http" || url.scheme == "https" {
                                    Button("Open Link") { ocr.openCode(code) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            }

            GlassGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Color picker", systemImage: "eyedropper")
                        .font(.headline)
                    Text("Use the system loupe anywhere on screen. This fallback needs no screen-recording permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Pick a Color", systemImage: "eyedropper.halffull") { colorPicker.pick() }
                        .macScopeGlassButton(prominent: true)

                    if let color = colorPicker.color {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: color))
                                .frame(width: 54, height: 54)
                                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
                            VStack(alignment: .leading, spacing: 5) {
                                if let hex = colorPicker.hex {
                                    Button(hex) { colorPicker.copy(hex) }.buttonStyle(.link)
                                }
                                if let rgb = colorPicker.rgb {
                                    Button(rgb) { colorPicker.copy(rgb) }.buttonStyle(.link)
                                }
                                if let hsl = colorPicker.hsl {
                                    Button(hsl) { colorPicker.copy(hsl) }.buttonStyle(.link)
                                }
                            }
                        }
                        if let swiftUI = colorPicker.swiftUI {
                            Button(swiftUI) { colorPicker.copy(swiftUI) }
                                .font(.caption.monospaced())
                                .buttonStyle(.link)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            }
        }
    }

    private var recordingPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundStyle(recorder.isRecording ? .red : MacScopeTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen recording").font(.headline)
                        Text(recorder.isRecording
                             ? "Recording \(recorder.selectedSourceName) · \(recordingDuration(recorder.elapsed))"
                             : recorder.isPreparing ? "Preparing capture…" : "Record a display or exact window to a local MOV file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if recorder.isRecording {
                        Button(recorder.isPaused ? "Resume" : "Pause", systemImage: recorder.isPaused ? "play.fill" : "pause.fill") {
                            recorder.togglePause()
                        }
                        .macScopeGlassButton()
                        Button("Stop Recording", systemImage: "stop.fill", role: .destructive) { recorder.stop() }
                            .macScopeGlassButton()
                    } else {
                        Button("Start Recording", systemImage: "record.circle") { recorder.start() }
                            .disabled(recorder.isPreparing)
                            .macScopeGlassButton(prominent: true)
                    }
                }
                Divider()
                HStack {
                    if !recorder.sources.isEmpty {
                        Picker("Source", selection: Binding(
                            get: { recorder.selectedSourceID ?? recorder.sources.first?.id },
                            set: { recorder.selectedSourceID = $0 }
                        )) {
                            ForEach(recorder.sources) { source in Text(source.name).tag(Optional(source.id)) }
                        }
                        .frame(maxWidth: 280)
                        .disabled(recorder.isRecording || recorder.isPreparing)
                    }
                    Button(recorder.isLoadingSources ? "Loading…" : "Choose Source", systemImage: "rectangle.on.rectangle") {
                        recorder.loadSources()
                    }
                    .disabled(recorder.isLoadingSources || recorder.isRecording || recorder.isPreparing)
                    .macScopeGlassButton()
                    Toggle("Include system audio", isOn: Binding(
                        get: { recorder.includesSystemAudio },
                        set: { recorder.includesSystemAudio = $0 }
                    ))
                    .disabled(recorder.isRecording || recorder.isPreparing)
                    if #available(macOS 15.0, *) {
                        Toggle("Include microphone", isOn: Binding(
                            get: { recorder.includesMicrophone },
                            set: { recorder.includesMicrophone = $0 }
                        ))
                        .disabled(recorder.isRecording || recorder.isPreparing)
                    }
                    Spacer()
                    if recorder.lastRecordingURL != nil {
                        Button("Edit Last", systemImage: "slider.horizontal.3") {
                            if let url = recorder.lastRecordingURL {
                                media.loadVideo(url)
                                showsRecordingEditor = true
                            }
                        }
                        .macScopeGlassButton()
                        Button("Reveal Last", systemImage: "magnifyingglass") { recorder.revealLastRecording() }
                            .macScopeGlassButton()
                    }
                    Button("Open Recordings", systemImage: "folder") { recorder.openRecordingsFolder() }
                        .macScopeGlassButton()
                }
            }
        }
        .sheet(isPresented: $showsRecordingEditor) {
            RecordingEditorSheet(media: media, recorder: recorder)
        }
    }

    private var cameraPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Camera preview", systemImage: "web.camera")
                            .font(.headline)
                        Text("A local mirror for checking framing before a call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if camera.devices.count > 1 {
                        Picker("Camera", selection: Binding(
                            get: { camera.selectedDeviceID ?? "" },
                            set: { camera.selectDevice($0) }
                        )) {
                            ForEach(camera.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    Button(
                        camera.isRunning ? "Close Preview" : "Open Floating Preview",
                        systemImage: camera.isRunning ? "xmark" : "video"
                    ) {
                        camera.isRunning ? camera.stop() : camera.start()
                    }
                    .macScopeGlassButton(prominent: !camera.isRunning)
                }

                if camera.isRunning {
                    UtilityNotice(
                        icon: "macwindow.on.rectangle",
                        title: "Floating camera preview is open",
                        detail: "It stays above other windows and closes automatically when you click away."
                    )
                }
            }
        }
    }
}

private struct RecordingEditorSheet: View {
    let media: MediaUtilityService
    let recorder: ScreenRecordingService
    @Environment(\.dismiss) private var dismiss
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var cropLeft = 0.0
    @State private var cropRight = 0.0
    @State private var cropTop = 0.0
    @State private var cropBottom = 0.0
    @State private var overlayText = ""
    @State private var canvasPadding = 4.0
    @State private var canvasBackground = RecordingCanvasBackground.black
    @State private var audioVolume = 1.0
    @State private var gifFramesPerSecond = 8
    @State private var presetName = ""
    @State private var autoZoomAtClicks = true
    @State private var autoZoomFactor = 1.6
    @State private var autoZoomHoldSeconds = 1.5
    @State private var confirmsCopyAndTrash = false

    var body: some View {
        ZStack {
            MacScopeTheme.contentBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.title2).foregroundStyle(MacScopeTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording editor").font(.title2.weight(.semibold))
                            Text(media.videoSourceURL?.lastPathComponent ?? "No recording selected")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }

                    if let source = media.videoSourceURL {
                        GlassGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                                        .resizable().scaledToFit().frame(width: 42, height: 42)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.lastPathComponent).font(.headline).lineLimit(1)
                                        Text(media.videoDuration > 0
                                             ? "\(media.videoDuration.formatted(.number.precision(.fractionLength(1)))) seconds · edits create a new MP4"
                                             : "Reading duration…")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Copy Original", systemImage: "doc.on.doc") { recorder.copyLastRecording() }
                                        .macScopeGlassButton()
                                    Button("Copy & Trash…", systemImage: "trash", role: .destructive) {
                                        confirmsCopyAndTrash = true
                                    }
                                    .macScopeGlassButton()
                                }

                                Divider()
                                HStack(spacing: 8) {
                                    Label("Timeline", systemImage: "timeline.selection")
                                        .font(.callout.weight(.medium))
                                    TextField("Start", value: $trimStart, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 84)
                                    Text("to").font(.caption).foregroundStyle(.secondary)
                                    TextField("End", value: $trimEnd, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 84)
                                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Full") { trimStart = 0; trimEnd = media.videoDuration }
                                        .buttonStyle(.link)
                                    Button("Trim") { media.trimVideo(start: trimStart, end: trimEnd) }
                                        .disabled(media.isEditingVideo || trimEnd <= trimStart)
                                        .macScopeGlassButton()
                                    Button("Remove Range") { media.cutVideo(start: trimStart, end: trimEnd) }
                                        .disabled(
                                            media.isEditingVideo || trimEnd <= trimStart
                                                || (trimStart <= 0 && trimEnd >= media.videoDuration)
                                        )
                                        .macScopeGlassButton()
                                }

                                Divider()
                                HStack(spacing: 8) {
                                    Label("Crop", systemImage: "crop").font(.callout.weight(.medium))
                                    recordingCropField("L", value: $cropLeft)
                                    recordingCropField("R", value: $cropRight)
                                    recordingCropField("T", value: $cropTop)
                                    recordingCropField("B", value: $cropBottom)
                                    Spacer()
                                    Button("Crop") {
                                        media.cropVideo(
                                            left: cropLeft, right: cropRight,
                                            top: cropTop, bottom: cropBottom
                                        )
                                    }
                                    .disabled(
                                        media.isEditingVideo
                                            || [cropLeft, cropRight, cropTop, cropBottom].allSatisfy { $0 <= 0 }
                                    )
                                    .macScopeGlassButton()
                                    Button(media.isCompressingVideo ? "Compressing…" : "Compress") {
                                        media.compressVideo()
                                    }
                                    .disabled(media.isCompressingVideo || media.isEditingVideo)
                                    .macScopeGlassButton(prominent: true)
                                }

                                Divider()
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Label("Canvas & text", systemImage: "text.below.photo")
                                            .font(.callout.weight(.medium))
                                        TextField("Optional text overlay", text: $overlayText)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 280)
                                        Picker("Background", selection: $canvasBackground) {
                                            ForEach(RecordingCanvasBackground.allCases) { background in
                                                Text(background.rawValue).tag(background)
                                            }
                                        }
                                        .frame(width: 125)
                                        Text("Padding").font(.caption).foregroundStyle(.secondary)
                                        Slider(value: $canvasPadding, in: 0...25, step: 1).frame(width: 90)
                                        Text("\(Int(canvasPadding))%")
                                            .font(.caption.monospacedDigit()).frame(width: 34)
                                    }
                                    HStack(spacing: 8) {
                                        Label("Audio mix", systemImage: audioVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                                            .font(.callout.weight(.medium))
                                        Slider(value: $audioVolume, in: 0...2, step: 0.05)
                                            .frame(width: 180)
                                        Text("\(Int((audioVolume * 100).rounded()))%")
                                            .font(.caption.monospacedDigit()).frame(width: 44)
                                        Button("Mute") { audioVolume = 0 }.buttonStyle(.link)
                                        Button("Reset") { audioVolume = 1 }.buttonStyle(.link)
                                        Spacer()
                                        Button("Render Edited MP4", systemImage: "wand.and.stars") {
                                            media.decorateVideo(
                                                text: overlayText,
                                                paddingPercent: canvasPadding,
                                                background: canvasBackground,
                                                audioVolume: audioVolume,
                                                autoZoomEvents: autoZoomAtClicks ? recorder.pointerEvents : [],
                                                autoZoomFactor: autoZoomAtClicks ? autoZoomFactor : 1,
                                                autoZoomHoldSeconds: autoZoomHoldSeconds
                                            )
                                        }
                                        .disabled(media.isEditingVideo || media.isCompressingVideo)
                                        .macScopeGlassButton(prominent: true)
                                    }
                                    HStack(spacing: 8) {
                                        Label("Click zoom", systemImage: "cursorarrow.click.badge.clock")
                                            .font(.callout.weight(.medium))
                                        Toggle("Auto zoom at recorded clicks", isOn: $autoZoomAtClicks)
                                            .toggleStyle(.checkbox)
                                        Text("\(recorder.pointerEvents.count) click\(recorder.pointerEvents.count == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text("Zoom").font(.caption).foregroundStyle(.secondary)
                                        Slider(value: $autoZoomFactor, in: 1.2...2.5, step: 0.1)
                                            .frame(width: 90).disabled(!autoZoomAtClicks)
                                        Text("\(autoZoomFactor.formatted(.number.precision(.fractionLength(1))))×")
                                            .font(.caption.monospacedDigit()).frame(width: 34)
                                        Text("Hold").font(.caption).foregroundStyle(.secondary)
                                        Slider(value: $autoZoomHoldSeconds, in: 0.4...5, step: 0.1)
                                            .frame(width: 90).disabled(!autoZoomAtClicks)
                                        Text("\(autoZoomHoldSeconds.formatted(.number.precision(.fractionLength(1))))s")
                                            .font(.caption.monospacedDigit()).frame(width: 38)
                                    }
                                    HStack(spacing: 8) {
                                        Label("GIF export", systemImage: "photo.stack")
                                            .font(.callout.weight(.medium))
                                        Text("First 12 seconds · up to 180 frames")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Picker("Frames per second", selection: $gifFramesPerSecond) {
                                            Text("4 fps").tag(4)
                                            Text("8 fps").tag(8)
                                            Text("12 fps").tag(12)
                                            Text("15 fps").tag(15)
                                        }
                                        .frame(width: 100)
                                        Spacer()
                                        Button("Export GIF", systemImage: "square.and.arrow.down") {
                                            media.exportVideoGIF(framesPerSecond: gifFramesPerSecond)
                                        }
                                        .disabled(media.isEditingVideo || media.isCompressingVideo)
                                        .macScopeGlassButton()
                                    }
                                    HStack(spacing: 8) {
                                        Label("Presets", systemImage: "square.stack.3d.up")
                                            .font(.callout.weight(.medium))
                                        if media.recordingPresets.isEmpty {
                                            Text("No saved editor presets")
                                                .font(.caption).foregroundStyle(.secondary)
                                        } else {
                                            Menu("Apply Preset") {
                                                ForEach(media.recordingPresets) { preset in
                                                    Button(preset.name) { applyRecordingPreset(preset) }
                                                }
                                            }
                                            Menu("Delete Preset") {
                                                ForEach(media.recordingPresets) { preset in
                                                    Button(preset.name, role: .destructive) {
                                                        media.deleteRecordingPreset(preset)
                                                    }
                                                }
                                            }
                                        }
                                        TextField("Preset name", text: $presetName)
                                            .textFieldStyle(.roundedBorder).frame(width: 170)
                                        Button("Save Current") {
                                            media.saveRecordingPreset(
                                                name: presetName,
                                                overlayText: overlayText,
                                                paddingPercent: canvasPadding,
                                                background: canvasBackground,
                                                audioVolume: audioVolume,
                                                gifFramesPerSecond: gifFramesPerSecond
                                            )
                                            presetName = ""
                                        }
                                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        .macScopeGlassButton()
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if let output = media.videoOutputURL {
                            GlassGroup {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Latest edited output").font(.callout.weight(.medium))
                                        Text(output.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Copy Output", systemImage: "doc.on.doc") { media.copyVideoOutput() }
                                        .macScopeGlassButton()
                                    Button("Reveal", systemImage: "magnifyingglass") { media.revealVideoOutput() }
                                        .macScopeGlassButton()
                                }
                            }
                        }
                        if let message = media.statusMessage {
                            UtilityNotice(icon: "info.circle", title: "Editor", detail: message)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { if trimEnd <= 0 { trimEnd = media.videoDuration } }
        .onChange(of: media.videoDuration) { _, duration in
            if trimEnd <= 0 || trimEnd > duration { trimEnd = duration }
        }
        .confirmationDialog(
            "Copy the original recording, then move it to Trash?",
            isPresented: $confirmsCopyAndTrash,
            titleVisibility: .visible
        ) {
            Button("Copy & Move to Trash", role: .destructive) {
                recorder.copyAndTrashLastRecording()
                confirmsCopyAndTrash = false
                dismiss()
            }
            Button("Cancel", role: .cancel) { confirmsCopyAndTrash = false }
        } message: {
            Text("The file remains recoverable in Trash. Any edited copies are left in place.")
        }
    }

    private func recordingCropField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 52)
            Text("%").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func applyRecordingPreset(_ preset: RecordingEditPreset) {
        overlayText = preset.overlayText
        canvasPadding = preset.paddingPercent
        canvasBackground = preset.background
        audioVolume = preset.audioVolume
        gifFramesPerSecond = preset.gifFramesPerSecond
    }
}

private func recordingDuration(_ duration: TimeInterval) -> String {
    let seconds = max(Int(duration), 0)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private struct ScreenshotCard: View {
    let record: ScreenshotRecord
    let service: ScreenshotService
    @State private var showsEditor = false
    @State private var detectedCodes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = NSImage(contentsOf: record.url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)
            .clipped()
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(record.url.lastPathComponent)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open") { service.open(record.url) }.buttonStyle(.link)
                Button("Edit") { showsEditor = true }.buttonStyle(.link)
                Button("Preview") { service.annotate(record.url) }.buttonStyle(.link)
                Button("Copy") { service.copy(record.url) }.buttonStyle(.link)
                Button("Pin") { service.pin(record.url) }.buttonStyle(.link)
                Button("Reveal") { service.reveal(record.url) }.buttonStyle(.link)
                Menu("Share") {
                    ShareLink(item: record.url) { Label("System Share…", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button("Local Link · 1 Hour") { service.shareTemporarily(record.url, hours: 1) }
                    Button("Local Link · 6 Hours") { service.shareTemporarily(record.url, hours: 6) }
                    Button("Local Link · 24 Hours") { service.shareTemporarily(record.url, hours: 24) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button(role: .destructive) { service.delete(record) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            ForEach(detectedCodes.prefix(2), id: \.self) { code in
                HStack(spacing: 7) {
                    Image(systemName: "qrcode").foregroundStyle(MacScopeTheme.accent)
                    Text(code).font(.caption2.monospaced()).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.link)
                    if let url = URL(string: code), url.scheme == "http" || url.scheme == "https" {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
            }
            ForEach(service.temporaryShares.filter { $0.captureURL == record.url }) { share in
                HStack(spacing: 7) {
                    Image(systemName: "link.badge.plus").foregroundStyle(MacScopeTheme.accent)
                    Text("Local link · expires \(share.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { service.copyTemporaryShare(share) }.buttonStyle(.link)
                    Button("Revoke", role: .destructive) { service.stopTemporaryShare(share.id) }.buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .sheet(isPresented: $showsEditor) {
            ScreenshotEditorView(sourceURL: record.url) { _ in service.refresh() }
        }
        .task(id: record.url) {
            detectedCodes = (try? await ScreenImageAnalyzer.detectQRCodes(at: record.url)) ?? []
        }
    }
}

private struct ClipboardUtilityView: View {
    let service: ClipboardHistoryService
    let snippetShelf: SnippetShelfService
    let plainTextPaste: PlainTextPasteService
    let finderShortcuts: FinderShortcutService
    @Binding var selectedTab: UtilityTab
    @State private var snippetTitle = ""
    @State private var snippetText = ""
    @State private var snippetTrigger = ""
    @State private var snippetFolder = ""
    @State private var snippetFolderFilter = "__all__"
    @State private var clipboardSearch = ""

    private var filteredEntries: [ClipboardHistoryEntry] {
        guard !clipboardSearch.isEmpty else { return service.entries }
        return service.entries.filter {
            $0.summary.localizedCaseInsensitiveContains(clipboardSearch)
        }
    }

    private var snippetFolders: [String] {
        Array(Set(snippetShelf.snippets.compactMap(\.folder))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var filteredSnippets: [SavedSnippet] {
        guard snippetFolderFilter != "__all__" else { return snippetShelf.snippets }
        return snippetShelf.snippets.filter { $0.folder == snippetFolderFilter }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Clipboard tools",
                    subtitle: "Opt-in session history, plain-text copying and one-click tracking cleanup"
                )
                UtilityTabPicker(selection: $selectedTab)

                GlassGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            "Watch text copied during this MacScope session",
                            isOn: Binding(get: { service.isEnabled }, set: { service.setEnabled($0) })
                        )
                        Text("History stays in memory, is never uploaded, and is cleared when MacScope quits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Global plain-text paste").font(.callout.weight(.medium))
                                Text("⌘⌥⇧V pastes unformatted text, then restores the original clipboard contents.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { plainTextPaste.isEnabled },
                                set: { plainTextPaste.setEnabled($0) }
                            ))
                            .labelsHidden()
                        }
                        if let error = plainTextPaste.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Finder shortcuts").font(.callout.weight(.medium))
                                Text("Use ⌘X then ⌘V to move files, F2 to rename, or ⌘V to save a copied bitmap as PNG.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { finderShortcuts.isEnabled },
                                set: { finderShortcuts.setEnabled($0) }
                            ))
                            .labelsHidden()
                        }
                        if let error = finderShortcuts.errorMessage {
                            UtilityErrorBanner(message: error)
                        }
                        Divider()
                        HStack(spacing: 18) {
                            Toggle("Clear when Mac sleeps", isOn: Binding(
                                get: { service.clearOnSystemSleep },
                                set: { service.setClearOnSystemSleep($0) }
                            ))
                            Toggle("Display sleeps", isOn: Binding(
                                get: { service.clearOnDisplaySleep },
                                set: { service.setClearOnDisplaySleep($0) }
                            ))
                            Toggle("Screen locks", isOn: Binding(
                                get: { service.clearOnScreenLock },
                                set: { service.setClearOnScreenLock($0) }
                            ))
                        }
                        .font(.caption)
                        Divider()
                        HStack {
                            Button("Clean Tracking URL", systemImage: "link.badge.plus") { service.cleanCurrentURL() }
                                .macScopeGlassButton(prominent: true)
                            Toggle("Clean copied URLs automatically", isOn: Binding(
                                get: { service.automaticallyCleansURLs },
                                set: { service.setAutomaticallyCleansURLs($0) }
                            ))
                            TextField("Extra parameters: campaign, source…", text: Binding(
                                get: { service.customTrackingParameters },
                                set: { service.customTrackingParameters = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            Menu("Auto-clear", systemImage: "timer") {
                                Button("After 1 minute") { service.scheduleClipboardClear(after: 60) }
                                Button("After 5 minutes") { service.scheduleClipboardClear(after: 5 * 60) }
                                Button("After 15 minutes") { service.scheduleClipboardClear(after: 15 * 60) }
                                Divider()
                                Button("Cancel automatic clear") { service.scheduleClipboardClear(after: nil) }
                            }
                            .macScopeGlassButton()
                            Spacer()
                            Button("Clear Session History", systemImage: "trash", role: .destructive) { service.clear() }
                                .disabled(service.entries.isEmpty)
                        }
                    }
                }

                snippetPanel

                shelfPanel

                if !service.pinnedEntries.isEmpty {
                    GlassGroup {
                        VStack(alignment: .leading, spacing: 0) {
                            Label("Pinned favorites", systemImage: "pin.fill")
                                .font(.headline).padding(.bottom, 10)
                            ForEach(service.pinnedEntries) { entry in
                                HStack(spacing: 12) {
                                    Image(systemName: entry.imageData != nil ? "photo" : entry.fileURLs.isEmpty ? "text.alignleft" : "doc")
                                        .foregroundStyle(MacScopeTheme.accent).frame(width: 30)
                                    Text(entry.summary).lineLimit(2)
                                    Spacer()
                                    Button("Copy") { service.copy(entry) }.macScopeGlassButton(prominent: true)
                                    Button(role: .destructive) { service.unpin(entry) } label: {
                                        Image(systemName: "pin.slash")
                                    }.buttonStyle(.plain)
                                }
                                .padding(.vertical, 8)
                                if entry.id != service.pinnedEntries.last?.id { Divider() }
                            }
                        }
                    }
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Session history").font(.headline)
                            Spacer()
                            TextField("Search history", text: $clipboardSearch)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 230)
                        }
                        .padding(.bottom, 10)
                        if service.entries.isEmpty {
                            UtilityNotice(
                                icon: "doc.on.clipboard",
                                title: service.isEnabled ? "Nothing copied yet" : "Clipboard watching is off",
                                detail: service.isEnabled ? "Copied text will appear here." : "Enable it above when you want a private session history."
                            )
                        } else {
                            ForEach(filteredEntries) { entry in
                                HStack(spacing: 12) {
                                    if let data = entry.imageData, let image = NSImage(data: data) {
                                        Image(nsImage: image)
                                            .resizable().scaledToFill()
                                            .frame(width: 48, height: 38).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else if let file = entry.fileURLs.first {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                            .resizable().scaledToFit().frame(width: 34, height: 34)
                                    } else {
                                        Image(systemName: "text.alignleft")
                                            .foregroundStyle(.secondary).frame(width: 34)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.summary).lineLimit(2).font(.callout)
                                        Text(entry.capturedAt.formatted(date: .omitted, time: .standard))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(
                                        entry.fileURLs.isEmpty && entry.imageData == nil ? "Copy Plain" : "Restore",
                                        systemImage: entry.fileURLs.isEmpty && entry.imageData == nil ? "doc.plaintext" : "arrow.uturn.backward"
                                    ) { service.copy(entry) }
                                        .macScopeGlassButton()
                                    Button("Pin", systemImage: "pin") { service.pin(entry) }
                                        .macScopeGlassButton()
                                }
                                .padding(.vertical, 9)
                                if entry.id != service.entries.last?.id { Divider() }
                            }
                        }
                    }
                }

                if let message = service.statusMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let message = snippetShelf.statusMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .task {
            plainTextPaste.restorePreference()
            finderShortcuts.restorePreference()
        }
    }

    private var snippetPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Reusable snippets", systemImage: "text.badge.plus")
                        .font(.headline)
                    Spacer()
                    if !snippetFolders.isEmpty {
                        Picker("Folder", selection: $snippetFolderFilter) {
                            Text("All folders").tag("__all__")
                            ForEach(snippetFolders, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                    Toggle("Expand while typing", isOn: Binding(
                        get: { snippetShelf.isExpansionEnabled },
                        set: { snippetShelf.setExpansionEnabled($0) }
                    ))
                    Button("Save Clipboard", systemImage: "clipboard") { snippetShelf.saveClipboardAsSnippet() }
                        .macScopeGlassButton()
                }
                Text("Stored locally. Templates support {clipboard}, {date}, {time}, and custom formats such as {date:yyyy-MM-dd}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    TextField("Trigger, e.g. ;sig", text: $snippetTrigger)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 145)
                    TextField("Optional title", text: $snippetTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    TextField("Folder", text: $snippetFolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                    TextField("Snippet text", text: $snippetText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    Button("Save") {
                        snippetShelf.saveSnippet(
                            title: snippetTitle,
                            text: snippetText,
                            trigger: snippetTrigger,
                            folder: snippetFolder
                        )
                        if snippetShelf.statusMessage == "Snippet saved locally." {
                            snippetTitle = ""
                            snippetText = ""
                            snippetTrigger = ""
                            snippetFolder = ""
                        }
                    }
                    .macScopeGlassButton(prominent: true)
                }
                if !snippetShelf.snippets.isEmpty {
                    Divider()
                    ForEach(filteredSnippets) { snippet in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(snippet.title).font(.callout.weight(.medium))
                                    if let folder = snippet.folder {
                                        Text(folder)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(MacScopeTheme.cyan)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(MacScopeTheme.cyan.opacity(0.1), in: Capsule())
                                    }
                                }
                                Text(snippet.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let trigger = snippet.trigger {
                                    Text("Trigger: \(trigger)").font(.caption2.monospaced()).foregroundStyle(MacScopeTheme.accent)
                                }
                            }
                            Spacer()
                            Button("Copy") { snippetShelf.copy(snippet) }.macScopeGlassButton()
                            Button(role: .destructive) { snippetShelf.delete(snippet) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let error = snippetShelf.expansionError {
                    UtilityErrorBanner(message: error)
                }
            }
        }
    }

    private var shelfPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Session shelf", systemImage: "tray.full")
                            .font(.headline)
                        Text("Keep temporary files, folders, text and links together for this session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Clipboard Text", systemImage: "doc.on.clipboard") {
                        snippetShelf.addClipboardTextToShelf()
                    }
                    .macScopeGlassButton()
                    Button("Add Files…", systemImage: "plus") { snippetShelf.addShelfItems() }
                        .macScopeGlassButton(prominent: true)
                    if !snippetShelf.shelfItems.isEmpty {
                        Button("Move Items…", systemImage: "arrow.right.circle.fill") {
                            snippetShelf.moveShelfItemsToCurrentFinderFolder()
                        }
                        .macScopeGlassButton(prominent: true)
                    }
                }
                if snippetShelf.shelfItems.isEmpty && snippetShelf.shelfTextItems.isEmpty {
                    UtilityNotice(
                        icon: "tray",
                        title: "Shelf is empty",
                        detail: "Add clipboard text or links, files or folders. Disk images open with the system installer."
                    )
                } else {
                    ForEach(snippetShelf.shelfTextItems) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.link == nil ? "text.quote" : "link")
                                .frame(width: 28, height: 28)
                                .foregroundStyle(MacScopeTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.summary).lineLimit(2)
                                Text(item.link == nil ? "Text · this session" : "Link · this session")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.link != nil {
                                Button("Open") { snippetShelf.open(item) }.buttonStyle(.link)
                            }
                            Button("Copy") { snippetShelf.copy(item) }.buttonStyle(.link)
                            Button(role: .destructive) { snippetShelf.remove(item) } label: {
                                Image(systemName: "xmark")
                            }.buttonStyle(.plain)
                        }
                        Divider()
                    }
                    ForEach(snippetShelf.shelfItems) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                .resizable().scaledToFit().frame(width: 28, height: 28)
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Open") { snippetShelf.open(item) }.buttonStyle(.link)
                            if item.url.pathExtension.lowercased() == "dmg" {
                                Button(snippetShelf.isInstallingDiskImage ? "Installing…" : "Install App…") {
                                    snippetShelf.installDiskImage(item)
                                }
                                .disabled(snippetShelf.isInstallingDiskImage)
                                .buttonStyle(.link)
                            }
                            Button("Reveal") { snippetShelf.reveal(item) }.buttonStyle(.link)
                            Button("Copy Path") { snippetShelf.copyPath(item) }.buttonStyle(.link)
                            Button(role: .destructive) { snippetShelf.remove(item) } label: {
                                Image(systemName: "xmark")
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct ScratchpadUtilityView: View {
    let service: ScratchpadService
    @Binding var selectedTab: UtilityTab
    @State private var selectedID: UUID?
    @State private var draftName = ""
    @State private var showsPreview = false

    private var selectedPad: ScratchpadTab? {
        service.tabs.first(where: { $0.id == selectedID }) ?? service.tabs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: "Scratchpads",
                subtitle: "Persistent named pads for temporary notes, fragments and Markdown"
            )
            UtilityTabPicker(selection: $selectedTab)

            GlassGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Picker("Pad", selection: Binding(
                            get: { selectedPad?.id },
                            set: { id in
                                selectedID = id
                                draftName = service.tabs.first(where: { $0.id == id })?.name ?? ""
                            }
                        )) {
                            ForEach(service.tabs) { tab in Text(tab.name).tag(Optional(tab.id)) }
                        }
                        .frame(maxWidth: 220)
                        TextField("Pad name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit {
                                if let id = selectedPad?.id { service.rename(id, to: draftName) }
                            }
                        Button("Rename") {
                            if let id = selectedPad?.id { service.rename(id, to: draftName) }
                        }
                        .macScopeGlassButton()
                        Spacer()
                            Button("New Pad", systemImage: "plus") {
                            let id = service.addTab()
                            selectedID = id
                            draftName = service.tabs.first(where: { $0.id == id })?.name ?? ""
                        }
                            .macScopeGlassButton(prominent: true)
                            Menu("Auto-clear", systemImage: "timer") {
                                Button("Off") { service.setAutoClear(after: nil) }
                                Button("After 15 minutes") { service.setAutoClear(after: 15 * 60) }
                                Button("After 1 hour") { service.setAutoClear(after: 60 * 60) }
                                Button("After 1 day") { service.setAutoClear(after: 24 * 60 * 60) }
                            }
                            .macScopeGlassButton()
                        }

                    if let pad = selectedPad {
                        HStack(alignment: .top, spacing: 12) {
                            TextEditor(text: Binding(
                                get: { service.tabs.first(where: { $0.id == pad.id })?.text ?? "" },
                                set: { service.updateText(pad.id, text: $0) }
                            ))
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                            if showsPreview {
                                ScrollView {
                                    Text((try? AttributedString(markdown: pad.text)) ?? AttributedString(pad.text))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .textSelection(.enabled)
                                        .padding(12)
                                }
                                .frame(maxWidth: .infinity)
                                .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .frame(maxHeight: .infinity)

                        HStack {
                            Toggle("Markdown preview", isOn: $showsPreview)
                            Spacer()
                            Button("Copy All", systemImage: "doc.on.doc") { service.copy(pad.id) }
                                .macScopeGlassButton()
                            Button("Export…", systemImage: "square.and.arrow.up") { service.export(pad.id) }
                                .macScopeGlassButton()
                            Button("Clear", role: .destructive) { service.clear(pad.id) }
                                .macScopeGlassButton()
                            Button("Delete Pad", role: .destructive) { service.delete(pad.id) }
                                .macScopeGlassButton()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let message = service.statusMessage {
                UtilityNotice(icon: "info.circle", title: "Scratchpad", detail: message)
            }
        }
        .padding(24)
        .task {
            if selectedID == nil {
                selectedID = service.tabs.first?.id
                draftName = service.tabs.first?.name ?? ""
            }
        }
    }
}

private enum MaintenanceConfirmation: Identifiable {
    case trash(URL)
    case trashMany([URL], String)
    case organizeMessaging([URL])
    case uninstall(InstalledApplicationItem, [URL])
    case upgrade(HomebrewOutdatedItem)
    case upgradeAll([HomebrewOutdatedItem])
    case homebrewChange(HomebrewSearchItem, Bool)

    var id: String {
        switch self {
        case .trash(let url): "trash:\(url.path)"
        case .trashMany(let urls, _): "trash-many:\(urls.map(\.path).joined(separator: "|"))"
        case .organizeMessaging(let urls): "organize-messaging:\(urls.map(\.path).joined(separator: "|"))"
        case .uninstall(let app, _): "uninstall:\(app.url.path)"
        case .upgrade(let item): "upgrade:\(item.id)"
        case .upgradeAll(let items): "upgrade-all:\(items.map(\.id).joined(separator: "|"))"
        case .homebrewChange(let item, let install): "brew:\(install):\(item.id)"
        }
    }
}

private enum MaintenancePane: String, CaseIterable, Identifiable {
    case applications = "Apps"
    case cleaner = "Cleaner"
    case downloads = "Downloads"
    case homebrew = "Homebrew"
    case media = "Media"
    var id: String { rawValue }
}

private struct MaintenanceUtilityView: View {
    let service: MaintenanceUtilityService
    let media: MediaUtilityService
    @Binding var selectedTab: UtilityTab
    @State private var confirmation: MaintenanceConfirmation?
    @State private var selectedPane = MaintenancePane.applications
    @State private var mediaFormat = MediaExportFormat.png
    @State private var mediaQuality = 0.86
    @State private var resizeImage = false
    @State private var maximumDimension = 2_048.0
    @State private var watermarkText = ""
    @State private var gifFrameDuration = 0.25
    @State private var mediaProfileName = ""
    @State private var videoTrimStart = 0.0
    @State private var videoTrimEnd = 0.0
    @State private var videoCropLeft = 0.0
    @State private var videoCropRight = 0.0
    @State private var videoCropTop = 0.0
    @State private var videoCropBottom = 0.0
    @State private var homebrewSearch = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Maintenance",
                    subtitle: "Inventory apps, find large downloads and manage Homebrew updates with review before changes"
                )
                UtilityTabPicker(selection: $selectedTab)

                Picker("Maintenance tool", selection: $selectedPane) {
                    ForEach(MaintenancePane.allCases) { pane in Text(pane.rawValue).tag(pane) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .center)

                Group {
                    switch selectedPane {
                    case .applications: applicationsPanel
                    case .cleaner: cleanerPanel
                    case .downloads: downloadsPanel
                    case .homebrew: homebrewPanel
                    case .media: mediaPanel
                    }
                }

                if let message = service.statusMessage {
                    UtilityNotice(icon: "info.circle", title: "Maintenance status", detail: message)
                }
                if let message = media.statusMessage {
                    UtilityNotice(icon: "photo.badge.checkmark", title: "Media status", detail: message)
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch confirmation {
            case .trash(let url):
                Button("Move \(url.lastPathComponent) to Trash", role: .destructive) {
                    service.moveToTrash(url)
                    confirmation = nil
                }
            case .trashMany(let urls, let label):
                Button("Move \(label) to Trash", role: .destructive) {
                    service.moveToTrash(urls)
                    confirmation = nil
                }
            case .organizeMessaging(let urls):
                Button("Organize \(urls.count) Files") {
                    service.organizeMessagingDownloads(urls)
                    confirmation = nil
                }
            case .uninstall(let app, let leftovers):
                Button("Move App Only to Trash", role: .destructive) {
                    service.moveToTrash(app.url)
                    confirmation = nil
                }
                if !leftovers.isEmpty {
                    Button("Move App + \(leftovers.count) Related Items", role: .destructive) {
                        service.moveToTrash([app.url] + leftovers)
                        confirmation = nil
                    }
                }
            case .upgrade(let item):
                Button("Update \(item.name)") {
                    service.upgrade(item)
                    confirmation = nil
                }
            case .upgradeAll(let items):
                Button("Update All \(items.count) Packages") {
                    service.upgradeAll(items)
                    confirmation = nil
                }
            case .homebrewChange(let item, let install):
                Button("\(install ? "Install" : "Remove") \(item.name)", role: install ? nil : .destructive) {
                    service.setHomebrewInstalled(install, item: item)
                    confirmation = nil
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .trash: "This item will remain recoverable in Trash."
        case .trashMany(let urls, _):
            "Move \(urls.count) reviewed items to Trash? They remain recoverable."
        case .organizeMessaging(let urls):
            "Move \(urls.count) reviewed files into category folders under the chosen organizer folder? Existing names are never overwritten."
        case .uninstall(_, let leftovers):
            leftovers.isEmpty
                ? "No standard related files were found. The app will remain recoverable in Trash."
                : "Review: \(leftovers.map(\.lastPathComponent).joined(separator: ", ")). Everything remains recoverable in Trash."
        case .upgrade: "Homebrew will download and install this update."
        case .upgradeAll(let items): "Homebrew will download and install \(items.count) reviewed updates in sequence."
        case .homebrewChange(let item, let install):
            "Homebrew will \(install ? "install" : "remove") \(item.name) and resolve its dependencies."
        case nil: "Confirm action"
        }
    }

    private var applicationsPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Applications", systemImage: "app.dashed")
                            .font(.headline)
                        Text("Review apps from /Applications and your user Applications folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        service.isScanningApplications ? "Scanning…" : "Scan Apps",
                        systemImage: "magnifyingglass"
                    ) { service.scanApplications() }
                        .disabled(service.isScanningApplications)
                        .macScopeGlassButton(prominent: true)
                    Button(
                        service.isCheckingApplicationUpdates ? "Checking…" : "Check Updates",
                        systemImage: "arrow.down.app"
                    ) { service.checkApplicationUpdates() }
                        .disabled(service.isCheckingApplicationUpdates)
                        .macScopeGlassButton()
                }
                HStack(spacing: 12) {
                    Toggle("Deep leftover discovery", isOn: Binding(
                        get: { service.deepUninstallerScanEnabled },
                        set: { service.setDeepUninstallerScanEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Text("Adds reviewed user/system Library matches for the exact app name or bundle identifier.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Full Disk Access…", systemImage: "lock.shield") {
                        service.openFullDiskAccessSettings()
                    }
                    .macScopeGlassButton()
                }
                HStack(spacing: 12) {
                    Toggle("Daily background update checks", isOn: Binding(
                        get: { service.backgroundUpdateChecksEnabled },
                        set: { service.setBackgroundUpdateChecksEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Text(service.nextBackgroundUpdateCheck.map {
                        "Next check \($0.formatted(date: .abbreviated, time: .shortened)); notifications appear only when updates are found."
                    } ?? "Checks exact App Store catalog versions and Homebrew only while MacScope is running.")
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Background Check Now", systemImage: "arrow.clockwise") {
                        service.runBackgroundUpdateCheckNow()
                    }
                    .disabled(service.isCheckingApplicationUpdates || service.isCheckingHomebrew)
                    .macScopeGlassButton()
                }
                HStack(spacing: 18) {
                    Text("Update sources").font(.caption.weight(.semibold))
                    Toggle("App Store catalog", isOn: Binding(
                        get: { service.appCatalogUpdateSourceEnabled },
                        set: { service.setAppCatalogUpdateSourceEnabled($0) }
                    ))
                    .toggleStyle(.checkbox)
                    Toggle("Homebrew", isOn: Binding(
                        get: { service.homebrewUpdateSourceEnabled },
                        set: { service.setHomebrewUpdateSourceEnabled($0) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                ForEach(service.applicationUpdates) { update in
                    HStack {
                        Image(systemName: "arrow.down.app.fill").foregroundStyle(MacScopeTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.name).font(.callout.weight(.medium))
                            Text("\(update.installedVersion) → \(update.availableVersion) · App Store catalog")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Update") { service.open(update.storeURL) }
                            .macScopeGlassButton(prominent: true)
                    }
                    Divider()
                }
                ForEach(service.applications) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().scaledToFit().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.callout.weight(.medium))
                            Text(app.size > 0 ? byteCount(app.size) : app.url.deletingLastPathComponent().path)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { service.open(app.url) }.buttonStyle(.link)
                        Button("Reveal") { service.reveal(app.url) }.buttonStyle(.link)
                        Button("Uninstall…", role: .destructive) {
                            confirmation = .uninstall(app, service.relatedApplicationFiles(for: app))
                        }
                            .buttonStyle(.link)
                    }
                    if app.id != service.applications.last?.id { Divider() }
                }
            }
        }
    }

    private var downloadsPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Large Downloads", systemImage: "externaldrive.badge.magnifyingglass")
                            .font(.headline)
                        Text("Find regular files at least 100 MB. MacScope never removes anything automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        service.isScanningDownloads ? "Scanning…" : "Scan Downloads",
                        systemImage: "magnifyingglass"
                    ) { service.scanDownloads() }
                        .disabled(service.isScanningDownloads)
                        .macScopeGlassButton()
                }
                ForEach(service.largeDownloads) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text("\(byteCount(item.size)) · \(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") { service.reveal(item.url) }.buttonStyle(.link)
                        Button("Trash…", role: .destructive) { confirmation = .trash(item.url) }
                            .buttonStyle(.link)
                    }
                }

                Divider().padding(.vertical, 4)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Messaging downloads", systemImage: "message.badge.waveform")
                            .font(.headline)
                        Text("Reviews only top-level Downloads files that macOS quarantine metadata attributes to WhatsApp, Telegram, Signal, Discord or Messages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Keep for", selection: Binding(
                        get: { service.messagingRetentionDays },
                        set: { service.setMessagingRetentionDays($0) }
                    )) {
                        ForEach([1, 2, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .frame(width: 130)
                    Button(
                        service.isScanningMessagingDownloads ? "Scanning…" : "Scan Metadata",
                        systemImage: "magnifyingglass"
                    ) { service.scanMessagingDownloads() }
                        .disabled(service.isScanningMessagingDownloads)
                        .macScopeGlassButton()
                }
                if let folder = service.messagingOrganizerFolder {
                    HStack {
                        Label("Organizer: \(folder.path(percentEncoded: false))", systemImage: "folder")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Change…") { service.chooseMessagingOrganizerFolder() }.buttonStyle(.link)
                    }
                } else {
                    Button("Choose Organizer Folder…", systemImage: "folder.badge.plus") {
                        service.chooseMessagingOrganizerFolder()
                    }
                    .macScopeGlassButton()
                }
                HStack(spacing: 10) {
                    Label("Daily automation", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.callout.weight(.medium))
                    Picker("Daily automation", selection: Binding(
                        get: { service.messagingAutomationMode },
                        set: { service.setMessagingAutomationMode($0) }
                    )) {
                        ForEach(MessagingAutomationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    if let next = service.nextMessagingAutomation {
                        Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if service.messagingAutomationMode != .off {
                        Button("Run Now", systemImage: "play.fill") { service.runMessagingAutomationNow() }
                            .disabled(service.isScanningMessagingDownloads)
                            .macScopeGlassButton()
                    }
                }
                Text("Automation remains limited to top-level files whose macOS quarantine metadata names a supported messaging app. Trash mode is recoverable; organizer mode uses collision-safe moves and never overwrites.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                let eligible = service.messagingDownloads.filter(\.isRetentionEligible)
                if !eligible.isEmpty {
                    HStack {
                        Text("\(eligible.count) item\(eligible.count == 1 ? " is" : "s are") older than the retention window by both download and edit date.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if service.messagingOrganizerFolder != nil {
                            Button("Organize Eligible…") {
                                confirmation = .organizeMessaging(eligible.map(\.url))
                            }
                            .macScopeGlassButton()
                        }
                        Button("Trash Eligible…", role: .destructive) {
                            confirmation = .trashMany(eligible.map(\.url), "\(eligible.count) messaging files")
                        }
                        .macScopeGlassButton()
                    }
                }
                ForEach(service.messagingDownloads) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isRetentionEligible ? "clock.badge.checkmark" : "clock")
                            .foregroundStyle(item.isRetentionEligible ? MacScopeTheme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text("\(item.sourceApplication) · \(item.category.rawValue) · \(byteCount(item.size)) · Downloaded \(item.downloadedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") { service.reveal(item.url) }.buttonStyle(.link)
                        Button("Trash…", role: .destructive) { confirmation = .trash(item.url) }
                            .buttonStyle(.link)
                    }
                    if item.id != service.messagingDownloads.last?.id { Divider() }
                }
            }
        }
    }

    private var cleanerPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Caches & logs", systemImage: "sparkles")
                            .font(.headline)
                        Text("Review top-level items in your user Caches and Logs folders. Nothing is removed automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        service.isScanningCleanup ? "Scanning…" : "Scan Caches & Logs",
                        systemImage: "magnifyingglass"
                    ) { service.scanCleanupCandidates() }
                        .disabled(service.isScanningCleanup)
                        .macScopeGlassButton(prominent: true)
                    Menu("Schedule", systemImage: "calendar.badge.clock") {
                        Button("Off") { service.setCleanupSchedule(hours: nil) }
                        Button("Every 24 hours") { service.setCleanupSchedule(hours: 24) }
                        Button("Every 3 days") { service.setCleanupSchedule(hours: 72) }
                        Button("Weekly") { service.setCleanupSchedule(hours: 168) }
                    }
                    .macScopeGlassButton()
                }
                if let next = service.nextCleanupScan {
                    Text("Next review scan: \(next.formatted(date: .abbreviated, time: .shortened)). Scans never delete automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(service.cleanupCandidates) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text("\(item.category) · \(byteCount(item.size)) · Modified \(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal") { service.reveal(item.url) }.buttonStyle(.link)
                        Button("Trash…", role: .destructive) { confirmation = .trash(item.url) }
                            .buttonStyle(.link)
                    }
                    if item.id != service.cleanupCandidates.last?.id { Divider() }
                }
            }
        }
    }

    private var homebrewPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Homebrew updates", systemImage: "mug")
                            .font(.headline)
                        Text(service.brewExecutable == nil
                             ? "Homebrew was not found in its standard Apple Silicon or Intel location."
                             : "Check formulae and casks, then approve each update individually.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        service.isCheckingHomebrew ? "Checking…" : "Check Updates",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) { service.checkHomebrew() }
                        .disabled(!service.homebrewUpdateSourceEnabled || service.brewExecutable == nil || service.isCheckingHomebrew)
                        .macScopeGlassButton()
                    if !service.outdatedPackages.isEmpty {
                        Button("Update All…", systemImage: "arrow.down.circle.fill") {
                            confirmation = .upgradeAll(service.outdatedPackages)
                        }
                        .disabled(service.activeOperation != nil)
                        .macScopeGlassButton(prominent: true)
                    }
                }
                HStack(spacing: 10) {
                    TextField("Search formulae and casks", text: $homebrewSearch)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { service.searchHomebrew(homebrewSearch) }
                    Button(service.isSearchingHomebrew ? "Searching…" : "Search", systemImage: "magnifyingglass") {
                        service.searchHomebrew(homebrewSearch)
                    }
                    .disabled(homebrewSearch.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || service.isSearchingHomebrew)
                    .macScopeGlassButton(prominent: true)
                }
                ForEach(service.homebrewSearchResults.prefix(30)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text("\(item.isCask ? "Cask" : "Formula") · \(item.isInstalled ? "Installed" : "Available")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(item.isInstalled ? "Remove…" : "Install…") {
                            confirmation = .homebrewChange(item, !item.isInstalled)
                        }
                        .disabled(service.activeOperation != nil)
                        .macScopeGlassButton(prominent: !item.isInstalled)
                    }
                }
                if !service.homebrewSearchResults.isEmpty, !service.outdatedPackages.isEmpty {
                    Divider()
                }
                ForEach(service.outdatedPackages) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text("\(item.installed) → \(item.current) · \(item.isCask ? "Cask" : "Formula")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(service.activeOperation == item.id ? "Updating…" : "Update…") {
                            confirmation = .upgrade(item)
                        }
                        .disabled(service.activeOperation != nil)
                        .macScopeGlassButton(prominent: true)
                    }
                }
            }
        }
    }

    private var mediaPanel: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Image converter", systemImage: "photo.on.rectangle.angled")
                            .font(.headline)
                        Text("Convert PNG or JPEG, resize, watermark, extract text, or turn a batch into an animated GIF.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Images…", systemImage: "photo.on.rectangle") { media.chooseImage() }
                        .macScopeGlassButton(prominent: media.sourceURL == nil)
                }
                if let source = media.sourceURL {
                    Divider()
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                            .resizable().scaledToFit().frame(width: 34, height: 34)
                        Text(media.sourceURLs.count > 1 ? "\(media.sourceURLs.count) images selected" : source.lastPathComponent).lineLimit(1)
                        Spacer()
                        Picker("Format", selection: $mediaFormat) {
                            ForEach(MediaExportFormat.allCases) { format in Text(format.rawValue).tag(format) }
                        }
                        .frame(width: 120)
                        if mediaFormat == .jpeg {
                            Slider(value: $mediaQuality, in: 0.4...1)
                                .frame(width: 110)
                            Text("\(Int(mediaQuality * 100))%")
                                .font(.caption.monospacedDigit()).frame(width: 34)
                        }
                    }
                    HStack {
                        Toggle("Limit longest edge", isOn: $resizeImage)
                        if resizeImage {
                            TextField("Pixels", value: $maximumDimension, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("px").foregroundStyle(.secondary)
                        }
                        TextField("Optional watermark", text: $watermarkText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                        Spacer()
                        Button(media.isExtractingText ? "Reading…" : "Extract Text", systemImage: "text.viewfinder") {
                            media.extractText()
                        }
                        .disabled(media.isExtractingText)
                        .macScopeGlassButton()
                        if media.outputURL != nil {
                            Button("Reveal Output", systemImage: "magnifyingglass") { media.revealOutput() }
                                .macScopeGlassButton()
                        }
                        Button(media.isConverting ? "Converting…" : "Convert") {
                            media.convert(
                                format: mediaFormat,
                                quality: mediaQuality,
                                maximumDimension: resizeImage ? maximumDimension : nil,
                                watermark: watermarkText
                            )
                        }
                        .disabled(media.isConverting)
                        .macScopeGlassButton(prominent: true)
                    }
                    HStack(spacing: 10) {
                        if !media.profiles.isEmpty {
                            Menu("Apply Profile", systemImage: "slider.horizontal.3") {
                                ForEach(media.profiles) { profile in
                                    Button(profile.name) {
                                        mediaFormat = profile.format
                                        mediaQuality = profile.quality
                                        resizeImage = profile.maximumDimension != nil
                                        maximumDimension = profile.maximumDimension ?? maximumDimension
                                        watermarkText = profile.watermark ?? ""
                                    }
                                }
                                Divider()
                                Menu("Remove Profile") {
                                    ForEach(media.profiles) { profile in
                                        Button(profile.name, role: .destructive) { media.deleteProfile(profile) }
                                    }
                                }
                            }
                            .macScopeGlassButton()
                        }
                        TextField("Profile name", text: $mediaProfileName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                        Button("Save Profile", systemImage: "square.and.arrow.down") {
                            media.saveProfile(
                                name: mediaProfileName,
                                format: mediaFormat,
                                quality: mediaQuality,
                                maximumDimension: resizeImage ? maximumDimension : nil,
                                watermark: watermarkText
                            )
                            if !mediaProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                mediaProfileName = ""
                            }
                        }
                        .macScopeGlassButton()
                        Spacer()
                    }
                    if media.sourceURLs.count >= 2 {
                        HStack(spacing: 10) {
                            Label("Animated GIF", systemImage: "photo.stack")
                                .font(.callout.weight(.medium))
                            TextField("Seconds per frame", value: $gifFrameDuration, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("seconds per frame")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if media.gifOutputURL != nil {
                                Button("Reveal GIF", systemImage: "magnifyingglass") { media.revealGIFOutput() }
                                    .macScopeGlassButton()
                            }
                            Button(media.isCreatingGIF ? "Creating…" : "Create GIF") {
                                media.createAnimatedGIF(frameDuration: gifFrameDuration)
                            }
                            .disabled(media.isCreatingGIF)
                            .macScopeGlassButton(prominent: true)
                        }
                    }
                    if !media.extractedText.isEmpty {
                        TextEditor(text: .constant(media.extractedText))
                            .font(.caption.monospaced())
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Button("Copy Recognized Text", systemImage: "doc.on.doc") { media.copyExtractedText() }
                            .macScopeGlassButton()
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Video compressor", systemImage: "film.stack")
                            .font(.headline)
                        Text("Create a network-optimized medium-quality MP4 locally.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Video…", systemImage: "film") { media.chooseVideo() }
                        .macScopeGlassButton(prominent: media.videoSourceURL == nil)
                }
                if let video = media.videoSourceURL {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: video.path))
                                .resizable().scaledToFit().frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.lastPathComponent).lineLimit(1)
                                if media.videoDuration > 0 {
                                    Text("Duration: \(media.videoDuration.formatted(.number.precision(.fractionLength(1)))) seconds")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if media.videoOutputURL != nil {
                                Button("Reveal Output", systemImage: "magnifyingglass") { media.revealVideoOutput() }
                                    .macScopeGlassButton()
                            }
                            Button(media.isCompressingVideo ? "Compressing…" : "Compress MP4") {
                                media.compressVideo()
                            }
                            .disabled(media.isCompressingVideo || media.isEditingVideo)
                            .macScopeGlassButton(prominent: true)
                        }
                        if media.videoDuration > 0 {
                            Divider()
                            HStack(spacing: 10) {
                                Label("Trim", systemImage: "timeline.selection")
                                    .font(.callout.weight(.medium))
                                TextField("Start", value: $videoTrimStart, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 90)
                                Text("to").font(.caption).foregroundStyle(.secondary)
                                TextField("End", value: $videoTrimEnd, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 90)
                                Text("seconds").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use Full Duration") {
                                    videoTrimStart = 0
                                    videoTrimEnd = media.videoDuration
                                }
                                .buttonStyle(.link)
                                Button(media.isEditingVideo ? "Trimming…" : "Trim MP4") {
                                    media.trimVideo(start: videoTrimStart, end: videoTrimEnd)
                                }
                                .disabled(media.isEditingVideo || media.isCompressingVideo || videoTrimEnd <= videoTrimStart)
                                .macScopeGlassButton()
                                Button(media.isEditingVideo ? "Editing…" : "Remove Range") {
                                    media.cutVideo(start: videoTrimStart, end: videoTrimEnd)
                                }
                                .disabled(
                                    media.isEditingVideo
                                        || media.isCompressingVideo
                                        || videoTrimEnd <= videoTrimStart
                                        || (videoTrimStart <= 0 && videoTrimEnd >= media.videoDuration)
                                )
                                .macScopeGlassButton()
                            }
                            .onAppear {
                                if videoTrimEnd <= videoTrimStart { videoTrimEnd = media.videoDuration }
                            }
                            .onChange(of: media.videoDuration) { _, duration in
                                if videoTrimEnd <= 0 || videoTrimEnd > duration { videoTrimEnd = duration }
                            }

                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Crop", systemImage: "crop")
                                    .font(.callout.weight(.medium))
                                HStack(spacing: 8) {
                                    cropPercentField("Left", value: $videoCropLeft)
                                    cropPercentField("Right", value: $videoCropRight)
                                    cropPercentField("Top", value: $videoCropTop)
                                    cropPercentField("Bottom", value: $videoCropBottom)
                                    Spacer()
                                    Button("Reset") {
                                        videoCropLeft = 0
                                        videoCropRight = 0
                                        videoCropTop = 0
                                        videoCropBottom = 0
                                    }
                                    .buttonStyle(.link)
                                    Button(media.isEditingVideo ? "Cropping…" : "Crop MP4") {
                                        media.cropVideo(
                                            left: videoCropLeft,
                                            right: videoCropRight,
                                            top: videoCropTop,
                                            bottom: videoCropBottom
                                        )
                                    }
                                    .disabled(
                                        media.isEditingVideo
                                            || media.isCompressingVideo
                                            || [videoCropLeft, videoCropRight, videoCropTop, videoCropBottom].allSatisfy { $0 <= 0 }
                                    )
                                    .macScopeGlassButton()
                                }
                                Text("Insets are percentages of the displayed frame. The export keeps audio and never overwrites the source.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func cropPercentField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct KeepAwakeUtilityView: View {
    let service: KeepAwakeService
    let displays: DisplayControlService
    let cleaningMode: CleaningModeService
    @Binding var selectedTab: UtilityTab
    @State private var includesDisplay = false
    @State private var cleaningDuration: Double = 60
    @State private var confirmsCleaningMode = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                SectionHeader(
                    title: "Keep awake",
                    subtitle: "Prevent idle sleep for a focused session without changing Energy settings"
                )
                UtilityTabPicker(selection: $selectedTab)

                GlassGroup {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            Image(systemName: service.isActive ? "cup.and.saucer.fill" : "moon.zzz")
                                .font(.system(size: 34))
                                .foregroundStyle(service.isActive ? MacScopeTheme.accent : .secondary)
                                .frame(width: 58, height: 58)
                                .background(MacScopeTheme.accent.opacity(service.isActive ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(service.isActive ? "Mac is staying awake" : "Normal sleep behavior")
                                    .font(.title3.weight(.semibold))
                                if let endsAt = service.endsAt {
                                    Text("Ends \(endsAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else if service.isActive {
                                    Text("Active until you stop it")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if service.isActive {
                                Button("Stop", systemImage: "stop.fill", role: .destructive) { service.stop() }
                                    .macScopeGlassButton()
                            }
                        }

                        Divider()
                        Toggle("Also keep the display awake", isOn: $includesDisplay)
                            .disabled(service.isActive)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { durationButtons }
                            VStack(alignment: .leading, spacing: 10) { durationButtons }
                        }

                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Automations").font(.headline)
                            Toggle("Keep awake while connected to power", isOn: Binding(
                                get: { service.startsOnACPower },
                                set: { service.setStartsOnACPower($0) }
                            ))
                            Toggle("Keep awake while an external display is connected", isOn: Binding(
                                get: { service.startsWithExternalDisplay },
                                set: { service.setStartsWithExternalDisplay($0) }
                            ))
                        }
                    }
                }

                UtilityNotice(
                    icon: "lock.shield",
                    title: "Native power assertion",
                    detail: "MacScope asks macOS to prevent idle sleep. It does not change persistent system preferences, and the assertion disappears if the app exits."
                )

                GlassGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.title2).foregroundStyle(cleaningMode.isActive ? .green : MacScopeTheme.accent)
                            .frame(width: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cleaning Mode").font(.headline)
                            Text("Black out every display and block keyboard/pointer input while you wipe the hardware. Escape always exits; the timer is a second fail-safe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Duration", selection: $cleaningDuration) {
                            Text("30 sec").tag(30.0)
                            Text("1 min").tag(60.0)
                            Text("2 min").tag(120.0)
                        }
                        .frame(width: 100)
                        if cleaningMode.isActive {
                            Button("Stop", role: .destructive) { cleaningMode.stop() }
                                .macScopeGlassButton()
                        } else {
                            Button("Start…", systemImage: "lock.display") { confirmsCleaningMode = true }
                                .macScopeGlassButton(prominent: true)
                        }
                    }
                    if let error = cleaningMode.errorMessage {
                        UtilityErrorBanner(message: error).padding(.top, 8)
                    }
                }
                .confirmationDialog(
                    "Start Cleaning Mode?",
                    isPresented: $confirmsCleaningMode,
                    titleVisibility: .visible
                ) {
                    Button("Black Out and Lock Input") { cleaningMode.start(duration: cleaningDuration) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All displays turn black and input is blocked for up to \(Int(cleaningDuration)) seconds. Press Escape at any time to stop.")
                }

                GlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Display brightness", systemImage: "sun.max.fill")
                                    .font(.headline)
                                Text("Uses each display's public IOKit brightness channel when available.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { displays.refresh() }
                                .macScopeGlassButton()
                        }
                        if displays.displays.isEmpty {
                            UtilityNotice(
                                icon: "display.trianglebadge.exclamationmark",
                                title: "No brightness channels found",
                                detail: "Some external displays require hardware buttons or a vendor-specific DDC implementation."
                            )
                        } else {
                            ForEach(displays.displays) { display in
                                HStack(spacing: 12) {
                                    Image(systemName: "display")
                                    Text(display.name).frame(width: 190, alignment: .leading).lineLimit(1)
                                    if let brightness = display.brightness {
                                        Slider(value: Binding(
                                            get: { displays.displays.first(where: { $0.id == display.id })?.brightness ?? brightness },
                                            set: { displays.setBrightness($0, for: display) }
                                        ), in: 0...1)
                                        Text("\(Int((displays.displays.first(where: { $0.id == display.id })?.brightness ?? brightness) * 100))%")
                                            .font(.caption.monospacedDigit()).frame(width: 42)
                                    } else {
                                        Text("Hardware control unavailable")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        if let message = displays.statusMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }

                        Divider().padding(.vertical, 2)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Software dimming fallback", systemImage: "sun.min.fill")
                                    .font(.headline)
                                Text("Dims the picture through macOS ColorSync when a display has no writable hardware channel. Restores automatically when MacScope exits.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore All", systemImage: "arrow.counterclockwise") {
                                displays.restoreSoftwareDimming()
                            }
                            .macScopeGlassButton()
                        }
                        ForEach(displays.softwareDisplays) { display in
                            HStack(spacing: 12) {
                                Image(systemName: "display")
                                Text(display.name).frame(width: 190, alignment: .leading).lineLimit(1)
                                Slider(value: Binding(
                                    get: { displays.softwareDisplays.first(where: { $0.id == display.id })?.level ?? display.level },
                                    set: { displays.setSoftwareLevel($0, for: display) }
                                ), in: 0.1...1)
                                Text("\(Int((displays.softwareDisplays.first(where: { $0.id == display.id })?.level ?? display.level) * 100))%")
                                    .font(.caption.monospacedDigit()).frame(width: 42)
                            }
                        }
                    }
                }

                if let error = service.errorMessage { UtilityErrorBanner(message: error) }
            }
            .padding(24)
        }
        .task { displays.refresh() }
    }

    @ViewBuilder private var durationButtons: some View {
        Button("30 minutes") { service.start(duration: 30 * 60, includesDisplay: includesDisplay) }
            .macScopeGlassButton(prominent: true)
        Button("1 hour") { service.start(duration: 60 * 60, includesDisplay: includesDisplay) }
            .macScopeGlassButton()
        Button("2 hours") { service.start(duration: 2 * 60 * 60, includesDisplay: includesDisplay) }
            .macScopeGlassButton()
        Button("Until stopped") { service.start(duration: nil, includesDisplay: includesDisplay) }
            .macScopeGlassButton()
    }
}

private struct UtilityNotice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(MacScopeTheme.cyan)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct UtilityErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
