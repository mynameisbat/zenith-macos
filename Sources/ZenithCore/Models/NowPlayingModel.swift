import Foundation
import SwiftUI

/// Supported media players on macOS for Dynamic Island integration.
public enum NowPlayingApp: String, Sendable, CaseIterable, Equatable {
    case appleMusic = "Music"
    case spotify = "Spotify"

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    public var iconName: String {
        switch self {
        case .appleMusic: return "music.note"
        case .spotify: return "waveform"
        }
    }

    public var brandColor: Color {
        switch self {
        case .appleMusic: return Color(red: 0.98, green: 0.22, blue: 0.36) // Apple Music vibrant pink-red
        case .spotify: return Color(red: 0.12, green: 0.84, blue: 0.38)    // Spotify neon green
        }
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
