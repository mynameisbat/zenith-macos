import Foundation
import CoreGraphics
import AppKit

/// Protocol defining synthetic paste keystroke automation.
public protocol AutoPasteServiceProtocol: Sendable {
    @discardableResult
    func paste() -> Bool
}

/// Service that synthesizes a native Command+V keystroke to automatically paste
/// clipboard contents into the currently focused application upon selection.
public struct AutoPasteService: AutoPasteServiceProtocol, Sendable {
    public static let shared = AutoPasteService()

    /// Virtual key code for letter 'V' in macOS standard ANSI keyboard layout (kVK_ANSI_V = 0x09).
    public static let vKeyCode: CGKeyCode = 9

    public init() {}

    /// Simulates a Command+V keystroke.
    /// Requires macOS Accessibility permission (`AXIsProcessTrusted()`).
    @discardableResult
    public func paste() -> Bool {
        Self.simulatePasteKeystroke()
    }

    /// Low-level synthesis of Command+V key events posted to the system HID event stream.
    @discardableResult
    public static func simulatePasteKeystroke() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
