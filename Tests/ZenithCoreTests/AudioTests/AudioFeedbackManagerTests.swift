import Testing
import Foundation
@testable import ZenithCore

@Suite("AudioFeedbackManager Playback & Concurrency Test Suite")
struct AudioFeedbackManagerTests {

    @Test("Plays distinct cues for all sound types when unmuted")
    func testSoundTypePlayback() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.last == "Pop")

        audioManager.playPasteSound()
        #expect(mockBackend.playedSounds.last == "Tink")

        audioManager.playShutterSound()
        #expect(mockBackend.playedSounds.last == "Hero")

        #expect(mockBackend.playedSounds.count == 3)
        #expect(audioManager.totalPlayedCount == 3)
        #expect(audioManager.lastPlayedSound == "Hero")
    }

    @Test("Mute suppresses all audio playback calls")
    func testMuteSuppression() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: true)

        audioManager.playNewCopySound()
        audioManager.playPasteSound()
        audioManager.playShutterSound()

        #expect(mockBackend.playedSounds.isEmpty)
        #expect(mockBackend.playRequestCount == 0)
        #expect(audioManager.totalPlayedCount == 0)
    }

    @Test("Dynamic mute toggling immediately suppresses and restores audio cues")
    func testDynamicMuteToggling() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 1)

        audioManager.isMuted = true
        audioManager.playPasteSound()
        #expect(mockBackend.playedSounds.count == 1) // Suppressed

        audioManager.isMuted = false
        audioManager.playShutterSound()
        #expect(mockBackend.playedSounds.count == 2)
    }

    @Test("Volume clamps strictly between 0.0 and 1.0")
    func testVolumeClamping() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend)

        audioManager.volume = -0.5
        #expect(audioManager.volume == 0.0)

        audioManager.volume = 1.5
        #expect(audioManager.volume == 1.0)

        audioManager.volume = 0.65
        #expect(audioManager.volume == 0.65)
    }

    @Test("Dynamic mute sync with SettingsStore")
    func testSettingsStoreSync() {
        let suiteName = "test.audio.sync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(userDefaults: defaults)
        store.soundEffectsEnabled = true

        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store)

        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 1)

        store.soundEffectsEnabled = false
        #expect(audioManager.isMuted == true)

        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 1) // Suppressed!

        store.soundEffectsEnabled = true
        #expect(audioManager.isMuted == false)

        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 2) // Restored!

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("SyntheticSoundGenerator generates valid RIFF WAV audio data")
    func testSyntheticSoundGeneration() {
        let wav = SyntheticSoundGenerator.generateWAV(frequency: 1000.0, duration: 0.05)
        #expect(wav.count > 44)

        // Check "RIFF" signature
        let riffHeader = String(decoding: wav.prefix(4), as: UTF8.self)
        #expect(riffHeader == "RIFF")

        // Check format chunk
        let formatHeader = String(decoding: wav.subdata(in: 8..<16), as: UTF8.self)
        #expect(formatHeader == "WAVEfmt ")
    }

    @Test("SyntheticSoundGenerator generates audio data for all SoundEffect cases")
    func testSyntheticSoundGeneratorCases() {
        for effect in SoundEffect.allCases {
            let data = SyntheticSoundGenerator.data(for: effect)
            #expect(!data.isEmpty)
            #expect(data.count > 44)
        }
    }

    @Test("Plays semantic sound effects cues accurately")
    func testSemanticSoundEffectsPlayback() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        audioManager.play(SoundEffect.colorSample)
        #expect(mockBackend.playedSounds.last == "Ping")

        audioManager.play(SoundEffect.pinToggle)
        #expect(mockBackend.playedSounds.last == "Purr")

        audioManager.play(SoundEffect.delete)
        #expect(mockBackend.playedSounds.last == "Basso")

        audioManager.play(SoundEffect.error)
        #expect(mockBackend.playedSounds.last == "Basso")
    }

    @Test("Stop all forwards command to backend")
    func testStopAllForwarding() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend)

        audioManager.stopAll()
        #expect(mockBackend.stopAllCount == 1)
    }

    @Test("Handles 50 concurrent dispatch tasks without data race or crash")
    func testConcurrentDispatch50Tasks() async {
        let mockBackend = MockAudioPlayerBackend()
        let isolatedDefaults = UserDefaults(suiteName: "isolated_afm_\(UUID().uuidString)")!
        let store = SettingsStore(userDefaults: isolatedDefaults)
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    switch i % 3 {
                    case 0: audioManager.playNewCopySound()
                    case 1: audioManager.playPasteSound()
                    default: audioManager.playShutterSound()
                    }
                }
            }
        }

        #expect(mockBackend.playedSounds.count == 50)
    }

    @Test("Handles concurrent mute toggling during rapid playback without crash")
    func testConcurrentMuteTogglingStress() async {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    audioManager.playNewCopySound()
                }
            }
            for i in 0..<10 {
                group.addTask {
                    audioManager.isMuted = (i % 2 == 0)
                }
            }
        }

        #expect(mockBackend.playedSounds.count <= 50)
    }

    @Test("Caller latency benchmark: 100 consecutive sound triggers execute in under 10ms")
    func testNonBlockingPerformanceSLA() {
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, isMuted: false)

        let start = DispatchTime.now()
        for _ in 0..<100 {
            audioManager.playNewCopySound()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0 // in ms

        #expect(elapsed < 10.0)
        #expect(mockBackend.playedSounds.count == 100)
    }

    @Test("Production NSSoundPlayerBackend smoke test executes safely")
    func testProductionNSSoundBackendSmoke() {
        let backend = NSSoundPlayerBackend.shared
        let success = backend.playSound(named: "Pop", volume: 1.0)
        #expect(success == true)
        backend.stopAll()
    }
}
