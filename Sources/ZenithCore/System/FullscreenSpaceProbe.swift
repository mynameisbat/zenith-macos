import AppKit
import Foundation

/// Tells whether the Space showing on a display is a full-screen app's.
///
/// AppKit has no call for this. The window server's own list of Spaces per display says it (`type` 4 is a
/// full-screen Space); it is read through SkyLight, resolved at run time, and a missing symbol reads as "not full
/// screen". A game that covers the screen with an ordinary borderless window has no such Space; `FullscreenWindowProbe`
/// looks for that.
public enum FullscreenSpaceProbe {
    static let fullscreenSpaceType = 4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (connection: MainConnection, copySpaces: CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let copySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(copySpaces, to: CopyManagedDisplaySpaces.self))
    }()

    /// Whether the entry for `displayUUID` in the window server's list has a full-screen Space in front. With
    /// "Displays have separate Spaces" off there is one entry, named "Main", for every display.
    static func isFullscreen(displayUUID: String?, in displays: [[String: Any]]) -> Bool {
        let entry = displays.first { ($0["Display Identifier"] as? String) == displayUUID }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? (displays.count == 1 ? displays.first : nil)
        guard let current = entry?["Current Space"] as? [String: Any] else { return false }
        return (current["type"] as? Int) == fullscreenSpaceType
    }

    public static func currentSpaceIsFullscreen(onDisplay display: CGDirectDisplayID) -> Bool {
        guard let functions,
              let displays = functions.copySpaces(functions.connection())?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let uuid = CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return isFullscreen(displayUUID: uuid, in: displays)
    }
}

/// Tells whether the frontmost app covers a display with an ordinary window, as games, VLC and emulators do in
/// their own full-screen mode without a full-screen Space.
///
/// The test is the window's frame, read from `CGWindowListCopyWindowInfo`: owner PID, layer, bounds and alpha need no
/// permission (titles would need Screen Recording and are not used). A window counts only if it reaches the display's
/// top edge, over the menu bar: a zoomed window starts below the menu bar and does not. Not detected: a window that
/// covers the screen but is drawn transparent, and with "Automatically hide and show the menu bar" on, a zoomed window
/// reaches the top edge and is taken for a full-screen one.
public enum FullscreenWindowProbe {
    /// One on-screen window, reduced to what the decision needs.
    public struct Window: Equatable, Sendable {
        public let pid: pid_t
        public let layer: Int
        /// Top-left origin, global display coordinates (as `CGWindowListCopyWindowInfo` and `CGDisplayBounds` give).
        public let bounds: CGRect
        public let alpha: Double
        public let ownerName: String?

        public init(pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1, ownerName: String? = nil) {
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
            self.ownerName = ownerName
        }
    }

    /// System processes whose windows sit over the whole screen without being an app in full screen (Stage Manager's
    /// strip belongs to WindowManager).
    static let systemOwners: Set<String> = [
        "Dock", "Window Server", "WindowManager", "Control Center", "SystemUIServer", "Notification Center",
        "Spotlight", "loginwindow", "screencaptureui"
    ]

    /// Slack for rounding in window frames, in points.
    static let tolerance: CGFloat = 1

    /// Whether a window of `frontmostPID` covers all of `displayBounds`, menu-bar strip included. Windows of this
    /// process, of system processes, below the normal layer (Finder's desktop is a screen-sized window at a negative
    /// layer) or (almost) transparent do not count.
    public static func frontmostAppCoversDisplay(
        windows: [Window],
        frontmostPID: pid_t?,
        ownPID: pid_t,
        displayBounds: CGRect
    ) -> Bool {
        guard let frontmostPID, frontmostPID != ownPID, !displayBounds.isEmpty else { return false }
        return windows.contains { window in
            window.pid == frontmostPID
                && window.layer >= 0
                && window.alpha > 0.01
                && !(window.ownerName.map(systemOwners.contains) ?? false)
                && covers(window.bounds, displayBounds)
        }
    }

    static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        window.minX <= display.minX + tolerance
            && window.minY <= display.minY + tolerance
            && window.maxX >= display.maxX - tolerance
            && window.maxY >= display.maxY - tolerance
    }

    /// The on-screen windows now, from the window server.
    public static func onScreenWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return Window(
                pid: pid,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                ownerName: info[kCGWindowOwnerName as String] as? String
            )
        }
    }

    /// Whether the frontmost app covers `display` right now.
    @MainActor
    public static func frontmostAppCoversDisplay(_ display: CGDirectDisplayID) -> Bool {
        frontmostAppCoversDisplay(
            windows: onScreenWindows(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            displayBounds: CGDisplayBounds(display)
        )
    }
}
