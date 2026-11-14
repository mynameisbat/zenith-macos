import Foundation
import CoreGraphics

/// The real Cleaning Mode event tap: an active `CGEventTap` at the head of the session that swallows key, mouse,
/// scroll, gesture and system-defined (media, volume, brightness) events. Needs Accessibility; without it
/// `CGEvent.tapCreate` returns nil and `install` throws. Runs on the main run loop.
///
/// Tests never create one: they use `MockCleaningModeEventTap`. `translate(type:flags:keyCode:)` is the pure part.
@MainActor
public final class SystemCleaningModeEventTap: CleaningModeEventTapping {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var retainedSelf: Unmanaged<SystemCleaningModeEventTap>?
    private var onEvent: (@MainActor (CleaningModeInputEvent) -> Bool)?
    private var onDisabled: (@MainActor (CleaningModeTapDisableReason) -> Void)?
    private var isInCallback = false

    public init() {}

    // MARK: Event types

    /// NSEvent types with no `CGEventType` name: trackpad gestures, smart zoom, Quick Look and Force Touch pressure.
    nonisolated static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 33, 34]

    nonisolated static let pointerTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    /// `NX_SYSDEFINED`: media, volume and brightness keys.
    nonisolated static let systemDefinedType: UInt32 = 14

    /// Every event type the tap swallows.
    public nonisolated static var eventMask: CGEventMask {
        var types: [UInt32] = [CGEventType.keyDown, .keyUp, .flagsChanged, .scrollWheel].map(\.rawValue)
        types += pointerTypes.map(\.rawValue)
        types += gestureTypes
        types.append(systemDefinedType)
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }

    /// Reduces a raw event to what Cleaning Mode needs. Returns nil for a type it does not block.
    public nonisolated static func translate(type: UInt32, flags: UInt64, keyCode: Int64) -> CleaningModeInputEvent? {
        switch type {
        case CGEventType.keyDown.rawValue:
            return .keyDown(keyCode: UInt16(truncatingIfNeeded: keyCode))
        case CGEventType.keyUp.rawValue:
            return .keyUp(keyCode: UInt16(truncatingIfNeeded: keyCode))
        case CGEventType.flagsChanged.rawValue:
            return .modifiersChanged(modifiers(from: CGEventFlags(rawValue: flags)))
        case CGEventType.scrollWheel.rawValue:
            return .scroll
        case systemDefinedType:
            return .systemDefined
        default:
            if pointerTypes.contains(where: { $0.rawValue == type }) { return .pointer }
            if gestureTypes.contains(type) { return .gesture }
            return nil
        }
    }

    public nonisolated static func modifiers(from flags: CGEventFlags) -> CleaningModeModifiers {
        var result: CleaningModeModifiers = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    // MARK: CleaningModeEventTapping

    public func install(
        onEvent: @escaping @MainActor (CleaningModeInputEvent) -> Bool,
        onDisabled: @escaping @MainActor (CleaningModeTapDisableReason) -> Void
    ) throws {
        remove()
        let retained = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: cleaningModeTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            throw CleaningModeError.tapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            retained.release()
            throw CleaningModeError.tapUnavailable
        }
        self.port = port
        self.source = source
        self.retainedSelf = retained
        self.onEvent = onEvent
        self.onDisabled = onDisabled
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    public func remove() {
        onEvent = nil
        onDisabled = nil
        guard let port else { return }
        // Stop swallowing at once; tearing the port down inside its own callback waits for the next run-loop turn.
        CGEvent.tapEnable(tap: port, enable: false)
        pendingTeardowns.append(PendingTeardown(port: port, source: source, retained: retainedSelf))
        self.port = nil
        self.source = nil
        self.retainedSelf = nil
        if isInCallback {
            // `retained` keeps this object alive until then.
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { self.finishTeardowns() }
            }
        } else {
            finishTeardowns()
        }
    }

    private struct PendingTeardown {
        let port: CFMachPort
        let source: CFRunLoopSource?
        let retained: Unmanaged<SystemCleaningModeEventTap>?
    }

    private var pendingTeardowns: [PendingTeardown] = []

    private func finishTeardowns() {
        let items = pendingTeardowns
        pendingTeardowns.removeAll()
        for item in items {
            if let source = item.source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(item.port)
            item.retained?.release()
        }
    }

    /// Returns `true` to swallow the event.
    fileprivate func process(type: UInt32, flags: UInt64, keyCode: Int64) -> Bool {
        isInCallback = true
        defer { isInCallback = false }
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            // Never re-enable silently: end Cleaning Mode so the user knows input is back.
            let reason: CleaningModeTapDisableReason = type == CGEventType.tapDisabledByTimeout.rawValue ? .timeout : .userInput
            onDisabled?(reason)
            return false
        }
        guard let onEvent, let event = Self.translate(type: type, flags: flags, keyCode: keyCode) else { return false }
        return onEvent(event)
    }
}

private func cleaningModeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let rawType = type.rawValue
    let flags = event.flags.rawValue
    let isKey = type == .keyDown || type == .keyUp
    let keyCode = isKey ? event.getIntegerValueField(.keyboardEventKeycode) : 0
    let tap = Unmanaged<SystemCleaningModeEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    // The run-loop source is on the main run loop, so this is the main thread.
    let swallow = MainActor.assumeIsolated {
        tap.process(type: rawType, flags: flags, keyCode: keyCode)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
