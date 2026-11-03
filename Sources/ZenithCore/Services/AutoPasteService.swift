import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

/// Protocol defining synthetic paste keystroke automation.
public protocol AutoPasteServiceProtocol: Sendable {
    @discardableResult
    func paste() -> Bool
}

/// Service that synthesizes a native Command+V keystroke to automatically paste
/// clipboard contents into the currently focused application upon selection.
public struct AutoPasteService: AutoPasteServiceProtocol, Sendable {
    public static let shared = AutoPasteService()

    /// Virtual key code for letter 'V' on a standard ANSI (QWERTY) keyboard (kVK_ANSI_V = 0x09).
    /// Used as the fallback when the active layout cannot be queried; see `keyCodeForV()`.
    public static let vKeyCode: CGKeyCode = 9

    private let isTrusted: @Sendable () -> Bool
    private let keyCodeForV: @Sendable () -> CGKeyCode
    private let postEvent: @Sendable (CGEvent) -> Void

    /// - Parameters:
    ///   - isTrusted: Whether the app may post keyboard events (Accessibility permission).
    ///   - keyCodeForV: The physical key that types "v" in the active keyboard layout.
    ///   - postEvent: Delivers an event to the system; tests substitute a recorder so no real keys are pressed.
    public init(
        isTrusted: @escaping @Sendable () -> Bool = { SystemPermissions.checkAccessibilityPermission() },
        keyCodeForV: @escaping @Sendable () -> CGKeyCode = AutoPasteService.keyCodeForV,
        postEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) {
        self.isTrusted = isTrusted
        self.keyCodeForV = keyCodeForV
        self.postEvent = postEvent
    }

    /// Simulates a Command+V keystroke. Returns `false`, without posting anything, when the app is not allowed to
    /// (macOS drops synthetic key events from untrusted processes without any error).
    @discardableResult
    public func paste() -> Bool {
        guard isTrusted() else { return false }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let keyCode = keyCodeForV()
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = []

        postEvent(keyDown)
        postEvent(keyUp)
        return true
    }

    /// Low-level synthesis of Command+V key events posted to the system HID event stream.
    @discardableResult
    public static func simulatePasteKeystroke() -> Bool {
        shared.paste()
    }

    /// The key code that types "v" in the active keyboard layout, so ⌘V works on Dvorak, Colemak and similar layouts.
    /// Falls back to the ANSI position if the layout cannot be read. Layouts that cannot type Latin letters use their
    /// ASCII-capable companion, which is what macOS itself uses for Command shortcuts.
    public static func keyCodeForV() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return vKeyCode
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return vKeyCode }
        let layout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        for code in 0..<UInt16(128) {
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                code,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys,
                characters.count,
                &length,
                &characters
            )
            if status == noErr, length == 1, characters[0] == UniChar(UInt8(ascii: "v")) {
                return CGKeyCode(code)
            }
        }
        return vKeyCode
    }
}
