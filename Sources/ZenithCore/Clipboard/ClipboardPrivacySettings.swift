import Foundation
import Combine

/// How long after a copy the system clipboard is emptied.
public enum ClipboardAutoClearDelay: Int, Sendable, CaseIterable, Identifiable {
    case never = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    public var id: Int { rawValue }

    /// Seconds to wait, or nil when the clipboard is never cleared.
    public var seconds: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue)
    }

    public var title: String {
        switch self {
        case .never: return String(localized: "Never")
        case .thirtySeconds: return String(localized: "After 30 Seconds")
        case .oneMinute: return String(localized: "After 1 Minute")
        case .fiveMinutes: return String(localized: "After 5 Minutes")
        case .tenMinutes: return String(localized: "After 10 Minutes")
        }
    }
}

/// A password manager (or similar) whose copies are not kept by default.
public struct ClipboardIgnoredAppDefault: Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String
}

/// The clipboard's privacy settings: ignored apps, clearing the clipboard, cleaning copied links. Saved in
/// `UserDefaults`. Every change is pushed into the pasteboard monitor, which applies it to the next copy.
@MainActor
public final class ClipboardPrivacySettings: ObservableObject {
    public static let shared = ClipboardPrivacySettings()

    public enum Keys {
        public static let ignoredApps = "zenith_clipboard_ignored_apps"
        public static let autoClearDelay = "zenith_clipboard_auto_clear_seconds"
        public static let clearOnLock = "zenith_clipboard_clear_on_lock"
        public static let cleanLinksOnCopy = "zenith_clipboard_clean_links_on_copy"
    }

    /// Ignored out of the box: password managers that do not all mark their copies as concealed.
    public static let defaultIgnoredApps: [ClipboardIgnoredAppDefault] = [
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.1password.1password", name: "1Password"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.agilebits.onepassword7", name: "1Password 7"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.bitwarden.desktop", name: "Bitwarden"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "org.keepassxc.keepassxc", name: "KeePassXC"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.hicknhacksoftware.MacPass", name: "MacPass"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.apple.keychainaccess", name: "Keychain Access"),
        ClipboardIgnoredAppDefault(bundleIdentifier: "com.apple.Passwords", name: "Passwords")
    ]

    /// Bundle identifiers of apps whose copies are not kept, in the order they were added.
    @Published public private(set) var ignoredAppBundleIdentifiers: [String] {
        didSet { save(ignoredAppBundleIdentifiers, Keys.ignoredApps); syncMonitor() }
    }

    /// Empty the system clipboard this long after a copy (if it still holds that copy). Off by default.
    @Published public var autoClearDelay: ClipboardAutoClearDelay {
        didSet { save(autoClearDelay.rawValue, Keys.autoClearDelay) }
    }

    /// Empty the system clipboard when the screen locks or the Mac goes to sleep. Off by default.
    @Published public var clearOnLock: Bool {
        didSet { save(clearOnLock, Keys.clearOnLock) }
    }

    /// Rewrite a copied web link without its tracking parameters. Off by default.
    @Published public var cleanLinksOnCopy: Bool {
        didSet { save(cleanLinksOnCopy, Keys.cleanLinksOnCopy); syncMonitor() }
    }

    private let userDefaults: UserDefaults
    private weak var monitor: PasteboardMonitor?

    public init(userDefaults: UserDefaults = .standard, monitor: PasteboardMonitor? = .shared) {
        self.userDefaults = userDefaults
        self.monitor = monitor
        if let saved = userDefaults.array(forKey: Keys.ignoredApps) as? [String] {
            self.ignoredAppBundleIdentifiers = Self.deduplicated(saved)
        } else {
            self.ignoredAppBundleIdentifiers = Self.defaultIgnoredApps.map(\.bundleIdentifier)
        }
        let seconds = userDefaults.object(forKey: Keys.autoClearDelay) as? Int ?? 0
        self.autoClearDelay = ClipboardAutoClearDelay(rawValue: seconds) ?? .never
        self.clearOnLock = userDefaults.object(forKey: Keys.clearOnLock) as? Bool ?? false
        self.cleanLinksOnCopy = userDefaults.object(forKey: Keys.cleanLinksOnCopy) as? Bool ?? false
        syncMonitor()
    }

    /// What the pasteboard monitor applies to each copy.
    public var captureOptions: ClipboardCaptureOptions {
        ClipboardCaptureOptions(
            ignoredBundleIdentifiers: Set(ignoredAppBundleIdentifiers),
            cleanLinksOnCopy: cleanLinksOnCopy
        )
    }

    public func isIgnored(bundleIdentifier: String) -> Bool {
        let key = bundleIdentifier.lowercased()
        return ignoredAppBundleIdentifiers.contains { $0.lowercased() == key }
    }

    /// Adds an app to the ignored list. Returns false for an empty identifier or one already there (any case).
    @discardableResult
    public func addIgnoredApp(bundleIdentifier: String) -> Bool {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), !isIgnored(bundleIdentifier: trimmed) else {
            return false
        }
        ignoredAppBundleIdentifiers.append(trimmed)
        return true
    }

    public func removeIgnoredApp(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        ignoredAppBundleIdentifiers.removeAll { $0.lowercased() == key }
    }

    /// The name Zenith knows for a built-in entry, for when the app is not installed.
    public static func knownName(for bundleIdentifier: String) -> String? {
        let key = bundleIdentifier.lowercased()
        return defaultIgnoredApps.first { $0.bundleIdentifier.lowercased() == key }?.name
    }

    public func resetToDefaults() {
        ignoredAppBundleIdentifiers = Self.defaultIgnoredApps.map(\.bundleIdentifier)
        autoClearDelay = .never
        clearOnLock = false
        cleanLinksOnCopy = false
    }

    private static func deduplicated(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in identifiers {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func save(_ value: Any, _ key: String) {
        userDefaults.set(value, forKey: key)
    }

    private func syncMonitor() {
        monitor?.captureOptions = captureOptions
    }
}
