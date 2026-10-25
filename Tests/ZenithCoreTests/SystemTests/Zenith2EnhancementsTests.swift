import Testing
import Foundation
import AppKit
@testable import ZenithCore

@Suite("Zenith 2.0 Feature Enhancements Test Suite")
struct Zenith2EnhancementsTests {

    // MARK: - 1. Audio Feedback Customization Tests

    @Test("AUD-01: SoundChoice system sound list covers all 14 macOS system sounds")
    func testSoundChoiceSystemSounds() {
        let expectedSounds = [
            "Pop", "Tink", "Hero", "Bottle", "Funk", "Ping", "Purr",
            "Submarine", "Basso", "Blow", "Frog", "Glass", "Morse", "Sosumi"
        ]
        #expect(SoundChoice.standardSystemSounds.count == 14)
        for sound in expectedSounds {
            #expect(SoundChoice.standardSystemSounds.contains(sound))
        }

        #expect(SoundChoice.system(name: "Pop").displayName == "Pop")
        #expect(SoundChoice.muted.displayName == "Muted")
        #expect(SoundChoice.custom(relativePath: "click.wav", displayName: "Click").displayName == "Click")
    }

    @Test("AUD-02: SoundChoice default assignments cover all SoundEffect cases")
    func testSoundChoiceDefaultAssignments() {
        let defaults = SoundChoice.defaultAssignments
        #expect(defaults.count == SoundEffect.allCases.count)
        #expect(defaults[SoundEffect.clipboardCopy.rawValue] == .system(name: "Pop"))
        #expect(defaults[SoundEffect.paste.rawValue] == .system(name: "Tink"))
        #expect(defaults[SoundEffect.capture.rawValue] == .system(name: "Hero"))
        #expect(defaults[SoundEffect.colorSample.rawValue] == .system(name: "Ping"))
        #expect(defaults[SoundEffect.pinToggle.rawValue] == .system(name: "Purr"))
        #expect(defaults[SoundEffect.delete.rawValue] == .system(name: "Basso"))
        #expect(defaults[SoundEffect.error.rawValue] == .system(name: "Basso"))
    }

    @Test("AUD-03: SoundChoice Codable roundtrips all enum variants")
    func testSoundChoiceCodable() throws {
        let choices: [SoundChoice] = [
            .system(name: "Glass"),
            .custom(relativePath: "custom/audio.wav", displayName: "Audio WAV"),
            .muted
        ]
        let data = try JSONEncoder().encode(choices)
        let decoded = try JSONDecoder().decode([SoundChoice].self, from: data)
        #expect(decoded == choices)
    }

    @Test("AUD-04: AudioFeedbackManager routes through custom sound effect assignments")
    func testAudioFeedbackCustomRouting() {
        let suiteName = "test.audio.custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(userDefaults: defaults)

        var customAssignments = SoundChoice.defaultAssignments
        customAssignments[SoundEffect.clipboardCopy.rawValue] = .system(name: "Frog")
        customAssignments[SoundEffect.paste.rawValue] = .muted
        customAssignments[SoundEffect.capture.rawValue] = .custom(relativePath: "custom_shutter.wav", displayName: "Custom Shutter")
        store.soundEffectAssignments = customAssignments

        let mockBackend = MockAudioPlayerBackend()
        let audioManager = AudioFeedbackManager(backend: mockBackend, settingsStore: store, isMuted: false)

        // 1. clipboardCopy should play "Frog" instead of default "Pop"
        audioManager.play(SoundEffect.clipboardCopy)
        #expect(mockBackend.playedSounds.last == "Frog")

        // 2. paste is muted specifically, should produce zero sound
        let countBeforeMute = mockBackend.playedSounds.count
        audioManager.play(SoundEffect.paste)
        #expect(mockBackend.playedSounds.count == countBeforeMute)

        // 3. capture should play "custom_shutter.wav"
        audioManager.play(SoundEffect.capture)
        #expect(mockBackend.playedSounds.last == "custom_shutter.wav")

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 2. DoH Provider Dynamic Re-configuration Tests

    @Test("DOH-01: DoHProvider covers NextDNS and Custom endpoints")
    func testDoHProviderCases() {
        let nextdns = DoHProvider.nextdns(profileID: "xyz987")
        #expect(nextdns.endpointURL.absoluteString == "https://dns.nextdns.io/xyz987")
        #expect(nextdns.directIP == "45.90.28.0")
        #expect(nextdns.displayName.contains("xyz987"))

        let customURL = URL(string: "https://my-custom-doh.com/query")!
        let custom = DoHProvider.custom(url: customURL, bootstrapIP: "1.2.3.4")
        #expect(custom.endpointURL == customURL)
        #expect(custom.directIP == "1.2.3.4")
        #expect(custom.displayName == "Custom DoH")

        let customNoBoot = DoHProvider.custom(url: customURL, bootstrapIP: nil)
        #expect(customNoBoot.directIP == "my-custom-doh.com")

        // NextDNS resilience against user input with spaces
        let nextWithSpace = DoHProvider.nextdns(profileID: "sec profile 99")
        #expect(nextWithSpace.endpointURL.absoluteString == "https://dns.nextdns.io/sec%20profile%2099")
    }

    @Test("DOH-02: DoHProvider Codable handles both new enum structures and legacy strings")
    func testDoHProviderCodableCompatibility() throws {
        // NextDNS variant
        let next = DoHProvider.nextdns(profileID: "corp-dns-42")
        let nextData = try JSONEncoder().encode(next)
        let decNext = try JSONDecoder().decode(DoHProvider.self, from: nextData)
        #expect(decNext == next)

        // Custom variant
        let custom = DoHProvider.custom(url: URL(string: "https://dns.example.com/dns-query")!, bootstrapIP: "10.0.0.1")
        let customData = try JSONEncoder().encode(custom)
        let decCustom = try JSONDecoder().decode(DoHProvider.self, from: customData)
        #expect(decCustom == custom)

        // Legacy string format fallback
        let legacyData = try JSONEncoder().encode("quad9")
        let decLegacy = try JSONDecoder().decode(DoHProvider.self, from: legacyData)
        #expect(decLegacy == .quad9)
    }

    @Test("DOH-03: SettingsStore persists and reloads dohProvider accurately")
    func testSettingsStoreDoHProviderPersistence() {
        let suiteName = "test.doh.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(userDefaults: defaults)

        #expect(store.dohProvider == .cloudflare)

        store.dohProvider = .nextdns(profileID: "sec-profile-9")
        #expect(store.dohProvider == .nextdns(profileID: "sec-profile-9"))

        // Create new store instance from same backing defaults
        let reloadedStore = SettingsStore(userDefaults: defaults)
        #expect(reloadedStore.dohProvider == .nextdns(profileID: "sec-profile-9"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 3. System Cleaner & Mach RAM Telemetry Tests

    @Test("MEM-01: SystemMemoryTelemetry samples valid metrics from Mach kernel")
    func testMachMemorySampler() {
        let telemetry = SystemMemoryTelemetry.current()

        #expect(telemetry.totalBytes > 0)
        #expect(telemetry.usedBytes > 0)
        #expect(telemetry.wiredBytes > 0)
        #expect(telemetry.activeBytes > 0)
        #expect(telemetry.freeBytes > 0)
        #expect(telemetry.usedPercentage > 0.0)
        #expect(telemetry.usedPercentage <= 1.0)
        #expect(!telemetry.formattedTotal.isEmpty)
        #expect(!telemetry.formattedUsed.isEmpty)
        #expect(!telemetry.formattedAvailable.isEmpty)
        #expect(!telemetry.formattedPercentage.isEmpty)
    }

    @Test("MEM-02: SystemCleanerService optimizeMemory flushes caches and returns telemetry")
    @MainActor
    func testSystemCleanerOptimizeMemory() async {
        let cleaner = SystemCleanerService()
        let result = await cleaner.optimizeMemory()

        #expect(result.availableBytes > 0)
        #expect(cleaner.memoryTelemetry != nil)
        #expect(cleaner.isOptimizingMemory == false)
    }

    @Test("MEM-03: Safe directory roots permit Simulator and Gradle caches")
    func testExpandedSafeDirectoryRoots() {
        let home = "/Users/testuser"
        let roots = SystemCleanerService.safeDirectoryRoots(home: home)

        #expect(roots.contains("\(home)/Library/Developer/CoreSimulator/Caches"))
        #expect(roots.contains("\(home)/.gradle/caches"))
        #expect(roots.contains("\(home)/.gradle"))
        #expect(roots.contains("\(home)/Library/Developer/CoreSimulator"))

        // Simulator & Gradle cache subpaths
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Developer/CoreSimulator/Caches/sample.cache", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/.gradle/caches/modules-2/files-2.1/data", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Caches/Google/Chrome/Default/Cache", home: home) == true)

        // Cache base directories themselves are safe to delete
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/.gradle/caches", home: home) == true)
        #expect(SystemCleanerService.isPathSafeForDeletion("\(home)/Library/Developer/CoreSimulator/Caches", home: home) == true)
    }

    // MARK: - 4. Dynamic Island Alert Capsule Tests

    @Test("ISL-04: Dynamic Island geometry alert dimensions and triggerAlert presentation")
    @MainActor
    func testDynamicIslandAlertCapsule() async throws {
        let geometry = ZenithIslandGeometry()
        #expect(geometry.alertWidth == 280)
        #expect(geometry.alertHeight == 36)

        let state = ZenithIslandState()
        #expect(state.activeAlert == nil)

        // Trigger transient alert
        state.triggerAlert(icon: "bolt.fill", title: "RAM Optimized", subtitle: "Freed 1.2 GB")
        #expect(state.activeAlert != nil)
        #expect(state.activeAlert?.icon == "bolt.fill")
        #expect(state.activeAlert?.title == "RAM Optimized")
        #expect(state.activeAlert?.subtitle == "Freed 1.2 GB")
        #expect(state.isRimLightVisible == true)

        // Verify it remains active mid-duration
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(state.activeAlert != nil)

        // Wait for 1.8s auto-dismissal with polling window (prevents flakiness under CI system load)
        let deadline = Date().addingTimeInterval(4.0)
        while state.activeAlert != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(state.activeAlert == nil)
        #expect(!state.isRimLightVisible)
    }

    @Test("ISL-05: Dynamic Island alert supports custom duration and replaces active alert")
    @MainActor
    func testDynamicIslandAlertCustomDurationAndReplacement() async throws {
        let state = ZenithIslandState()

        // 1. Trigger first alert with fast custom duration
        state.triggerAlert(icon: "sparkles", title: "First Alert", duration: 0.1)
        #expect(state.activeAlert?.title == "First Alert")

        // 2. Trigger second alert immediately; should replace first
        state.triggerAlert(icon: "bell.fill", title: "Second Alert", duration: 0.1)
        #expect(state.activeAlert?.title == "Second Alert")

        // 3. Wait for auto-dismissal
        let deadline = Date().addingTimeInterval(2.0)
        while state.activeAlert != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.activeAlert == nil)
        #expect(!state.isRimLightVisible)
    }
}
