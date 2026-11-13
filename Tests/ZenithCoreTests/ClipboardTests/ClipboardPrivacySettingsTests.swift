import Testing
import Foundation
import AppKit
@testable import ZenithCore

@MainActor
@Suite("Clipboard privacy settings")
struct ClipboardPrivacySettingsTests {

    private func makeDefaults() -> UserDefaults {
        TestDefaults.make("clipboard-privacy-\(UUID().uuidString)")!
    }

    @Test("Defaults: built-in password managers ignored, auto-clear, clear on lock and link cleaning off")
    func testDefaults() {
        let settings = ClipboardPrivacySettings(userDefaults: makeDefaults(), monitor: nil)
        #expect(settings.ignoredAppBundleIdentifiers == ClipboardPrivacySettings.defaultIgnoredApps.map(\.bundleIdentifier))
        #expect(settings.isIgnored(bundleIdentifier: "com.1password.1password"))
        #expect(settings.isIgnored(bundleIdentifier: "COM.BITWARDEN.DESKTOP"))
        #expect(settings.autoClearDelay == .never)
        #expect(settings.clearOnLock == false)
        #expect(settings.cleanLinksOnCopy == false)
        #expect(Set(settings.ignoredAppBundleIdentifiers.map { $0.lowercased() }).count == settings.ignoredAppBundleIdentifiers.count)
    }

    @Test("Every setting is saved and read back")
    func testPersistence() {
        let defaults = makeDefaults()
        let settings = ClipboardPrivacySettings(userDefaults: defaults, monitor: nil)
        settings.autoClearDelay = .fiveMinutes
        settings.clearOnLock = true
        settings.cleanLinksOnCopy = true
        settings.removeIgnoredApp(bundleIdentifier: "com.apple.keychainaccess")
        #expect(settings.addIgnoredApp(bundleIdentifier: "com.example.vault"))

        let reloaded = ClipboardPrivacySettings(userDefaults: defaults, monitor: nil)
        #expect(reloaded.autoClearDelay == .fiveMinutes)
        #expect(reloaded.clearOnLock)
        #expect(reloaded.cleanLinksOnCopy)
        #expect(!reloaded.isIgnored(bundleIdentifier: "com.apple.keychainaccess"))
        #expect(reloaded.ignoredAppBundleIdentifiers.last == "com.example.vault")
    }

    @Test("An emptied list stays empty instead of coming back to the defaults")
    func testEmptyListPersists() {
        let defaults = makeDefaults()
        let settings = ClipboardPrivacySettings(userDefaults: defaults, monitor: nil)
        for id in settings.ignoredAppBundleIdentifiers {
            settings.removeIgnoredApp(bundleIdentifier: id)
        }
        #expect(ClipboardPrivacySettings(userDefaults: defaults, monitor: nil).ignoredAppBundleIdentifiers.isEmpty)
    }

    @Test("Adding refuses empty, spaced and duplicate identifiers (any case)")
    func testAddValidation() {
        let settings = ClipboardPrivacySettings(userDefaults: makeDefaults(), monitor: nil)
        let before = settings.ignoredAppBundleIdentifiers
        #expect(!settings.addIgnoredApp(bundleIdentifier: ""))
        #expect(!settings.addIgnoredApp(bundleIdentifier: "   "))
        #expect(!settings.addIgnoredApp(bundleIdentifier: "com.example two"))
        #expect(!settings.addIgnoredApp(bundleIdentifier: "COM.1PASSWORD.1PASSWORD"))
        #expect(settings.ignoredAppBundleIdentifiers == before)
        #expect(settings.addIgnoredApp(bundleIdentifier: "  com.example.app  "))
        #expect(settings.ignoredAppBundleIdentifiers.last == "com.example.app")
        settings.removeIgnoredApp(bundleIdentifier: "COM.EXAMPLE.APP")
        #expect(settings.ignoredAppBundleIdentifiers == before)
    }

    @Test("A saved list with blanks and duplicates is tidied when read")
    func testLoadDeduplicates() {
        let defaults = makeDefaults()
        defaults.set(["com.a.app", " ", "COM.A.APP", "com.b.app"], forKey: ClipboardPrivacySettings.Keys.ignoredApps)
        let settings = ClipboardPrivacySettings(userDefaults: defaults, monitor: nil)
        #expect(settings.ignoredAppBundleIdentifiers == ["com.a.app", "com.b.app"])
    }

    @Test("An unknown saved delay falls back to never")
    func testUnknownDelay() {
        let defaults = makeDefaults()
        defaults.set(42, forKey: ClipboardPrivacySettings.Keys.autoClearDelay)
        #expect(ClipboardPrivacySettings(userDefaults: defaults, monitor: nil).autoClearDelay == .never)
    }

    @Test("Ignored apps and link cleaning are pushed into the monitor on load and on every change")
    func testSyncsMonitor() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: pasteboard)
        let settings = ClipboardPrivacySettings(userDefaults: makeDefaults(), monitor: monitor)
        #expect(monitor.captureOptions.ignoredBundleIdentifiers.contains("com.1password.1password"))
        #expect(monitor.captureOptions.cleanLinksOnCopy == false)

        settings.cleanLinksOnCopy = true
        settings.addIgnoredApp(bundleIdentifier: "com.Example.Vault")
        #expect(monitor.captureOptions.cleanLinksOnCopy)
        #expect(monitor.captureOptions.ignoredBundleIdentifiers.contains("com.example.vault"))
        settings.removeIgnoredApp(bundleIdentifier: "com.1password.1password")
        #expect(!monitor.captureOptions.ignoredBundleIdentifiers.contains("com.1password.1password"))
    }

    @Test("Reset puts every clipboard privacy setting back")
    func testReset() {
        let settings = ClipboardPrivacySettings(userDefaults: makeDefaults(), monitor: nil)
        settings.autoClearDelay = .tenMinutes
        settings.clearOnLock = true
        settings.cleanLinksOnCopy = true
        settings.removeIgnoredApp(bundleIdentifier: "com.bitwarden.desktop")
        settings.resetToDefaults()
        #expect(settings.autoClearDelay == .never)
        #expect(!settings.clearOnLock)
        #expect(!settings.cleanLinksOnCopy)
        #expect(settings.ignoredAppBundleIdentifiers == ClipboardPrivacySettings.defaultIgnoredApps.map(\.bundleIdentifier))
    }

    @Test("Delay choices: seconds and titles")
    func testDelayChoices() {
        #expect(ClipboardAutoClearDelay.allCases.map(\.seconds) == [nil, 30, 60, 300, 600])
        #expect(ClipboardAutoClearDelay.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(ClipboardPrivacySettings.knownName(for: "COM.APPLE.KEYCHAINACCESS") == "Keychain Access")
        #expect(ClipboardPrivacySettings.knownName(for: "com.example.unknown") == nil)
    }
}
