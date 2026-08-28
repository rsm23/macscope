import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import MacScopeCore
import Observation

struct AudioMixerApp: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let audioObjects: [AudioObjectID]
    let isPlaying: Bool
    var volume: Double
    var outputDeviceUID: String?
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isDefault: Bool
}

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isDefault: Bool
}

@MainActor
@Observable
final class MusicAutoLaunchBlocker {
    private(set) var isEnabled = false
    private(set) var statusMessage: String?
    private var observer: NSObjectProtocol?

    init() {
        if UserDefaults.standard.bool(forKey: "utility.blockMusicAutoLaunch") {
            setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.blockMusicAutoLaunch")
        if enabled {
            installObserver()
            statusMessage = "Future Music launches will be asked to quit."
        } else {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
            statusMessage = "Music launch blocking is off."
        }
    }

    private func installObserver() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let launched = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  launched.bundleIdentifier == "com.apple.Music" else { return }
            let pid = launched.processIdentifier
            Task { @MainActor in
                guard let self, self.isEnabled,
                      let application = NSRunningApplication(processIdentifier: pid) else { return }
                if application.terminate() {
                    self.statusMessage = "Stopped Music after it launched."
                } else {
                    self.statusMessage = "Music did not accept the quit request."
                }
            }
        }
    }
}

@MainActor
@Observable
final class AudioMixerService {
    private(set) var apps: [AudioMixerApp] = []
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var systemVolume: Double?
    private(set) var systemMuted: Bool?
    private(set) var inputMuted: Bool?
    private(set) var pinnedInputUID: String?
    private(set) var errorMessage: String?
    private(set) var needsSystemAudioPermission = false
    private(set) var isRunning = false
    private(set) var lowersVolumeAfterHeadphoneDisconnect = false
    var disconnectVolume: Double {
        didSet {
            disconnectVolume = min(max(disconnectVolume, 0), 1)
            UserDefaults.standard.set(disconnectVolume, forKey: "utility.disconnectOutputVolume")
        }
    }

    private var timer: Timer?
    private var engines: [String: any AudioGainEngine] = [:]
    private var consumerCount = 0
    private let defaultsKey = "utility.perAppVolumes"
    private let routesDefaultsKey = "utility.perAppOutputRoutes"
    private var inputVolumesBeforeMute: [AudioObjectID: Float32] = [:]
    private var previousDefaultOutputUID: String?
    private var previousDefaultOutputName: String?

    init() {
        lowersVolumeAfterHeadphoneDisconnect = UserDefaults.standard.bool(
            forKey: "utility.lowerVolumeAfterHeadphoneDisconnect"
        )
        disconnectVolume = UserDefaults.standard.object(forKey: "utility.disconnectOutputVolume") == nil
            ? 0.25
            : UserDefaults.standard.double(forKey: "utility.disconnectOutputVolume")
        pinnedInputUID = UserDefaults.standard.string(forKey: "utility.pinnedInputUID")
    }

    var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    func start() {
        consumerCount += 1
        guard !isRunning else { return }
        isRunning = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        consumerCount = max(consumerCount - 1, 0)
        guard consumerCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        engines.values.forEach { $0.stop() }
        engines.removeAll()
        isRunning = false
    }

    func refresh() {
        let devices = Self.readOutputDevices()
        outputDevices = devices
        let defaultDevice = devices.first(where: \AudioOutputDevice.isDefault)
        if let previousUID = previousDefaultOutputUID,
           let previousName = previousDefaultOutputName,
           let defaultDevice,
           previousUID != defaultDevice.uid,
           lowersVolumeAfterHeadphoneDisconnect,
           Self.isPrivateListeningDevice(named: previousName),
           !Self.isPrivateListeningDevice(named: defaultDevice.name) {
            _ = Self.writeOutputVolume(Float32(disconnectVolume), device: defaultDevice.id)
            errorMessage = "Lowered speaker volume after \(previousName) disconnected."
        }
        previousDefaultOutputUID = defaultDevice?.uid
        previousDefaultOutputName = defaultDevice?.name
        systemVolume = defaultDevice.flatMap { Self.readOutputVolume(device: $0.id) }.map(Double.init)
        systemMuted = defaultDevice.flatMap { Self.readMute(device: $0.id) }
        let inputs = Self.readInputDevices()
        inputDevices = inputs
        if let pinnedInputUID,
           let pinned = inputs.first(where: { $0.uid == pinnedInputUID }),
           !pinned.isDefault,
           Self.setDefaultInput(pinned.id) {
            statusAfterInputPin(pinned.name)
        }
        if let input = inputs.first(where: \AudioInputDevice.isDefault) {
            inputMuted = Self.readMute(device: input.id, scope: kAudioObjectPropertyScopeInput)
                ?? Self.readInputVolume(device: input.id).map { $0 <= 0.001 }
        } else {
            inputMuted = nil
        }

        guard isSupported else {
            apps = []
            return
        }

        let saved = savedVolumes()
        let routes = savedRoutes()
        var grouped: [String: AudioMixerApp] = [:]
        for object in Self.audioProcessObjects() {
            var pid: pid_t = 0
            guard Self.read(object: object, selector: kAudioProcessPropertyPID, value: &pid),
                  pid > 0,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: pid),
                  application.activationPolicy == .regular else { continue }

            let bundleIdentifier = application.bundleIdentifier
            let rowID = bundleIdentifier ?? "pid:\(pid)"
            let name = application.localizedName ?? "Process \(pid)"
            var running: UInt32 = 0
            _ = Self.read(object: object, selector: kAudioProcessPropertyIsRunningOutput, value: &running)
            let volume = saved[bundleIdentifier ?? rowID] ?? 1
            let route = routes[bundleIdentifier ?? rowID]

            if let existing = grouped[rowID] {
                grouped[rowID] = AudioMixerApp(
                    id: rowID,
                    pid: existing.pid,
                    name: existing.name,
                    bundleIdentifier: existing.bundleIdentifier,
                    audioObjects: (existing.audioObjects + [object]).sorted(),
                    isPlaying: existing.isPlaying || running != 0,
                    volume: volume,
                    outputDeviceUID: route
                )
            } else {
                grouped[rowID] = AudioMixerApp(
                    id: rowID,
                    pid: pid,
                    name: name,
                    bundleIdentifier: bundleIdentifier,
                    audioObjects: [object],
                    isPlaying: running != 0,
                    volume: volume,
                    outputDeviceUID: route
                )
            }
        }

        apps = grouped.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying && !$1.isPlaying }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        reconcileEngines()
    }

    func setVolume(_ value: Double, for app: AudioMixerApp) {
        let volume = UtilitySupport.sanitizedAppVolume(value)
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index].volume = volume
        persist(volume: volume, for: app)
        applyEngine(for: apps[index])
    }

    func toggleMute(_ app: AudioMixerApp) {
        setVolume(app.volume > 0.001 ? 0 : 1, for: app)
    }

    func setOutputDevice(_ device: AudioOutputDevice?, for app: AudioMixerApp) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        let defaultUID = outputDevices.first(where: \AudioOutputDevice.isDefault)?.uid
        let route = device?.uid == defaultUID ? nil : device?.uid
        apps[index].outputDeviceUID = route
        persist(route: route, for: app)
        applyEngine(for: apps[index])
    }

    func setSystemVolume(_ value: Double) {
        guard let device = outputDevices.first(where: \AudioOutputDevice.isDefault) else { return }
        let volume = Float32(min(max(value, 0), 1))
        if Self.writeOutputVolume(volume, device: device.id) {
            systemVolume = Double(volume)
            if volume > 0 { _ = Self.writeMute(false, device: device.id); systemMuted = false }
            errorMessage = nil
        } else {
            errorMessage = "This output device does not expose software volume control."
        }
    }

    func toggleSystemMute() {
        guard let device = outputDevices.first(where: \AudioOutputDevice.isDefault),
              let muted = systemMuted else { return }
        if Self.writeMute(!muted, device: device.id) {
            systemMuted = !muted
            errorMessage = nil
        }
    }

    func selectOutput(_ device: AudioOutputDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &deviceID
        )
        if status == noErr {
            errorMessage = nil
            refresh()
        } else {
            errorMessage = "Unable to switch output (OSStatus \(status))."
        }
    }

    func cycleOutput() {
        guard outputDevices.count > 1 else {
            errorMessage = "Only one audio output is currently available."
            return
        }
        let index = outputDevices.firstIndex(where: \AudioOutputDevice.isDefault) ?? 0
        selectOutput(outputDevices[(index + 1) % outputDevices.count])
    }

    func setLowersVolumeAfterHeadphoneDisconnect(_ enabled: Bool) {
        lowersVolumeAfterHeadphoneDisconnect = enabled
        UserDefaults.standard.set(enabled, forKey: "utility.lowerVolumeAfterHeadphoneDisconnect")
    }

    func selectInput(_ device: AudioInputDevice) {
        if Self.setDefaultInput(device.id) {
            if pinnedInputUID != nil {
                pinnedInputUID = device.uid
                UserDefaults.standard.set(device.uid, forKey: "utility.pinnedInputUID")
            }
            errorMessage = nil
            refresh()
        } else { errorMessage = "Unable to switch input." }
    }

    func toggleInputPin() {
        if pinnedInputUID != nil {
            pinnedInputUID = nil
            UserDefaults.standard.removeObject(forKey: "utility.pinnedInputUID")
            errorMessage = nil
        } else if let current = inputDevices.first(where: \AudioInputDevice.isDefault) {
            pinnedInputUID = current.uid
            UserDefaults.standard.set(current.uid, forKey: "utility.pinnedInputUID")
            errorMessage = "Pinned \(current.name) as the preferred microphone."
        }
    }

    private func statusAfterInputPin(_ name: String) {
        errorMessage = "Restored pinned microphone: \(name)."
    }

    func toggleInputMute() {
        guard !inputDevices.isEmpty, let muted = inputMuted else { return }
        var changed = false
        if muted {
            for device in inputDevices {
                if Self.writeMute(false, device: device.id, scope: kAudioObjectPropertyScopeInput) {
                    changed = true
                } else if Self.writeInputVolume(
                    max(inputVolumesBeforeMute[device.id] ?? 1, 0.5), device: device.id
                ) {
                    changed = true
                }
            }
        } else {
            inputVolumesBeforeMute.removeAll()
            for device in inputDevices {
                inputVolumesBeforeMute[device.id] = Self.readInputVolume(device: device.id) ?? 1
                if Self.writeMute(true, device: device.id, scope: kAudioObjectPropertyScopeInput)
                    || Self.writeInputVolume(0, device: device.id) {
                    changed = true
                }
            }
        }
        if changed {
            inputMuted = !muted
            errorMessage = nil
        } else {
            errorMessage = "The connected input devices do not expose software mute or gain control."
        }
    }

    private func reconcileEngines() {
        let current = apps.reduce(into: [String: AudioMixerApp]()) { values, app in
            values[app.id] = app
        }
        for (id, engine) in engines where current[id] == nil {
            engine.stop()
            engines.removeValue(forKey: id)
        }
        for app in apps where needsEngine(app) {
            applyEngine(for: app)
        }
    }

    private static func isPrivateListeningDevice(named name: String) -> Bool {
        let normalized = name.lowercased()
        return ["headphone", "headset", "airpods", "earbuds", "beats"]
            .contains { normalized.contains($0) }
    }

    private func applyEngine(for app: AudioMixerApp) {
        if !needsEngine(app) {
            engines.removeValue(forKey: app.id)?.stop()
            if engines.isEmpty { needsSystemAudioPermission = false }
            return
        }
        guard let defaultOutputUID = outputDevices.first(where: \AudioOutputDevice.isDefault)?.uid else {
            errorMessage = "No default audio output is available."
            return
        }
        let outputUID = outputDevices.contains(where: { $0.uid == app.outputDeviceUID })
            ? (app.outputDeviceUID ?? defaultOutputUID) : defaultOutputUID
        if let existing = engines[app.id],
           existing.audioObjects == app.audioObjects,
           existing.gain == Float(app.volume),
           existing.outputDeviceUID == outputUID {
            return
        }

        let previous = engines[app.id]
        guard #available(macOS 14.4, *),
              let replacement = ProcessGainEngine(
                audioObjects: app.audioObjects,
                gain: Float(app.volume),
                outputDeviceUID: outputUID
              ) else {
            errorMessage = "MacScope could not create an audio tap. Allow MacScope in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            needsSystemAudioPermission = true
            return
        }
        engines[app.id] = replacement
        previous?.stop()
        needsSystemAudioPermission = false
        errorMessage = nil
    }

    private func savedVolumes() -> [String: Double] {
        let values = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        return values.reduce(into: [:]) { result, pair in
            guard let number = pair.value as? NSNumber else { return }
            result[pair.key] = UtilitySupport.sanitizedAppVolume(number.doubleValue)
        }
    }

    private func savedRoutes() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: routesDefaultsKey) as? [String: String] ?? [:]
    }

    private func needsEngine(_ app: AudioMixerApp) -> Bool {
        UtilitySupport.requiresAudioTap(
            volume: app.volume,
            hasCustomOutput: app.outputDeviceUID != nil
        )
    }

    private func persist(volume: Double, for app: AudioMixerApp) {
        let key = app.bundleIdentifier ?? app.id
        var values = savedVolumes()
        if UtilitySupport.isUnityVolume(volume) { values.removeValue(forKey: key) }
        else { values[key] = volume }
        UserDefaults.standard.set(values, forKey: defaultsKey)
    }

    private func persist(route: String?, for app: AudioMixerApp) {
        let key = app.bundleIdentifier ?? app.id
        var values = savedRoutes()
        if let route { values[key] = route }
        else { values.removeValue(forKey: key) }
        UserDefaults.standard.set(values, forKey: routesDefaultsKey)
    }

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var objects = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }
        return objects
    }

    private static func readOutputDevices() -> [AudioOutputDevice] {
        var defaultID = AudioObjectID(0)
        _ = read(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            value: &defaultID
        )

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            var transportType: UInt32 = 0
            _ = read(
                object: id,
                selector: kAudioDevicePropertyTransportType,
                value: &transportType
            )
            guard transportType != kAudioDeviceTransportTypeAggregate,
                  outputChannelCount(device: id) > 0,
                  let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device: id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID)
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func readInputDevices() -> [AudioInputDevice] {
        var defaultID = AudioObjectID(0)
        _ = read(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            value: &defaultID
        )
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(device: id) > 0,
                  let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device: id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID)
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func setDefaultInput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &deviceID
        ) == noErr
    }

    private static func inputChannelCount(device: AudioObjectID) -> Int {
        channelCount(device: device, scope: kAudioObjectPropertyScopeInput)
    }

    private static func outputChannelCount(device: AudioObjectID) -> Int {
        channelCount(device: device, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func channelCount(
        device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        device: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString = "" as CFString
        guard read(object: device, selector: selector, value: &value) else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    private static let volumeSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyVolumeScalar
    ]

    private static func readOutputVolume(device: AudioObjectID) -> Float32? {
        for selector in volumeSelectors {
            var value: Float32 = 0
            if read(
                object: device,
                selector: selector,
                value: &value,
                scope: kAudioObjectPropertyScopeOutput
            ) { return value }
        }
        return nil
    }

    private static func writeOutputVolume(_ volume: Float32, device: AudioObjectID) -> Bool {
        for selector in volumeSelectors {
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: AudioObjectPropertyElement(element)
                )
                guard AudioObjectHasProperty(device, &address) else { continue }
                var settable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                      settable.boolValue else { continue }
                var value = volume
                if AudioObjectSetPropertyData(
                    device, &address, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &value
                ) == noErr { return true }
            }
        }
        return false
    }

    private static func readInputVolume(device: AudioObjectID) -> Float32? {
        for selector in volumeSelectors {
            var value: Float32 = 0
            if read(object: device, selector: selector, value: &value, scope: kAudioObjectPropertyScopeInput) {
                return value
            }
        }
        return nil
    }

    private static func writeInputVolume(_ volume: Float32, device: AudioObjectID) -> Bool {
        writeVolume(volume, device: device, scope: kAudioObjectPropertyScopeInput)
    }

    private static func writeVolume(
        _ volume: Float32,
        device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        for selector in volumeSelectors {
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: scope,
                    mElement: AudioObjectPropertyElement(element)
                )
                guard AudioObjectHasProperty(device, &address) else { continue }
                var settable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                      settable.boolValue else { continue }
                var value = volume
                if AudioObjectSetPropertyData(
                    device, &address, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &value
                ) == noErr { return true }
            }
        }
        return false
    }

    private static func readMute(
        device: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool? {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var value: UInt32 = 0
            if read(
                object: device,
                selector: kAudioDevicePropertyMute,
                value: &value,
                scope: scope,
                element: AudioObjectPropertyElement(element)
            ) { return value != 0 }
        }
        return nil
    }

    private static func writeMute(
        _ muted: Bool,
        device: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        var changed = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            ) == noErr { changed = true }
        }
        return changed
    }

    @discardableResult
    private static func read<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        value: inout T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(
                object, &address, 0, nil, &size, bytes.baseAddress!
            ) == noErr
        }
    }
}

private protocol AudioGainEngine: AnyObject {
    var audioObjects: [AudioObjectID] { get }
    var gain: Float { get }
    var outputDeviceUID: String { get }
    func stop()
}

@available(macOS 14.4, *)
private final class ProcessGainEngine: AudioGainEngine {
    let audioObjects: [AudioObjectID]
    let gain: Float
    let outputDeviceUID: String

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?

    init?(audioObjects: [AudioObjectID], gain: Float, outputDeviceUID: String) {
        guard !audioObjects.isEmpty else { return nil }
        self.audioObjects = audioObjects
        self.gain = min(max(gain, 0), Float(UtilitySupport.maximumAppVolume))
        self.outputDeviceUID = outputDeviceUID

        let tap = CATapDescription(stereoMixdownOfProcesses: audioObjects)
        tap.muteBehavior = .mutedWhenTapped
        tap.isPrivate = true
        guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr, tapID != 0 else { return nil }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacScope App Mixer",
            kAudioAggregateDeviceUIDKey: "local.taskmanager.MacScope.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return nil
        }

        let fixedGain = self.gain
        guard AudioDeviceCreateIOProcIDWithBlock(
            &ioProc, aggregateID, nil
        , { _, input, _, output, _ in
            let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let destinations = UnsafeMutableAudioBufferListPointer(output)
            guard let source = sources.reversed().first(where: {
                $0.mData != nil && $0.mNumberChannels > 0
            }) else { return }
            Self.render(source: source, into: destinations, gain: fixedGain)
        }) == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateID = 0
            tapID = 0
            return nil
        }

        guard AudioDeviceStart(aggregateID, ioProc) == noErr else {
            stop()
            return nil
        }
    }

    func stop() {
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    private static func render(
        source: AudioBuffer,
        into output: UnsafeMutableAudioBufferListPointer,
        gain: Float
    ) {
        guard let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else { return }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let sourceFrames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
        guard sourceFrames > 0 else { return }

        var sourceChannelOffset = 0
        for bufferIndex in output.indices {
            guard let destination = output[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(output[bufferIndex].mNumberChannels), 1)
            let frames = min(
                sourceFrames,
                Int(output[bufferIndex].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            )
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sourceChannel = sourceChannelOffset + channel
                    destination[frame * channels + channel] = sourceChannel < sourceChannels
                        ? sourceData[frame * sourceChannels + sourceChannel] * gain
                        : 0
                }
            }
            sourceChannelOffset += channels
        }
    }
}
