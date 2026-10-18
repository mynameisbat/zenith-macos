#if DEBUG
import Foundation

/// Mock hotkey service tracking registrations and simulating keystroke triggers.
/// Conforms to @unchecked Sendable with full NSLock synchronization across all internal state.
public final class MockHotKeyService: HotKeyServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _registeredHotKeys: [String: HotKeyDefinition] = [:]
    private var _handlers: [String: () -> Void] = [:]
    private var _invokedHotKeys: [String: Int] = [:]
    private var _shouldRegistrationSucceed: Bool = true
    private var _unregisterCallCount: Int = 0

    public init() {}

    // MARK: - Synchronized Public State Accessors

    /// Snapshot of currently registered hotkey definitions indexed by ID.
    public var registeredHotKeys: [String: HotKeyDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return _registeredHotKeys
    }

    /// Dictionary mapping hotkey ID to number of times it has been simulated/invoked.
    public var invokedHotKeys: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return _invokedHotKeys
    }

    /// Controls whether subsequent registerHotKey calls succeed or fail.
    public var shouldRegistrationSucceed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldRegistrationSucceed
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shouldRegistrationSucceed = newValue
        }
    }

    /// Number of unregister operations performed.
    public var unregisterCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _unregisterCallCount
    }

    // MARK: - HotKeyServiceProtocol Implementation

    public func registerHotKey(_ definition: HotKeyDefinition, handler: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _shouldRegistrationSucceed else { return false }
        _registeredHotKeys[definition.id] = definition
        _handlers[definition.id] = handler
        return true
    }

    public func unregisterHotKey(_ definition: HotKeyDefinition) {
        unregisterHotKey(id: definition.id)
    }

    public func unregisterHotKey(id: String) {
        lock.lock()
        defer { lock.unlock() }
        _registeredHotKeys.removeValue(forKey: id)
        _handlers.removeValue(forKey: id)
        _unregisterCallCount += 1
    }

    public func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        _registeredHotKeys.removeAll()
        _handlers.removeAll()
        _unregisterCallCount += 1
    }

    // MARK: - Simulation & Testing Helpers

    /// Simulates pressing the global keyboard shortcut associated with the provided ID.
    /// Handlers are dispatched OUTSIDE the lock to prevent reentrant deadlocks.
    @discardableResult
    public func simulateHotKeyTrigger(id: String) -> Bool {
        lock.lock()
        guard let handler = _handlers[id] else {
            lock.unlock()
            return false
        }
        _invokedHotKeys[id, default: 0] += 1
        lock.unlock()

        handler()
        return true
    }

    /// Convenience alias matching simulateTrigger(hotKeyId:) in test suites.
    @discardableResult
    public func simulateTrigger(hotKeyId: String) -> Bool {
        simulateHotKeyTrigger(id: hotKeyId)
    }

    /// Returns whether a hotkey with the given ID is currently registered.
    public func isRegistered(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _registeredHotKeys[id] != nil
    }

    /// Returns the number of times a specific hotkey was simulated/invoked.
    public func invocationCount(for id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _invokedHotKeys[id, default: 0]
    }

    /// Resets all mock registration and invocation state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _registeredHotKeys.removeAll()
        _handlers.removeAll()
        _invokedHotKeys.removeAll()
        _unregisterCallCount = 0
        _shouldRegistrationSucceed = true
    }
}
#endif
