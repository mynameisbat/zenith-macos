import Foundation
import SwiftUI
import Combine
import GoldenGateCore

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case audio = "Audio"
    case privacy = "Privacy"
    case cleaner = "Cleaner"
    case permissions = "Permissions"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .audio: return "speaker.wave.2.fill"
        case .privacy: return "shield.checkered"
        case .cleaner: return "trash.circle.fill"
        case .permissions: return "lock.shield.fill"
        }
    }

    public var subtitle: String {
        switch self {
        case .general: return "Startup & History"
        case .shortcuts: return "Global Hotkeys"
        case .audio: return "Sound Feedback"
        case .privacy: return "Cloudflare DoH"
        case .cleaner: return "Caches & Junk"
        case .permissions: return "Screen & Access"
        }
    }

    public var sectionTitle: String {
        switch self {
        case .general, .shortcuts, .audio:
            return "WORKSPACE"
        case .privacy, .cleaner, .permissions:
            return "SYSTEM & SECURITY"
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var selectedTab: SettingsTab = .general
    @Published public var hoveredTab: SettingsTab? = nil
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
    public var onClearHistoryRequest: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    public init(
        store: SettingsStore = .shared,
        launchAtLoginService: LaunchAtLoginServiceProtocol = SystemLaunchAtLoginService.shared,
        permissionsService: PermissionsServiceProtocol = SystemPermissionsService.shared,
        onClearHistoryRequest: (() -> Void)? = nil
    ) {
        self.store = store
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
        for (existingId, existing) in store.hotkeyMappings where existingId != definition.id {
            if existing.keyCode == definition.keyCode && existing.carbonModifiers == definition.carbonModifiers {
                shortcutConflictError = "Shortcut '\(definition.keyEquivalent)' is already assigned to '\(existing.name)'."
                return false
            }
        }
        shortcutConflictError = nil
        store.updateHotkey(definition)
        return true
    }

    public func resetHotkeyToDefault(id: String) {
        if let defaultDef = HotKeyDefinition.defaultDictionary[id] {
            store.updateHotkey(defaultDef)
        }
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
}
