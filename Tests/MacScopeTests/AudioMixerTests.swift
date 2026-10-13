import CoreAudio
import Foundation
import Testing
@testable import MacScope

@Suite("Audio mixer", .serialized)
struct AudioMixerTests {
    @Test("Audio from a browser helper belongs to its regular parent app")
    func helperAudioBelongsToParentApp() {
        let parents: [pid_t: pid_t] = [102: 101, 101: 100, 100: 1]
        #expect(AudioMixerProcessOwner.resolve(
            pid: 102, regularAppPIDs: [100], ownPID: 200, parentPID: { parents[$0] }
        ) == 100)
    }

    @Test("Owner discovery excludes MacScope helpers and stops on cycles or unknown ancestry")
    func ownerDiscoveryIsBounded() {
        #expect(AudioMixerProcessOwner.resolve(
            pid: 201, regularAppPIDs: [200], ownPID: 200, parentPID: { _ in 200 }
        ) == nil)
        #expect(AudioMixerProcessOwner.resolve(
            pid: 101, regularAppPIDs: [100], ownPID: 200, parentPID: { $0 == 101 ? 102 : 101 }
        ) == nil)
        #expect(AudioMixerProcessOwner.resolve(
            pid: 101, regularAppPIDs: [100], ownPID: 200, parentPID: { _ in nil }
        ) == nil)
    }

    @Test("The shipping bundle declares the process-tap permission purpose")
    func audioCapturePurposeIsDeclared() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let purpose = try #require(plist["NSAudioCaptureUsageDescription"] as? String)
        #expect(!purpose.isEmpty)
    }

    @Test("Closing the last mixer view preserves the user's applied gain") @MainActor
    func closingMixerPreservesGain() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        var engines: [TestAudioGainEngine] = []
        let mixer = fixture.makeMixer { objects, gain, output in
            let engine = TestAudioGainEngine(audioObjects: objects, gain: gain, outputDeviceUID: output)
            engines.append(engine)
            return engine
        }
        defer { mixer.shutdown() }
        mixer.start()
        mixer.setVolume(0.25, for: try #require(mixer.apps.first))

        mixer.stop()

        #expect(engines.count == 1)
        #expect(engines.first?.stopCount == 0)
        #expect(engines.first?.gain == 0.25)
    }

    @Test("Changing gain reuses the active tap rather than recreating hardware") @MainActor
    func gainUpdatesReuseTap() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        var engines: [TestAudioGainEngine] = []
        let mixer = fixture.makeMixer { objects, gain, output in
            let engine = TestAudioGainEngine(audioObjects: objects, gain: gain, outputDeviceUID: output)
            engines.append(engine)
            return engine
        }
        defer { mixer.shutdown() }
        mixer.start()
        let app = try #require(mixer.apps.first)
        mixer.setVolume(0.5, for: app)
        mixer.setVolume(0.25, for: app)

        #expect(engines.count == 1)
        #expect(engines.first?.gain == 0.25)
        mixer.stop()
    }

    @Test("Saved per-app settings resume without opening a mixer view") @MainActor
    func restoresSavedMixing() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        fixture.defaults.set(["test.audio": 0.25], forKey: "utility.perAppVolumes")
        var engines: [TestAudioGainEngine] = []
        let mixer = fixture.makeMixer { objects, gain, output in
            let engine = TestAudioGainEngine(audioObjects: objects, gain: gain, outputDeviceUID: output)
            engines.append(engine)
            return engine
        }
        defer { mixer.shutdown() }

        mixer.restoreMixingPreferences()

        #expect(mixer.isRunning)
        #expect(engines.count == 1)
        #expect(engines.first?.gain == 0.25)
    }

    @Test("Reset releases the tap and background poller after closing the mixer") @MainActor
    func resetReleasesTap() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        let engine = TestAudioGainEngine(audioObjects: [42], gain: 0.25, outputDeviceUID: "test.output")
        let mixer = fixture.makeMixer { _, _, _ in engine }
        defer { mixer.shutdown() }
        mixer.start()
        let app = try #require(mixer.apps.first)
        mixer.setVolume(0.25, for: app)
        mixer.stop()
        #expect(engine.stopCount == 0)

        mixer.setVolume(1, for: app)

        #expect(engine.stopCount == 1)
        #expect(!mixer.isRunning)
    }

    @Test("Command reads do not register unbalanced UI consumers") @MainActor
    func commandReadsDoNotLeakConsumers() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        let mixer = fixture.makeMixer { _, _, _ in nil }
        defer { mixer.shutdown() }

        for _ in 0..<100 { mixer.refreshForCommand() }
        mixer.start()
        mixer.stop()

        #expect(!mixer.isRunning)
    }

    @Test("Mute toggles use current state even when a view holds an older row") @MainActor
    func staleMuteRowStillToggles() throws {
        let fixture = try AudioMixerFixture()
        defer { fixture.remove() }
        let engine = TestAudioGainEngine(audioObjects: [42], gain: 0, outputDeviceUID: "test.output")
        let mixer = fixture.makeMixer { _, _, _ in engine }
        defer { mixer.shutdown() }
        mixer.start()
        let app = try #require(mixer.apps.first)

        mixer.toggleMute(app)
        #expect(mixer.apps.first?.volume == 0)
        #expect(engine.gain == 0)
        mixer.toggleMute(app)

        #expect(mixer.apps.first?.volume == 1)
        #expect(engine.stopCount == 1)
    }

    @Test("The render callback applies live mute, attenuation and boost values")
    func rendersLiveGain() {
        let gain = AudioGainValue(1)
        let source: [Float] = [1, -1, 0.5, -0.5]
        for value: Float in [0, 0.25, 2] {
            gain.value = value
            var output = [Float](repeating: 99, count: source.count)
            source.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    let input = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inputBytes.count),
                                            mData: UnsafeMutableRawPointer(mutating: inputBytes.baseAddress))
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress
                    ))
                    withUnsafeMutablePointer(to: &list) {
                        AudioGainRenderer.render(source: input, into: UnsafeMutableAudioBufferListPointer($0), gain: gain.value)
                    }
                }
            }
            #expect(output == source.map { $0 * value })
        }
    }
}

private final class TestAudioGainEngine: AudioGainEngine {
    let audioObjects: [AudioObjectID]
    var gain: Float
    let outputDeviceUID: String
    var stopCount = 0

    init(audioObjects: [AudioObjectID], gain: Float, outputDeviceUID: String) {
        self.audioObjects = audioObjects
        self.gain = gain
        self.outputDeviceUID = outputDeviceUID
    }

    func setGain(_ value: Float) { gain = value }
    func stop() { stopCount += 1 }
}

@MainActor
private struct AudioMixerFixture {
    let domain = "MacScopeAudioMixerTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws { defaults = try #require(UserDefaults(suiteName: domain)) }
    func remove() { defaults.removePersistentDomain(forName: domain) }

    func makeMixer(
        factory: @escaping @MainActor ([AudioObjectID], Float, String) -> (any AudioGainEngine)?
    ) -> AudioMixerService {
        AudioMixerService(defaults: defaults, inventoryProvider: {
            AudioMixerInventory(apps: [.init(
                id: "test.audio", pid: 123, name: "Audio fixture", bundleIdentifier: "test.audio",
                audioObjects: [42], isPlaying: true, volume: 1, outputDeviceUID: nil
            )], outputs: [.init(id: 43, uid: "test.output", name: "Fixture output", isDefault: true)])
        }, engineFactory: factory)
    }
}
