#if DEBUG
import Foundation

/// Mock sound service that records audio events and verifies mute suppression.
public final class MockSoundService: SoundServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _isMuted: Bool = false
    private var _playedSounds: [SoundType] = []
    private var _newCopySoundCount: Int = 0
    private var _pasteSoundCount: Int = 0
    private var _shutterSoundCount: Int = 0

    public init(isMuted: Bool = false) {
        self._isMuted = isMuted
    }

    public var isMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isMuted
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isMuted = newValue
        }
    }

    public var playedSounds: [SoundType] {
        lock.lock()
        defer { lock.unlock() }
        return _playedSounds
    }

    public var newCopySoundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _newCopySoundCount
    }

    public var pasteSoundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _pasteSoundCount
    }

    public var shutterSoundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _shutterSoundCount
    }

    public func playNewCopySound() {
        lock.lock()
        defer { lock.unlock() }
        guard !_isMuted else { return }
        _newCopySoundCount += 1
        _playedSounds.append(.newCopy)
    }

    public func playPasteSound() {
        lock.lock()
        defer { lock.unlock() }
        guard !_isMuted else { return }
        _pasteSoundCount += 1
        _playedSounds.append(.paste)
    }

    public func playShutterSound() {
        lock.lock()
        defer { lock.unlock() }
        guard !_isMuted else { return }
        _shutterSoundCount += 1
        _playedSounds.append(.shutter)
    }

    public func reset() {
        lock.lock()
        _playedSounds.removeAll()
        _newCopySoundCount = 0
        _pasteSoundCount = 0
        _shutterSoundCount = 0
        lock.unlock()
    }
}
#endif
