import AppKit
import Foundation

// MARK: - Controlling playback

/// The hardware media keys macOS routes to whichever app is the current Now Playing app.
public enum MediaKey: Int32, Sendable {
    case playPause = 16   // NX_KEYTYPE_PLAY
    case next = 17        // NX_KEYTYPE_NEXT
    case previous = 18    // NX_KEYTYPE_PREVIOUS
}

public protocol MediaKeyPosting: Sendable {
    /// Returns whether the key press was actually sent.
    @discardableResult
    func post(_ key: MediaKey) -> Bool
}

/// Posts a media key press the same way a keyboard's F7/F8/F9 does, so it reaches a browser tab without stealing
/// focus or typing into whatever text field has it.
public struct SystemMediaKeys: MediaKeyPosting {
    public init() {}

    @discardableResult
    public func post(_ key: MediaKey) -> Bool {
        // macOS silently drops synthetic key events from an app without Accessibility permission. Ask for it
        // (once the user has clicked a control, a prompt is expected) rather than failing without a trace.
        guard SystemPermissions.checkAccessibilityPermission() else {
            _ = SystemPermissions.requestAccessibilityPermission()
            return false
        }
        for isDown in [true, false] {
            let flags = isDown ? 0xA00 : 0xB00
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Int(key.rawValue) << 16) | flags,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }
}
