import Foundation
import SwiftUI
import Combine
import ZenithCore

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case audio = "Audio"
    case island = "Dynamic Island"
    case snippets = "Snippets"
    case privacy = "Privacy"
    case ports = "Ports"
    case cleaner = "Cleaner"
    case permissions = "Permissions"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .audio: return "speaker.wave.2.fill"
        case .island: return "capsule.fill"
        case .snippets: return "text.badge.plus"
        case .privacy: return "lock.shield.fill"
        case .ports: return "network"
        case .cleaner: return "sparkles"
        case .permissions: return "hand.raised.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .general: return "Startup & History"
        case .shortcuts: return "Global Hotkeys"
        case .audio: return "Sound Feedback"
        case .island: return "Widgets & Timer"
        case .snippets: return "Text Expansion"
        case .privacy: return "Encrypted DNS"
        case .ports: return "Listening Processes"
        case .cleaner: return "Caches & Junk"
        case .permissions: return "Screen & Access"
        }
    }

    /// The name shown in the sidebar and as the pane title.
    public var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .shortcuts: return String(localized: "Shortcuts")
        case .audio: return String(localized: "Audio")
        case .island: return String(localized: "Dynamic Island")
        case .snippets: return String(localized: "Snippets")
        case .privacy: return String(localized: "Privacy Shield")
        case .ports: return String(localized: "Ports")
        case .cleaner: return String(localized: "Cleaner")
        case .permissions: return String(localized: "Permissions")
        }
    }

    /// Extra words the sidebar search finds the tab by.
    public var searchKeywords: [String] {
        switch self {
        case .general: return ["login", "startup", "clipboard", "history", "reset"]
        case .shortcuts: return ["hotkey", "keyboard", "keys"]
        case .audio: return ["sound", "volume"]
        case .island: return ["notch", "timer", "pomodoro", "focus", "calendar", "event", "widget"]
        case .snippets: return ["snippet", "text", "expansion", "abbreviation", "trigger", "template"]
        case .privacy: return ["dns", "doh", "proxy", "shield"]
        case .ports: return ["port", "listen", "lsof", "server", "localhost", "kill", "process"]
        case .cleaner: return ["junk", "cache", "disk", "storage", "uninstall"]
        case .permissions: return ["accessibility", "screen recording", "automation", "calendar"]
        }
    }

    public var sectionTitle: String {
        switch self {
        case .general, .shortcuts, .audio, .island, .snippets:
            return "WORKSPACE"
        case .privacy, .ports, .cleaner, .permissions:
            return "SYSTEM & SECURITY"
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var selectedTab: SettingsTab = .general
    @Published public var hoveredTab: SettingsTab? = nil
    @Published public var isCloseHovered: Bool = false
    @Published public var searchText: String = ""
    @Published public var launchAtLoginError: String? = nil
    @Published public var screenRecordingGranted: Bool = false
    @Published public var accessibilityGranted: Bool = false
    @Published public var shortcutConflictError: String? = nil
    @Published public var showClearConfirmation: Bool = false
    @Published public var customSounds: [SoundChoice] = []

    public let store: SettingsStore
    public let launchAtLoginService: LaunchAtLoginServiceProtocol
    public let permissionsService: PermissionsServiceProtocol
    public let hotKeys: HotKeyConfigurator
    public var onClearHistoryRequest: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    public init(
        store: SettingsStore = .shared,
        launchAtLoginService: LaunchAtLoginServiceProtocol = SystemLaunchAtLoginService.shared,
        permissionsService: PermissionsServiceProtocol = SystemPermissionsService.shared,
        hotKeys: HotKeyConfigurator = .shared,
        onClearHistoryRequest: (() -> Void)? = nil
    ) {
        self.store = store
        self.hotKeys = hotKeys
        self.launchAtLoginService = launchAtLoginService
        self.permissionsService = permissionsService
        self.onClearHistoryRequest = onClearHistoryRequest

        store.objectWillChange
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    self?.objectWillChange.send()
                } else {
                    DispatchQueue.main.async {
                        self?.objectWillChange.send()
                    }
                }
            }
            .store(in: &cancellables)

        refreshPermissions()

        if let tab = Self.requestedTab {
            selectedTab = tab
            Self.requestedTab = nil
        }
        Self.tabRequests
            .sink { [weak self] tab in
                self?.selectedTab = tab
                Self.requestedTab = nil
            }
            .store(in: &cancellables)
    }

    /// A pane another part of the app wants Settings to show (e.g. Permissions, when a feature lacks one).
    private static var requestedTab: SettingsTab?
    private static let tabRequests = PassthroughSubject<SettingsTab, Never>()

    /// Makes Settings show `tab`: now if the window exists, else when it is created. Call before showing the window.
    public static func request(_ tab: SettingsTab) {
        requestedTab = tab
        tabRequests.send(tab)
    }

    // MARK: - General Tab Bindings

    public var historyLimit: Int {
        get { store.historyLimit }
        set { store.historyLimit = newValue }
    }

    public var isLaunchAtLoginEnabled: Bool {
        launchAtLoginService.isEnabled
    }

    public var launchAtLoginStatus: LaunchAtLoginStatus {
        launchAtLoginService.status
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try launchAtLoginService.enable()
                store.launchAtLoginEnabled = true
            } else {
                try launchAtLoginService.disable()
                store.launchAtLoginEnabled = false
            }
        } catch let error as LaunchAtLoginError {
            launchAtLoginError = error.localizedDescription
            store.launchAtLoginEnabled = launchAtLoginService.isEnabled
        } catch {
            launchAtLoginError = error.localizedDescription
            store.launchAtLoginEnabled = launchAtLoginService.isEnabled
        }
    }

    public func clearClipboardHistory() {
        if let onClear = onClearHistoryRequest {
            onClear()
        } else {
            ClipboardStore.shared.clearUnpinnedHistory()
        }
    }

    public func resetAllDefaults() {
        store.resetToDefaults()
        if launchAtLoginService.isEnabled {
            try? launchAtLoginService.disable()
        }
        refreshPermissions()
    }

    // MARK: - Shortcuts Tab Bindings

    public func hotkey(for id: String) -> HotKeyDefinition? {
        store.hotkey(for: id)
    }

    public func updateHotkey(_ definition: HotKeyDefinition) -> Bool {
        report(hotKeys.change(definition), for: definition)
    }

    public func resetHotkeyToDefault(id: String) {
        let result = hotKeys.resetToDefault(id: id)
        if let builtIn = HotKeyDefinition.builtIn(for: id) {
            _ = report(result, for: builtIn)
        }
    }

    /// Turns the outcome into the message the Shortcuts tab shows; `true` when the change took effect.
    private func report(_ result: HotKeyChangeResult, for definition: HotKeyDefinition) -> Bool {
        switch result {
        case .applied:
            shortcutConflictError = nil
            return true
        case .conflict(let name):
            shortcutConflictError = "Shortcut '\(definition.keyEquivalent)' is already assigned to '\(name)'."
        case .unavailable:
            shortcutConflictError = "Shortcut '\(definition.keyEquivalent)' could not be registered, probably because another app uses it. The previous shortcut still works."
        case .unknownAction:
            shortcutConflictError = "This shortcut is not active yet. Restart Zenith and try again."
        }
        return false
    }

    // MARK: - Audio Tab Bindings

    public var soundEffectsEnabled: Bool {
        get { store.soundEffectsEnabled }
        set { store.soundEffectsEnabled = newValue }
    }

    public var soundVolume: Float {
        get { store.soundVolume }
        set {
            store.soundVolume = newValue
            AudioFeedbackManager.shared.volume = newValue
        }
    }

    public var soundEffectAssignments: [String: SoundChoice] {
        get { store.soundEffectAssignments }
        set { store.soundEffectAssignments = newValue }
    }

    public func soundChoice(for effect: SoundEffect) -> SoundChoice {
        store.soundEffectAssignments[effect.rawValue] ?? .system(name: effect.standardSoundName)
    }

    public func setSoundChoice(_ choice: SoundChoice, for effect: SoundEffect) {
        var current = store.soundEffectAssignments
        current[effect.rawValue] = choice
        store.soundEffectAssignments = current
    }

    public func playTestSound(effect: SoundEffect) {
        guard soundEffectsEnabled else { return }
        AudioFeedbackManager.shared.play(effect)
    }

    public func playTestSound(type: String) {
        guard soundEffectsEnabled else { return }
        switch type {
        case "copy":
            AudioFeedbackManager.shared.playNewCopySound()
        case "paste":
            AudioFeedbackManager.shared.playPasteSound()
        case "shutter":
            AudioFeedbackManager.shared.playShutterSound()
        default:
            break
        }
    }

    public func refreshCustomSounds() {
        customSounds = SoundChoice.availableCustomSounds()
    }

    // MARK: - Permissions Tab Bindings

    public func refreshPermissions() {
        screenRecordingGranted = permissionsService.checkScreenRecordingPermission()
        accessibilityGranted = permissionsService.checkAccessibilityPermission()
    }

    public func openScreenRecordingSettings() {
        _ = permissionsService.openScreenRecordingSettings()
    }

    public func openAccessibilitySettings() {
        _ = permissionsService.openAccessibilitySettings()
    }

    public func openAutomationSettings() {
        _ = SystemPermissions.openAutomationSettings()
    }
}
