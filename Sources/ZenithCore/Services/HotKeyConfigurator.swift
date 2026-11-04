import Foundation

/// How a shortcut change turned out.
public enum HotKeyChangeResult: Sendable, Equatable {
    /// Registered with the system and saved.
    case applied
    /// Another of Zenith's shortcuts already uses that key combination. Nothing changed.
    case conflict(with: String)
    /// The system refused the combination (usually another app has it). The previous shortcut still works.
    case unavailable
    /// No action with this identifier is registered.
    case unknownAction
}

/// Connects the shortcuts the user chose (saved in `SettingsStore`) to the ones registered with the system.
///
/// Settings used to save a changed shortcut and nothing more: the app registered the built-in defaults at launch and
/// never looked at what was saved, so a change did nothing, even after a restart.
public final class HotKeyConfigurator: @unchecked Sendable {
    public static let shared = HotKeyConfigurator()

    private let store: SettingsStore
    private let manager: HotKeyManager
    private let lock = NSLock()
    private var defaultDefinitions: [String: HotKeyDefinition] = [:]

    public init(store: SettingsStore = .shared, manager: HotKeyManager = .shared) {
        self.store = store
        self.manager = manager
    }

    /// Registers every action at launch with the user's saved shortcut, or its default.
    /// A saved shortcut the system refuses falls back to the default.
    /// - Returns: The shortcuts that could not be registered at all (the key combination is taken by another app).
    @discardableResult
    public func registerAll(_ actions: [(definition: HotKeyDefinition, handler: () -> Void)]) -> [HotKeyDefinition] {
        var failed: [HotKeyDefinition] = []
        for action in actions {
            let builtIn = action.definition
            lock.withLock { defaultDefinitions[builtIn.id] = builtIn }

            let chosen = store.hotkey(for: builtIn.id) ?? builtIn
            if manager.registerHotKey(chosen, handler: action.handler) { continue }
            if chosen != builtIn, manager.registerHotKey(builtIn, handler: action.handler) {
                // The saved shortcut cannot be used (any more); go back to the built-in one, visibly.
                store.updateHotkey(builtIn)
                continue
            }
            failed.append(chosen)
        }
        return failed
    }

    /// Applies a new shortcut for an action that is already registered, and saves it only if the system accepts it.
    @discardableResult
    public func change(_ definition: HotKeyDefinition) -> HotKeyChangeResult {
        guard manager.isRegistered(id: definition.id) else { return .unknownAction }
        if let other = manager.findConflict(for: definition) { return .conflict(with: other.name) }
        guard manager.reRegister(definition: definition) else { return .unavailable }
        store.updateHotkey(definition)
        return .applied
    }

    /// Puts an action back on its built-in shortcut.
    @discardableResult
    public func resetToDefault(id: String) -> HotKeyChangeResult {
        guard let builtIn = lock.withLock({ defaultDefinitions[id] }) ?? HotKeyDefinition.defaultDictionary[id] else {
            return .unknownAction
        }
        return change(builtIn)
    }
}
