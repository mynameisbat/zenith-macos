import Foundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Translating an event

/// Turns what the event tap sees into a `SnippetKeyInput`. Pure, so the rules are tested without a tap.
public enum SnippetKeyEventTranslator {
    /// Keys that move the caret or leave the line: forward delete, arrows, Home, End, Page Up/Down, Return, Enter,
    /// Tab, Escape.
    public static let resetKeyCodes: Set<Int64> = [
        Int64(kVK_ForwardDelete), Int64(kVK_LeftArrow), Int64(kVK_RightArrow), Int64(kVK_UpArrow),
        Int64(kVK_DownArrow), Int64(kVK_Home), Int64(kVK_End), Int64(kVK_PageUp), Int64(kVK_PageDown),
        Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter), Int64(kVK_Tab), Int64(kVK_Escape)
    ]

    /// - Parameters:
    ///   - isKeyDown: false for a mouse click.
    ///   - characters: what the key typed in the current layout (empty for a dead key).
    ///   - userData: the event's `eventSourceUserData`; Zenith's own key presses carry `SnippetSyntheticEventMarker`.
    /// - Returns: nil for an event that changes nothing (Zenith's own key, a dead key, a function key).
    public static func input(
        isKeyDown: Bool,
        keyCode: Int64,
        flags: CGEventFlags,
        characters: String,
        userData: Int64 = 0
    ) -> SnippetKeyInput? {
        if userData == SnippetSyntheticEventMarker.userData { return nil }
        guard isKeyDown else { return .reset }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .reset }
        if keyCode == Int64(kVK_Delete) { return .backspace }
        if resetKeyCodes.contains(keyCode) { return .reset }
        guard !characters.isEmpty else { return nil }
        let scalars = characters.unicodeScalars
        // F-keys and other special keys type characters from the private use area (U+F700…).
        if scalars.contains(where: { $0.properties.generalCategory == .privateUse }) { return nil }
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return .reset }
        return .characters(characters)
    }
}

// MARK: - Event source seam

/// Delivers the user's typing to the snippet service. The app uses `EventTapSnippetKeySource` (a listen-only
/// `CGEventTap`, needs Accessibility); tests use `MockSnippetKeySource` and never create a tap.
@MainActor
public protocol SnippetKeySource: AnyObject {
    /// Starts delivering. Returns false when the tap cannot be created (no Accessibility permission).
    func start(_ handler: @escaping @MainActor (SnippetKeyInput) -> Void) -> Bool
    func stop()
    var isRunning: Bool { get }
}

/// A listen-only event tap on key-down and mouse-down, plus a reset whenever another app comes to the front.
/// It never changes or swallows an event.
@MainActor
public final class EventTapSnippetKeySource: SnippetKeySource {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    fileprivate var handler: (@MainActor (SnippetKeyInput) -> Void)?

    public init() {}

    public var isRunning: Bool { tap != nil }

    public func start(_ handler: @escaping @MainActor (SnippetKeyInput) -> Void) -> Bool {
        self.handler = handler
        if tap != nil { return true }

        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: snippetEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?(.reset) }
        }
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        tap = nil
        runLoopSource = nil
        activationObserver = nil
        handler = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func deliver(_ input: SnippetKeyInput) {
        handler?(input)
    }

    /// Reads an event from the tap. Runs before the event moves on, and keeps nothing of it.
    nonisolated fileprivate static func translate(_ event: CGEvent, type: CGEventType) -> SnippetKeyInput? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        if type == .keyDown {
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        }
        let characters = String(utf16CodeUnits: buffer, count: max(0, min(length, buffer.count)))
        return SnippetKeyEventTranslator.input(
            isKeyDown: type == .keyDown,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            characters: characters,
            userData: event.getIntegerValueField(.eventSourceUserData)
        )
    }
}

/// The tap's C callback. The tap's run loop source is on the main run loop, so this runs on the main thread.
private func snippetEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let source = Unmanaged<EventTapSnippetKeySource>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            source.reenable()
            source.deliver(.reset)
        }
    } else if let input = EventTapSnippetKeySource.translate(event, type: type) {
        MainActor.assumeIsolated { source.deliver(input) }
    }
    return Unmanaged.passUnretained(event)
}

/// Sends whatever a test tells it to.
@MainActor
public final class MockSnippetKeySource: SnippetKeySource {
    public var allowsStart: Bool
    public private(set) var startCount = 0
    private var handler: (@MainActor (SnippetKeyInput) -> Void)?

    public init(allowsStart: Bool = true) {
        self.allowsStart = allowsStart
    }

    public var isRunning: Bool { handler != nil }

    public func start(_ handler: @escaping @MainActor (SnippetKeyInput) -> Void) -> Bool {
        startCount += 1
        guard allowsStart else { return false }
        self.handler = handler
        return true
    }

    public func stop() {
        handler = nil
    }

    /// Delivers one input, as the tap would.
    public func send(_ input: SnippetKeyInput) {
        handler?(input)
    }

    /// Types each character of `text` as its own key press.
    public func type(_ text: String) {
        for character in text { send(.characters(String(character))) }
    }
}
