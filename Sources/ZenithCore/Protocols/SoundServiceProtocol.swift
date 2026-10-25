import Foundation

/// Semantic sound effect identifiers in Zenith.
public enum SoundType: String, Sendable, CaseIterable {
    case newCopy
    case paste
    case shutter
}

/// Service protocol for executing haptic audio cues during user operations.
public protocol SoundServiceProtocol: Sendable {
    /// Global mute state. When true, all audio playback operations are suppressed.
    var isMuted: Bool { get set }
    
    /// Plays the subtle pop/click sound when a new item is captured to the clipboard.
    func playNewCopySound()
    
    /// Plays the subtle feedback sound when a user selects an item to paste/restore.
    func playPasteSound()
    
    /// Plays the native camera shutter sound upon completing a screen capture.
    func playShutterSound()
}
