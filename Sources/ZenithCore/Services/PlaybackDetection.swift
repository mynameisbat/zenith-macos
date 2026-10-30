import AppKit
import Foundation
import IOKit.pwr_mgt

// MARK: - Which app is playing audio

/// An app that currently holds a "playing media" power assertion.
public struct PlayingApplication: Sendable, Equatable {
    public let processID: Int32
    public let bundleIdentifier: String?
    public let name: String

    public init(processID: Int32, bundleIdentifier: String?, name: String) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Finds the app playing audio from the system's power assertions.
///
/// macOS 15.4+ answers the private `MediaRemote` framework with nothing for processes Apple did not sign, so browser
/// audio cannot be read from there. Browsers do announce playback with a power assertion, though, and
/// `IOPMCopyAssertionsByProcess` lists those per process:
///   - Chrome-family browsers hold "Playing audio"
///   - Safari/WebKit holds "com.apple.WebCore: HTMLMediaElement playback"
/// "Video Wake Lock" is deliberately not used: it is also held by muted, autoplaying video.
public enum PlaybackAssertionProbe {
    static let playbackMarkers = ["playing audio", "htmlmediaelement"]

    /// PIDs in an `IOPMCopyAssertionsByProcess` table that hold a playback assertion, in ascending order.
    static func playbackPIDs(in table: [Int: [[String: Any]]]) -> [Int] {
        table.compactMap { pid, assertions -> Int? in
            let isPlaying = assertions.contains { assertion in
                guard let name = (assertion["AssertName"] as? String)?.lowercased() else { return false }
                return playbackMarkers.contains { name.contains($0) }
            }
            return isPlaying ? pid : nil
        }.sorted()
    }

    /// The regular (Dock-visible) app playing audio right now, preferring the frontmost one.
    /// `excluding` lists bundle identifiers that are tracked by other means (Apple Music and Spotify post their own
    /// notifications) and so must not be reported here.
    public static func playingApplication(excluding excludedBundleIDs: Set<String> = []) -> PlayingApplication? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let table = unmanaged?.takeRetainedValue() as? [Int: [[String: Any]]] else {
            return nil
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let candidates = playbackPIDs(in: table).compactMap { pid -> NSRunningApplication? in
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.activationPolicy == .regular,
                  !app.isTerminated else { return nil }
            if let bundleID = app.bundleIdentifier, excludedBundleIDs.contains(bundleID) || bundleID == ownBundleID {
                return nil
            }
            return app
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let chosen = candidates.first(where: { $0.processIdentifier == frontmostPID }) ?? candidates.first else {
            return nil
        }
        return PlayingApplication(
            processID: chosen.processIdentifier,
            bundleIdentifier: chosen.bundleIdentifier,
            name: chosen.localizedName ?? chosen.bundleIdentifier ?? "App"
        )
    }
}

// MARK: - What the browser is showing

public struct BrowserTab: Sendable, Equatable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// Reads the front tab of a browser over AppleScript (needs the user's Automation permission for that browser).
///
/// The script runs through `osascript` via a `SystemCommandRunner`: the caller is never blocked on an
/// `NSAppleScript` call on its own thread, and tests can supply the output. A browser that is not running is never
/// launched by the lookup.
public enum BrowserTabProbe {
    private enum Family {
        case safari
        case chromium
    }

    private static let families: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium
    ]

    /// True if the front tab of this app can be read (Firefox, for one, has no AppleScript dictionary).
    public static func supportsTabLookup(bundleIdentifier: String) -> Bool {
        families[bundleIdentifier] != nil
    }

    static func script(forBundleIdentifier bundleIdentifier: String) -> String? {
        guard let family = families[bundleIdentifier] else { return nil }
        let tab = family == .safari ? "current tab of front window" : "active tab of front window"
        let title = family == .safari ? "name" : "title"
        return """
        with timeout of 3 seconds
            if application id "\(bundleIdentifier)" is not running then return ""
            tell application id "\(bundleIdentifier)"
                if (count of windows) is 0 then return ""
                set t to \(tab)
                return (\(title) of t) & linefeed & (URL of t)
            end tell
        end timeout
        """
    }

    /// Parses the two lines the script returns: title, then URL.
    static func parseTab(_ output: String) -> BrowserTab? {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 2, !lines[1].isEmpty else { return nil }
        return BrowserTab(title: lines[0], url: lines[1])
    }

    public static func activeTab(bundleIdentifier: String, runner: SystemCommandRunner) -> BrowserTab? {
        guard let script = script(forBundleIdentifier: bundleIdentifier),
              let result = runner("/usr/bin/osascript", ["-e", script]),
              result.status == 0 else { return nil }
        return parseTab(result.output)
    }

    // MARK: Interpreting a tab

    private static let mediaHosts = [
        "youtube.com", "youtu.be", "x.com", "twitter.com", "soundcloud.com", "spotify.com", "twitch.tv",
        "vimeo.com", "netflix.com", "bandcamp.com", "tiktok.com", "facebook.com", "instagram.com"
    ]

    /// Whether the URL belongs to a site whose tab title is a good description of what is playing.
    public static func isMediaSite(url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Titles a site shows when the tab says nothing about the media (e.g. the X home timeline).
    static let genericTitles: Set<String> = ["home", "x", "twitter", "youtube", "notifications", "explore"]

    /// Removes the unread counter and site suffix browsers and sites add to titles.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let counter = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            title.removeSubrange(counter)
        }
        for suffix in [" - YouTube", " / X", " / Twitter", " - SoundCloud"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
