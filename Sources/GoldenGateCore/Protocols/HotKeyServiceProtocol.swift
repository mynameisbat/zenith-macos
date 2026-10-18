import Foundation

/// Service protocol managing system-wide keyboard shortcut registration and dispatch.
public protocol HotKeyServiceProtocol: AnyObject {
    /// Registers a global hotkey with a given action handler.
    /// - Parameters:
    ///   - definition: The hotkey definition specifying keycode and modifiers.
    ///   - handler: Closure invoked when the global key combination is pressed.
    /// - Returns: `true` if registration succeeded with the OS, `false` otherwise.
    func registerHotKey(_ definition: HotKeyDefinition, handler: @escaping () -> Void) -> Bool
    
    /// Unregisters an active hotkey definition.
    /// - Parameter definition: The definition to remove.
    func unregisterHotKey(_ definition: HotKeyDefinition)
    
    /// Unregisters a hotkey by its unique identifier.
    /// - Parameter id: The identifier of the hotkey.
    func unregisterHotKey(id: String)
    
    /// Unregisters all currently registered global hotkeys.
    func unregisterAll()
}

public extension HotKeyServiceProtocol {
    func unregisterHotKey(id: String) {}
}
