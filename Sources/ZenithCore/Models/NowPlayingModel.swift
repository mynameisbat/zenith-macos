import Foundation
import SwiftUI

/// Supported media players and browsers on macOS for Dynamic Island integration.
public enum NowPlayingApp: String, Sendable, CaseIterable, Equatable {
    case appleMusic = "Music"
    case spotify = "Spotify"
    case youtube = "YouTube"
    case chrome = "Chrome"
    case safari = "Safari"
    case arc = "Arc"
    case firefox = "Firefox"
    case edge = "Edge"
    case generic = "Media"

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .youtube: return "com.google.Chrome"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .generic: return "com.apple.media"
        }
    }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .generic: return "Media Player"
        }
    }

    public var iconName: String {
        switch self {
        case .appleMusic: return "music.note"
        case .spotify: return "waveform"
        case .youtube: return "play.rectangle.fill"
        case .chrome: return "globe"
        case .safari: return "safari.fill"
        case .arc: return "sparkles"
        case .firefox: return "flame.fill"
        case .edge: return "globe"
        case .generic: return "play.circle.fill"
        }
    }

    public var brandColor: Color {
        switch self {
        case .appleMusic: return Color(red: 0.98, green: 0.22, blue: 0.36) // Apple Music vibrant pink-red
        case .spotify: return Color(red: 0.12, green: 0.84, blue: 0.38)    // Spotify neon green
        case .youtube: return Color(red: 1.0, green: 0.15, blue: 0.15)     // YouTube vibrant red
        case .chrome: return Color(red: 0.26, green: 0.52, blue: 0.96)     // Chrome Google blue
        case .safari: return Color(red: 0.0, green: 0.48, blue: 1.0)       // Safari electric blue
        case .arc: return Color(red: 0.95, green: 0.35, blue: 0.55)        // Arc browser magenta
        case .firefox: return Color(red: 1.0, green: 0.45, blue: 0.1)      // Firefox sunset orange
        case .edge: return Color(red: 0.0, green: 0.65, blue: 0.95)        // Edge cyan
        case .generic: return Color(red: 0.98, green: 0.45, blue: 0.09)    // Zenith flame orange
        }
    }

    /// Resolves best matching NowPlayingApp from bundle identifier, track title, and artist metadata.
    public static func resolve(bundleId: String?, title: String?, artist: String?) -> NowPlayingApp {
        let b = bundleId?.lowercased() ?? ""
        let t = (title ?? "").lowercased()
        let a = (artist ?? "").lowercased()

        if t.contains("youtube") || a.contains("youtube") {
            return .youtube
        }
        if b.contains("com.apple.music") {
            return .appleMusic
        }
        if b.contains("spotify") {
            return .spotify
        }
        if b.contains("chrome") {
            return .chrome
        }
        if b.contains("safari") {
            return .safari
        }
        if b.contains("thebrowser") || b.contains("arc") {
            return .arc
        }
        if b.contains("firefox") {
            return .firefox
        }
        if b.contains("edgemac") || b.contains("microsoft.edge") {
            return .edge
        }
        return .generic
    }
}

/// Domain model representing an actively playing or paused track on macOS.
public struct NowPlayingTrack: Identifiable, Sendable, Equatable {
    public let id: String
    public let app: NowPlayingApp
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: TimeInterval
    public let position: TimeInterval
    public let isPlaying: Bool
    public let artworkData: Data?

    public init(
        app: NowPlayingApp,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval = 0,
        position: TimeInterval = 0,
        isPlaying: Bool = true,
        artworkData: Data? = nil
    ) {
        self.id = "\(app.rawValue):\(artist):\(title)"
        self.app = app
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = max(0, duration)
        self.position = max(0, min(position, max(1, duration)))
        self.isPlaying = isPlaying
        self.artworkData = artworkData
    }

    /// Playback progress ratio clamped between 0.0 and 1.0.
    public var progress: Double {
        guard duration > 0 else { return 0.0 }
        return min(max(position / duration, 0.0), 1.0)
    }

    /// Formatted current playback position (e.g. "1:24").
    public var formattedPosition: String {
        Self.formatTime(position)
    }

    /// Formatted total track duration (e.g. "3:45").
    public var formattedDuration: String {
        Self.formatTime(duration)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 && !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    public static func == (lhs: NowPlayingTrack, rhs: NowPlayingTrack) -> Bool {
        lhs.id == rhs.id &&
        lhs.isPlaying == rhs.isPlaying &&
        abs(lhs.position - rhs.position) < 2.0 &&
        abs(lhs.duration - rhs.duration) < 1.0 &&
        lhs.artworkData?.count == rhs.artworkData?.count
    }
}
