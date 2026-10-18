import Foundation
import Carbon

// MARK: - Carbon Backend Driver Protocol

/// Abstract driver protocol for Carbon HIToolbox HotKey C APIs.
/// Decouples HotKeyManager from direct OS C-functions to support deterministic headless testing.
public protocol CarbonHotKeyBackendProtocol: AnyObject, Sendable {
    /// Registers a shortcut combination with the OS WindowServer or simulation engine.
    func register(keyCode: UInt32, modifiers: UInt32, signature: OSType, id: UInt32) -> (status: OSStatus, ref: EventHotKeyRef?)

    /// Unregisters an existing hotkey reference.
    func unregister(ref: EventHotKeyRef) -> OSStatus

    /// Installs a dispatcher handler invoked whenever a registered hotkey is pressed.
    func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) -> OSStatus

    /// Removes the installed hotkey dispatcher handler.
    func removeHandler() -> OSStatus
}

// MARK: - Production System Carbon Backend

/// Real macOS Carbon HIToolbox implementation using RegisterEventHotKey and InstallEventHandler.
/// Requires ZERO Accessibility permissions (`AXIsProcessTrusted`).
public final class SystemCarbonBackend: CarbonHotKeyBackendProtocol, @unchecked Sendable {
    public static let shared = SystemCarbonBackend()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var globalHandler: (@Sendable (UInt32) -> Void)?
    nonisolated(unsafe) private static var globalEventHandlerRef: EventHandlerRef?

    public init() {}

    public func register(keyCode: UInt32, modifiers: UInt32, signature: OSType, id: UInt32) -> (status: OSStatus, ref: EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var outRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &outRef
        )
        return (status, outRef)
    }

    public func unregister(ref: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(ref)
    }

    public func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) -> OSStatus {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        Self.globalHandler = handler
        guard Self.globalEventHandlerRef == nil else { return noErr }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (callRef, event, userData) -> OSStatus in
                guard let event = event else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                let handler: (@Sendable (UInt32) -> Void)? = {
                    SystemCarbonBackend.lock.lock()
                    defer { SystemCarbonBackend.lock.unlock() }
                    return SystemCarbonBackend.globalHandler
                }()

                if let handler = handler {
                    if Thread.isMainThread {
                        handler(hotKeyID.id)
                    } else {
                        DispatchQueue.main.async {
                            handler(hotKeyID.id)
                        }
                    }
                    return noErr
                }

                return OSStatus(eventNotHandledErr)
            },
            1,
            &spec,
            nil,
            &Self.globalEventHandlerRef
        )

        return status
    }

    public func removeHandler() -> OSStatus {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        Self.globalHandler = nil
        if let ref = Self.globalEventHandlerRef {
            let status = RemoveEventHandler(ref)
            Self.globalEventHandlerRef = nil
            return status
        }
        return noErr
    }
}

// MARK: - Headless Simulated Carbon Backend

/// In-memory simulated Carbon backend for headless unit tests and CI automation.
public final class SimulatedCarbonBackend: CarbonHotKeyBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var registeredCombinations: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    private var registeredRefs: Set<UInt32> = []
    private var handler: (@Sendable (UInt32) -> Void)?

    public var shouldFailRegistration: Bool = false
    public var failingKeyCodes: Set<UInt32> = []
    public var simulatedErrorCode: OSStatus = -9878 // eventHotKeyExistsErr

    public init() {}

    public var registeredRefsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registeredRefs.count
    }

    public func register(keyCode: UInt32, modifiers: UInt32, signature: OSType, id: UInt32) -> (status: OSStatus, ref: EventHotKeyRef?) {
        lock.lock()
        defer { lock.unlock() }

        if shouldFailRegistration || failingKeyCodes.contains(keyCode) {
            return (simulatedErrorCode, nil)
        }

        // Detect duplicate key combination
        for (_, existing) in registeredCombinations {
            if existing.keyCode == keyCode && existing.modifiers == modifiers {
                return (OSStatus(eventHotKeyExistsErr), nil)
            }
        }

        registeredCombinations[id] = (keyCode, modifiers)
        registeredRefs.insert(id)

        let ref = EventHotKeyRef(bitPattern: UInt(id))
        return (noErr, ref)
    }

    public func unregister(ref: EventHotKeyRef) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }

        let id = UInt32(UInt(bitPattern: ref))
        registeredCombinations.removeValue(forKey: id)
        registeredRefs.remove(id)
        return noErr
    }

    public func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        return noErr
    }

    public func removeHandler() -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        self.handler = nil
        return noErr
    }

    /// Simulates a global keypress event in headless testing.
    public func simulateKeyPress(hotKeyID: UInt32) {
        let callback: (@Sendable (UInt32) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }()
        callback?(hotKeyID)
    }
}

// MARK: - HotKey Manager Implementation

/// Production zero-permission Carbon Global HotKey Manager.
/// Uses Carbon Event Manager (RegisterEventHotKey / InstallEventHandler)
/// to listen for system-wide shortcuts with zero Accessibility permissions required.
public final class HotKeyManager: HotKeyServiceProtocol, @unchecked Sendable {
    public static let shared = HotKeyManager()

    /// OSType signature for GoldenGate: 'GGHK' = 0x4747484B
    public static let signature: OSType = 0x4747484B

    private let lock = NSLock()
    private let backend: CarbonHotKeyBackendProtocol

    private var _registeredHotKeys: [String: HotKeyDefinition] = [:]
    private var _hotKeyRefs: [String: EventHotKeyRef] = [:]
    private var _numericIds: [String: UInt32] = [:]
    private var _numericToId: [UInt32: String] = [:]
    private var _actionHandlers: [String: () -> Void] = [:]
    private var nextNumericId: UInt32 = 1

    public init(backend: CarbonHotKeyBackendProtocol = SystemCarbonBackend.shared) {
        self.backend = backend
        _ = backend.installHandler { [weak self] numericId in
            self?.handleTrigger(numericId: numericId)
        }
    }

    deinit {
        unregisterAll()
    }

    // MARK: - HotKeyServiceProtocol Implementation

    @discardableResult
    public func registerHotKey(_ definition: HotKeyDefinition, handler: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // 1. Conflict detection: reject if another action already registered this key combination
        for (existingId, existing) in _registeredHotKeys {
            if existingId != definition.id,
               existing.keyCode == definition.keyCode,
               existing.carbonModifiers == definition.carbonModifiers {
                return false
            }
        }

        // 2. Rebinding: if same action ID already registered
        if let existing = _registeredHotKeys[definition.id] {
            // Case 2a: If key combination is identical, update action handler and definition in-place
            // without calling Carbon's RegisterEventHotKey (avoiding -9878: eventHotKeyExistsErr)
            if existing.keyCode == definition.keyCode && existing.carbonModifiers == definition.carbonModifiers {
                _registeredHotKeys[definition.id] = definition
                _actionHandlers[definition.id] = handler
                return true
            }

            // Case 2b: If changing key combination, take backup snapshot for rollback
            let backupDefinition = existing
            let backupNumId = _numericIds[definition.id]
            let backupHandler = _actionHandlers[definition.id]

            internalUnregister(id: definition.id)

            let numId = nextNumericId
            nextNumericId += 1

            let result = backend.register(
                keyCode: definition.keyCode,
                modifiers: definition.carbonModifiers,
                signature: Self.signature,
                id: numId
            )

            if result.status == noErr, let ref = result.ref {
                _registeredHotKeys[definition.id] = definition
                _hotKeyRefs[definition.id] = ref
                _numericIds[definition.id] = numId
                _numericToId[numId] = definition.id
                _actionHandlers[definition.id] = handler
                return true
            } else {
                // Rollback and restore previous shortcut
                let restoreNumId = backupNumId ?? {
                    let n = nextNumericId
                    nextNumericId += 1
                    return n
                }()
                let restoreResult = backend.register(
                    keyCode: backupDefinition.keyCode,
                    modifiers: backupDefinition.carbonModifiers,
                    signature: Self.signature,
                    id: restoreNumId
                )
                if restoreResult.status == noErr, let restoredRef = restoreResult.ref {
                    _registeredHotKeys[definition.id] = backupDefinition
                    _hotKeyRefs[definition.id] = restoredRef
                    _numericIds[definition.id] = restoreNumId
                    _numericToId[restoreNumId] = definition.id
                    if let bh = backupHandler {
                        _actionHandlers[definition.id] = bh
                    }
                }
                return false
            }
        }

        // 3. New action ID registration
        let numId = nextNumericId
        nextNumericId += 1

        let result = backend.register(
            keyCode: definition.keyCode,
            modifiers: definition.carbonModifiers,
            signature: Self.signature,
            id: numId
        )

        guard result.status == noErr, let ref = result.ref else {
            return false
        }

        _registeredHotKeys[definition.id] = definition
        _hotKeyRefs[definition.id] = ref
        _numericIds[definition.id] = numId
        _numericToId[numId] = definition.id
        _actionHandlers[definition.id] = handler

        return true
    }

    public func unregisterHotKey(_ definition: HotKeyDefinition) {
        unregisterHotKey(id: definition.id)
    }

    public func unregisterHotKey(id: String) {
        lock.lock()
        defer { lock.unlock() }
        internalUnregister(id: id)
    }

    public func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        let ids = Array(_registeredHotKeys.keys)
        for id in ids {
            internalUnregister(id: id)
        }
    }

    private func internalUnregister(id: String) {
        if let ref = _hotKeyRefs.removeValue(forKey: id) {
            _ = backend.unregister(ref: ref)
        }
        if let numId = _numericIds.removeValue(forKey: id) {
            _numericToId.removeValue(forKey: numId)
        }
        _registeredHotKeys.removeValue(forKey: id)
        _actionHandlers.removeValue(forKey: id)
    }

    // MARK: - Trigger Handling

    private func handleTrigger(numericId: UInt32) {
        let handler: (() -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let actionId = _numericToId[numericId] else { return nil }
            return _actionHandlers[actionId]
        }()

        // Dispatched OUTSIDE lock to prevent re-entrant deadlocks
        handler?()
    }

    // MARK: - Inspection & Diagnostics

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _registeredHotKeys.count
    }

    public var registeredHotKeys: [String: HotKeyDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return _registeredHotKeys
    }

    public func isRegistered(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _registeredHotKeys[id] != nil
    }

    public func carbonId(for id: String) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return _numericIds[id]
    }

    /// Finds any registered hotkey conflicting with the target definition.
    public func findConflict(for definition: HotKeyDefinition) -> HotKeyDefinition? {
        lock.lock()
        defer { lock.unlock() }
        for (id, existing) in _registeredHotKeys {
            if id != definition.id,
               existing.keyCode == definition.keyCode,
               existing.carbonModifiers == definition.carbonModifiers {
                return existing
            }
        }
        return nil
    }

    /// Dynamically re-registers a hotkey when changed in settings, preserving its existing handler closure.
    @discardableResult
    public func reRegister(definition: HotKeyDefinition) -> Bool {
        lock.lock()
        guard let existingHandler = _actionHandlers[definition.id] else {
            lock.unlock()
            return false
        }
        lock.unlock()
        return registerHotKey(definition, handler: existingHandler)
    }

    // MARK: - Simulation Helpers

    @discardableResult
    public func simulateHotKeyTrigger(id: String) -> Bool {
        let handler: (() -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return _actionHandlers[id]
        }()

        guard let handler = handler else { return false }
        handler()
        return true
    }

    @discardableResult
    public func simulateTrigger(hotKeyId: String) -> Bool {
        simulateHotKeyTrigger(id: hotKeyId)
    }
}

/// Convenience alias matching architecture documentation.
public typealias CarbonHotKeyManager = HotKeyManager
