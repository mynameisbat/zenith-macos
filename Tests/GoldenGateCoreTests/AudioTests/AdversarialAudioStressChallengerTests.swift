import Testing
import Foundation
import AppKit
import AVFoundation
@testable import GoldenGateCore

@Suite("Adversarial Audio Latency, Concurrency & Bit-Level WAV Challenger Suite")
struct AdversarialAudioStressChallengerTests {

    // MARK: - Helpers

    private func makeIsolatedStore(soundEffectsEnabled: Bool = true) -> (SettingsStore, String) {
        let suiteName = "ChallengerAudio_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(soundEffectsEnabled, forKey: SettingsStore.Keys.soundEffectsEnabled)
        let store = SettingsStore(userDefaults: defaults)
        return (store, suiteName)
    }

    private func readUInt16LE(from data: Data, at offset: Int) -> UInt16 {
        let sub = data.subdata(in: offset..<(offset + 2))
        return sub.withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    private func readUInt32LE(from data: Data, at offset: Int) -> UInt32 {
        let sub = data.subdata(in: offset..<(offset + 4))
        return sub.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    private func readInt16LE(from data: Data, at offset: Int) -> Int16 {
        let sub = data.subdata(in: offset..<(offset + 2))
        return sub.withUnsafeBytes { $0.load(as: Int16.self) }
    }

    // MARK: - 1. Caller Latency SLA Verification (<10ms for 100 calls, <0.1ms/call)

    @Test("Adversarial SLA: 100 consecutive triggers on MockAudioPlayerBackend in <10ms (<0.1ms/call)")
    func testCallerLatencySLAMockBackend() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        var durationsNanoseconds: [UInt64] = []
        durationsNanoseconds.reserveCapacity(100)

        let overallStart = DispatchTime.now()
        for _ in 0..<100 {
            let callStart = DispatchTime.now()
            audioManager.playNewCopySound()
            let callEnd = DispatchTime.now()
            durationsNanoseconds.append(callEnd.uptimeNanoseconds - callStart.uptimeNanoseconds)
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0

        let sorted = durationsNanoseconds.sorted()
        let minMs = Double(sorted.first!) / 1_000_000.0
        let maxMs = Double(sorted.last!) / 1_000_000.0
        let avgMs = totalElapsedMs / 100.0
        let p95Ms = Double(sorted[94]) / 1_000_000.0

        print("[Challenger Latency SLA - Mock] Total: \(String(format: "%.3f", totalElapsedMs))ms | Avg: \(String(format: "%.4f", avgMs))ms | Min: \(String(format: "%.4f", minMs))ms | P95: \(String(format: "%.4f", p95Ms))ms | Max: \(String(format: "%.4f", maxMs))ms")

        #expect(totalElapsedMs < 10.0, "Total 100-call trigger latency must be < 10ms")
        #expect(avgMs < 0.1, "Average per-call caller latency must be < 0.1ms")
        #expect(mockBackend.playedSounds.count == 100)
    }

    @Test("Adversarial SLA: 100 consecutive triggers on Production NSSoundPlayerBackend in <10ms (<0.1ms/call)")
    func testCallerLatencySLANSSoundProductionBackend() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let backend = NSSoundPlayerBackend.shared
        let audioManager = AudioFeedbackManager(backend: backend, settingsStore: store, isMuted: false)

        var durationsNanoseconds: [UInt64] = []
        durationsNanoseconds.reserveCapacity(100)

        let overallStart = DispatchTime.now()
        for _ in 0..<100 {
            let callStart = DispatchTime.now()
            audioManager.playShutterSound()
            let callEnd = DispatchTime.now()
            durationsNanoseconds.append(callEnd.uptimeNanoseconds - callStart.uptimeNanoseconds)
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0

        let sorted = durationsNanoseconds.sorted()
        let minMs = Double(sorted.first!) / 1_000_000.0
        let maxMs = Double(sorted.last!) / 1_000_000.0
        let avgMs = totalElapsedMs / 100.0
        let p95Ms = Double(sorted[94]) / 1_000_000.0

        print("[Challenger Latency SLA - NSSound] Total: \(String(format: "%.3f", totalElapsedMs))ms | Avg: \(String(format: "%.4f", avgMs))ms | Min: \(String(format: "%.4f", minMs))ms | P95: \(String(format: "%.4f", p95Ms))ms | Max: \(String(format: "%.4f", maxMs))ms")

        #expect(totalElapsedMs < 10.0, "Total 100-call trigger latency on NSSound backend must be < 10ms without blocking caller")
        #expect(avgMs < 0.1, "Average per-call caller latency on NSSound backend must be < 0.1ms")
        backend.stopAll()
    }

    @Test("Adversarial SLA: 100 consecutive triggers while MUTED execute near-instantly (<2ms total, <0.02ms/call)")
    func testCallerLatencySLAMutedEarlyExit() {
        let (store, suite) = makeIsolatedStore(soundEffectsEnabled: false)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: true)

        let overallStart = DispatchTime.now()
        for _ in 0..<100 {
            audioManager.playNewCopySound()
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0
        let avgMs = totalElapsedMs / 100.0

        print("[Challenger Latency SLA - Muted] Total: \(String(format: "%.3f", totalElapsedMs))ms | Avg: \(String(format: "%.4f", avgMs))ms")

        #expect(totalElapsedMs < 2.0, "Muted 100-call trigger must short-circuit in < 2ms")
        #expect(avgMs < 0.02, "Muted per-call latency must be < 0.02ms")
        #expect(mockBackend.playedSounds.isEmpty)
        #expect(audioManager.totalPlayedCount == 0)
    }

    @Test("Adversarial SLA: 100 calls rotating across all 7 semantic sound effects complete in <10ms")
    func testCallerLatencySLAMixedSemanticEffects() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)
        let allEffects = SoundEffect.allCases

        let overallStart = DispatchTime.now()
        for i in 0..<100 {
            audioManager.play(allEffects[i % allEffects.count])
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0
        let avgMs = totalElapsedMs / 100.0

        print("[Challenger Latency SLA - Mixed Effects] Total: \(String(format: "%.3f", totalElapsedMs))ms | Avg: \(String(format: "%.4f", avgMs))ms")

        #expect(totalElapsedMs < 10.0)
        #expect(avgMs < 0.1)
        #expect(mockBackend.playedSounds.count == 100)
    }

    // MARK: - 2. 50+ Concurrent Asynchronous Playback Calls Hammering Audio Manager

    @Test("Adversarial Concurrency: 75 concurrent async tasks hammering MockAudioPlayerBackend (750 total calls)")
    func testConcurrentHammering75TasksMockBackend() async {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<75 {
                group.addTask {
                    for callId in 0..<10 {
                        let step = (taskId + callId) % 3
                        switch step {
                        case 0: audioManager.playNewCopySound()
                        case 1: audioManager.playPasteSound()
                        default: audioManager.playShutterSound()
                        }
                    }
                }
            }
        }

        #expect(mockBackend.playedSounds.count == 750)
        #expect(audioManager.totalPlayedCount == 750)
    }

    @Test("Adversarial Concurrency: 100 concurrent async tasks hammering NSSoundPlayerBackend without crash or deadlock")
    func testConcurrentHammering100TasksNSSoundBackend() async {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let backend = NSSoundPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: backend, settingsStore: store, isMuted: false)
        let allEffects = SoundEffect.allCases

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<100 {
                group.addTask {
                    let effect = allEffects[taskId % allEffects.count]
                    audioManager.play(effect)
                    if taskId % 25 == 0 {
                        audioManager.stopAll()
                    }
                }
            }
        }

        #expect(audioManager.totalPlayedCount == 100)
        backend.stopAll()
    }

    @Test("Adversarial Concurrency: High contention with interleaved volume, mute, stopAll and 60 hammering tasks")
    func testHighContentionInterleavedStateAndPlayback() async {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            // 40 Playback tasks
            for taskId in 0..<40 {
                group.addTask {
                    for i in 0..<15 {
                        if (taskId + i) % 2 == 0 {
                            audioManager.playNewCopySound()
                        } else {
                            audioManager.playPasteSound()
                        }
                    }
                }
            }
            // 10 Volume adjustment tasks
            for v in 0..<10 {
                group.addTask {
                    audioManager.volume = Float(v) / 10.0
                }
            }
            // 10 StopAll tasks
            for _ in 0..<10 {
                group.addTask {
                    audioManager.stopAll()
                }
            }
        }

        #expect(mockBackend.stopAllCount == 10)
        #expect(audioManager.totalPlayedCount == mockBackend.playedSounds.count)
        #expect(mockBackend.playedSounds.count == 600)
    }

    // MARK: - 3. Rapid Mute Toggle Flipping During Active Playback Bursts

    @Test("Adversarial Mute Bursts: Alternating unmuted/muted bursts confirm 100% suppression and clean resumption")
    func testMuteToggleBurstsCleanSuppressionAndResumption() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        // Burst 1: Unmuted (50 triggers)
        for _ in 0..<50 { audioManager.playNewCopySound() }
        #expect(mockBackend.playedSounds.count == 50)
        #expect(audioManager.totalPlayedCount == 50)

        // Burst 2: Muted (50 triggers -> 0 played)
        audioManager.isMuted = true
        for _ in 0..<50 { audioManager.playPasteSound() }
        #expect(mockBackend.playedSounds.count == 50, "Suppression must be 100% when isMuted = true")
        #expect(audioManager.totalPlayedCount == 50)

        // Burst 3: Unmuted (50 triggers -> 50 played, total 100)
        audioManager.isMuted = false
        for _ in 0..<50 { audioManager.playShutterSound() }
        #expect(mockBackend.playedSounds.count == 100, "Playback must immediately resume when isMuted = false")
        #expect(audioManager.totalPlayedCount == 100)

        // Burst 4: Muted (50 triggers -> 0 played, total remains 100)
        audioManager.isMuted = true
        for _ in 0..<50 { audioManager.playNewCopySound() }
        #expect(mockBackend.playedSounds.count == 100)
        #expect(audioManager.totalPlayedCount == 100)

        // Burst 5: Unmuted (50 triggers -> 50 played, total 150)
        audioManager.isMuted = false
        for _ in 0..<50 { audioManager.playPasteSound() }
        #expect(mockBackend.playedSounds.count == 150)
        #expect(audioManager.totalPlayedCount == 150)
    }

    @Test("Adversarial Mute Toggle: High-frequency alternating loop (100 toggle cycles)")
    func testHighFrequencyMuteToggleLoop() {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        for _ in 0..<100 {
            // Mute and fire -> must be suppressed
            audioManager.isMuted = true
            audioManager.playNewCopySound()

            // Unmute and fire -> must be played
            audioManager.isMuted = false
            audioManager.playNewCopySound()
        }

        #expect(mockBackend.playedSounds.count == 100)
        #expect(audioManager.totalPlayedCount == 100)
    }

    @Test("Adversarial Mute Toggle: Concurrent torture test with 30 trigger tasks and 20 toggle tasks")
    func testConcurrentMuteTogglingStressInvariants() async {
        let (store, suite) = makeIsolatedStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        await withTaskGroup(of: Void.self) { group in
            // 30 Playback tasks: 20 sounds each = 600 total triggers
            for _ in 0..<30 {
                group.addTask {
                    for _ in 0..<20 {
                        audioManager.playNewCopySound()
                    }
                }
            }
            // 20 Mute flipping tasks: 15 flips each
            for taskId in 0..<20 {
                group.addTask {
                    for i in 0..<15 {
                        audioManager.isMuted = ((taskId + i) % 2 == 0)
                    }
                }
            }
        }

        // Strict invariant check: internal count MUST equal backend received count
        #expect(audioManager.totalPlayedCount == mockBackend.playedSounds.count)
        #expect(audioManager.totalPlayedCount <= 600)
    }

    @Test("Adversarial SettingsStore Sync: Dynamic soundEffectsEnabled toggle bursts via UserDefaults")
    func testSettingsStoreSoundEffectsEnabledSyncBursts() {
        let suiteName = "ChallengerAudioSync_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: defaults)
        store.soundEffectsEnabled = true

        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store)

        // Phase 1: Enabled
        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 1)

        // Phase 2: Disabled in Store
        store.soundEffectsEnabled = false
        #expect(audioManager.isMuted == true)
        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 1)

        // Phase 3: Enabled in Store
        store.soundEffectsEnabled = true
        #expect(audioManager.isMuted == false)
        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 2)

        // Phase 4: Reset to defaults (restores soundEffectsEnabled = true)
        store.soundEffectsEnabled = false
        #expect(audioManager.isMuted == true)
        store.resetToDefaults()
        #expect(store.soundEffectsEnabled == true)
        #expect(audioManager.isMuted == false)
        audioManager.playNewCopySound()
        #expect(mockBackend.playedSounds.count == 3)
    }

    // MARK: - 4. Synthetic Sound Generator: Bit-Level RIFF WAV Header & PCM Integrity

    @Test("Adversarial WAV: Bit-level RIFF WAV 44.1kHz 16-bit PCM Mono header field verification")
    func testWAVHeaderBitLevelStructure() {
        let sampleRate = 44100
        let duration = 0.05
        let frequency = 1000.0
        let wav = SyntheticSoundGenerator.generateWAV(frequency: frequency, duration: duration, sampleRate: sampleRate)

        let numSamples = Int(Double(sampleRate) * duration) // 2205
        let expectedTotalBytes = 44 + numSamples * 2 // 4454

        #expect(wav.count == expectedTotalBytes)

        // 1. ChunkID: "RIFF" (bytes 0..3)
        let chunkID = String(decoding: wav.subdata(in: 0..<4), as: UTF8.self)
        #expect(chunkID == "RIFF")

        // 2. ChunkSize: TotalBytes - 8 (bytes 4..7)
        let chunkSize = readUInt32LE(from: wav, at: 4)
        #expect(chunkSize == UInt32(expectedTotalBytes - 8))

        // 3. Format: "WAVE" (bytes 8..11)
        let format = String(decoding: wav.subdata(in: 8..<12), as: UTF8.self)
        #expect(format == "WAVE")

        // 4. Subchunk1ID: "fmt " (bytes 12..15)
        let subchunk1ID = String(decoding: wav.subdata(in: 12..<16), as: UTF8.self)
        #expect(subchunk1ID == "fmt ")

        // 5. Subchunk1Size: 16 for PCM (bytes 16..19)
        let subchunk1Size = readUInt32LE(from: wav, at: 16)
        #expect(subchunk1Size == 16)

        // 6. AudioFormat: 1 for PCM (bytes 20..21)
        let audioFormat = readUInt16LE(from: wav, at: 20)
        #expect(audioFormat == 1)

        // 7. NumChannels: 1 for Mono (bytes 22..23)
        let numChannels = readUInt16LE(from: wav, at: 22)
        #expect(numChannels == 1)

        // 8. SampleRate: 44100 (bytes 24..27)
        let sRate = readUInt32LE(from: wav, at: 24)
        #expect(sRate == 44100)

        // 9. ByteRate: 88200 (SampleRate * NumChannels * BitsPerSample / 8) (bytes 28..31)
        let byteRate = readUInt32LE(from: wav, at: 28)
        #expect(byteRate == 44100 * 1 * 16 / 8)

        // 10. BlockAlign: 2 (NumChannels * BitsPerSample / 8) (bytes 32..33)
        let blockAlign = readUInt16LE(from: wav, at: 32)
        #expect(blockAlign == 2)

        // 11. BitsPerSample: 16 (bytes 34..35)
        let bitsPerSample = readUInt16LE(from: wav, at: 34)
        #expect(bitsPerSample == 16)

        // 12. Subchunk2ID: "data" (bytes 36..39)
        let subchunk2ID = String(decoding: wav.subdata(in: 36..<40), as: UTF8.self)
        #expect(subchunk2ID == "data")

        // 13. Subchunk2Size: numSamples * 2 (bytes 40..43)
        let subchunk2Size = readUInt32LE(from: wav, at: 40)
        #expect(subchunk2Size == UInt32(numSamples * 2))
    }

    @Test("Adversarial WAV: PCM sample range, waveform non-zeroness, and exponential decay verification")
    func testWAVSampleIntegrityAndDecayEnvelope() {
        let sampleRate = 44100
        let duration = 0.05
        let frequency = 800.0
        let wav = SyntheticSoundGenerator.generateWAV(frequency: frequency, duration: duration, sampleRate: sampleRate)
        let numSamples = Int(Double(sampleRate) * duration)

        var samples: [Int16] = []
        samples.reserveCapacity(numSamples)

        for i in 0..<numSamples {
            let offset = 44 + (i * 2)
            let sample = readInt16LE(from: wav, at: offset)
            samples.append(sample)
        }

        // 1. Verify samples fit within 16-bit PCM amplitude bounds [-20000, 20000]
        let maxSample = samples.max() ?? 0
        let minSample = samples.min() ?? 0
        #expect(maxSample <= 20000, "Peak positive amplitude should not exceed 20000")
        #expect(minSample >= -20000, "Peak negative amplitude should not exceed -20000")
        #expect(maxSample > 10000, "Peak amplitude should be active (> 10000)")

        // 2. Verify decay envelope: Head RMS vs Tail RMS
        let headCount = numSamples / 5
        let tailCount = numSamples / 5

        let headSamples = samples.prefix(headCount).map { Double($0) }
        let tailSamples = samples.suffix(tailCount).map { Double($0) }

        let headRMS = sqrt(headSamples.reduce(0.0) { $0 + ($1 * $1) } / Double(headCount))
        let tailRMS = sqrt(tailSamples.reduce(0.0) { $0 + ($1 * $1) } / Double(tailCount))

        print("[Challenger WAV Decay] Head RMS: \(String(format: "%.1f", headRMS)), Tail RMS: \(String(format: "%.1f", tailRMS))")
        #expect(headRMS > tailRMS * 3.0, "Decay envelope must attenuate signal by > 3x from head to tail")
    }

    @Test("Adversarial WAV: All 7 SoundEffect generators produce decodable audio for native NSSound & AVAudioPlayer")
    func testAllSoundEffectCasesNativeAudioDecodability() throws {
        for effect in SoundEffect.allCases {
            let data = SyntheticSoundGenerator.data(for: effect)
            #expect(!data.isEmpty)
            #expect(data.count > 44)

            // Test NSSound decodability
            let nsSound = NSSound(data: data)
            #expect(nsSound != nil, "NSSound must successfully decode synthetic data for \(effect.rawValue)")
            if let nsSound = nsSound {
                #expect(nsSound.duration > 0.0)
            }

            // Test AVAudioPlayer decodability & format properties
            do {
                let avPlayer = try AVAudioPlayer(data: data)
                #expect(avPlayer.format.sampleRate == 44100.0, "AVAudioPlayer sampleRate must be 44.1kHz")
                #expect(avPlayer.format.channelCount == 1, "AVAudioPlayer channelCount must be 1 (Mono)")
                #expect(avPlayer.duration > 0.0)
            } catch {
                Issue.record("AVAudioPlayer failed to decode synthetic WAV for \(effect.rawValue): \(error)")
            }
        }
    }

    @Test("Adversarial WAV: Boundary conditions (zero duration, negative duration, extreme sample rates)")
    func testWAVBoundaryConditions() {
        // Zero duration: numSamples clamped to max(1, 0) = 1
        let zeroWav = SyntheticSoundGenerator.generateWAV(frequency: 1000.0, duration: 0.0)
        #expect(zeroWav.count == 44 + 2) // 44 byte header + 1 sample (2 bytes)
        #expect(readUInt32LE(from: zeroWav, at: 40) == 2)

        // Negative duration: numSamples clamped to max(1, negative) = 1
        let negWav = SyntheticSoundGenerator.generateWAV(frequency: 1000.0, duration: -0.5)
        #expect(negWav.count == 44 + 2)

        // High sample rate (96kHz)
        let highRateWav = SyntheticSoundGenerator.generateWAV(frequency: 440.0, duration: 0.01, sampleRate: 96000)
        #expect(readUInt32LE(from: highRateWav, at: 24) == 96000)
        #expect(readUInt32LE(from: highRateWav, at: 28) == 96000 * 2)

        // Fallback for unrecognized sound name
        let fallbackWav = SyntheticSoundGenerator.data(for: "non_existent_sound_name_xyz")
        #expect(!fallbackWav.isEmpty)
        #expect(fallbackWav.count > 44)
    }
}
