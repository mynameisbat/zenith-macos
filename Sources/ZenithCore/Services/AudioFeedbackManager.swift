import Foundation
import AppKit
import Combine

// MARK: - Semantic Sound Effects

/// Semantic acoustic feedback identifiers across Zenith.
public enum SoundEffect: String, Sendable, CaseIterable {
    /// Tactile pop/click emitted when a new item is captured to the clipboard (F33).
    case clipboardCopy
    /// Tactile acoustic cue emitted when a user selects an item to restore/paste (F34).
    case paste
    /// Native camera shutter sound emitted upon completing a screenshot (F35).
    case capture
    /// Crisp resonant ping emitted when sampling a color in Loupe Magnifier.
    case colorSample
    /// Soft mechanical latch emitted when toggling an item's pinned state.
    case pinToggle
    /// Subtle deletion thud emitted when clearing unpinned or all items.
    case delete
    /// Muted alert emitted on invalid action or error boundary.
    case error

    /// Compatibility conversion to legacy SoundType.
    public var soundType: SoundType? {
        switch self {
        case .clipboardCopy: return .newCopy
        case .paste: return .paste
        case .capture: return .shutter
        default: return nil
        }
    }

    /// System sound name or alias used for playback.
    public var standardSoundName: String {
        switch self {
        case .clipboardCopy: return "Pop"
        case .paste: return "Tink"
        case .capture: return "Hero"
        case .colorSample: return "Ping"
        case .pinToggle: return "Purr"
        case .delete: return "Basso"
        case .error: return "Basso"
        }
    }
}

// MARK: - Legacy SoundType Bridge

public extension SoundType {
    /// Maps legacy SoundType to modern SoundEffect.
    var soundEffect: SoundEffect {
        switch self {
        case .newCopy: return .clipboardCopy
        case .paste: return .paste
        case .shutter: return .capture
        }
    }

    /// System sound name associated with this sound type.
    var standardSoundName: String {
        soundEffect.standardSoundName
    }
}

// MARK: - SoundServiceProtocol Extensions

public extension SoundServiceProtocol {
    /// Plays a specific semantic sound effect cue.
    func play(_ effect: SoundEffect) {
        switch effect {
        case .clipboardCopy: playNewCopySound()
        case .paste: playPasteSound()
        case .capture: playShutterSound()
        default: break
        }
    }

    /// Plays a legacy SoundType cue.
    func play(_ type: SoundType) {
        switch type {
        case .newCopy: playNewCopySound()
        case .paste: playPasteSound()
        case .shutter: playShutterSound()
        }
    }
}

// MARK: - Audio Player Backend Protocol

/// Abstract audio player backend decoupling AudioFeedbackManager from NSSound.
public protocol AudioPlayerBackendProtocol: Sendable {
    /// Plays the sound with the given name and normalized volume (0.0 ... 1.0).
    func playSound(named name: String, volume: Float) -> Bool

    /// Stops all currently playing audio instances.
    func stopAll()
}

#if DEBUG
// MARK: - Mock Audio Player Backend

/// Thread-safe in-memory mock player backend for fast headless unit tests.
public final class MockAudioPlayerBackend: AudioPlayerBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _playedSounds: [String] = []
    private var _playRequestCount: Int = 0
    private var _lastVolume: Float?
    private var _stopAllCount: Int = 0

    public init() {}

    public var playedSounds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _playedSounds
    }

    public var playRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _playRequestCount
    }

    public var lastPlayedSound: String? {
        lock.lock()
        defer { lock.unlock() }
        return _playedSounds.last
    }

    public var lastVolume: Float? {
        lock.lock()
        defer { lock.unlock() }
        return _lastVolume
    }

    public var stopAllCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopAllCount
    }

    @discardableResult
    public func playSound(named name: String, volume: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _playedSounds.append(name)
        _playRequestCount += 1
        _lastVolume = volume
        return true
    }

    public func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        _stopAllCount += 1
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _playedSounds.removeAll()
        _playRequestCount = 0
        _lastVolume = nil
        _stopAllCount = 0
    }
}
#endif

// MARK: - Synthetic Sound Generator (Headless Fallback)

/// Generates valid in-memory PCM RIFF WAV audio data without touching the filesystem.
public enum SyntheticSoundGenerator {
    /// Generates pure 16-bit PCM Mono RIFF WAV audio data with exponential decay envelope.
    public static func generateWAV(frequency: Double, duration: Double, sampleRate: Int = 44100) -> Data {
        let numSamples = max(1, Int(Double(sampleRate) * duration))
        var data = Data()
        data.reserveCapacity(44 + numSamples * 2)

        // 1. RIFF Chunk Descriptor
        data.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + numSamples * 2).littleEndian
        data.append(Data(bytes: &fileSize, count: 4))
        data.append(contentsOf: "WAVEfmt ".utf8)

        // 2. "fmt " Subchunk
        var subchunk1Size = UInt32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(1).littleEndian // Mono
        data.append(Data(bytes: &numChannels, count: 2))
        var sRate = UInt32(sampleRate).littleEndian
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian // sampleRate * numChannels * bitsPerSample / 8
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian // numChannels * bitsPerSample / 8
        data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: 2))

        // 3. "data" Subchunk
        data.append(contentsOf: "data".utf8)
        var subchunk2Size = UInt32(numSamples * 2).littleEndian
        data.append(Data(bytes: &subchunk2Size, count: 4))

        // 4. Sample Generation with Decay Envelope
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let sample = sin(2.0 * .pi * frequency * t)
            let envelope = max(0.0, 1.0 - (Double(i) / Double(numSamples)))
            var value = Int16(sample * envelope * 20000.0).littleEndian
            data.append(Data(bytes: &value, count: 2))
        }

        return data
    }

    /// Generates appropriate synthetic sound data for a semantic SoundEffect.
    public static func data(for effect: SoundEffect) -> Data {
        switch effect {
        case .clipboardCopy:
            return generateWAV(frequency: 1200.0, duration: 0.02)
        case .paste:
            return generateWAV(frequency: 1800.0, duration: 0.025)
        case .capture:
            return generateWAV(frequency: 800.0, duration: 0.05)
        case .colorSample:
            return generateWAV(frequency: 1500.0, duration: 0.06)
        case .pinToggle:
            return generateWAV(frequency: 450.0, duration: 0.03)
        case .delete:
            return generateWAV(frequency: 180.0, duration: 0.08)
        case .error:
            return generateWAV(frequency: 220.0, duration: 0.12)
        }
    }

    /// Generates synthetic sound data for a standard system sound name.
    public static func data(for name: String) -> Data {
        switch name.lowercased() {
        case "pop":
            return data(for: .clipboardCopy)
        case "tink":
            return data(for: .paste)
        case "hero":
            return data(for: .capture)
        case "ping":
            return data(for: .colorSample)
        case "purr":
            return data(for: .pinToggle)
        case "basso":
            return data(for: .error)
        default:
            return generateWAV(frequency: 1000.0, duration: 0.03)
        }
    }
}

// MARK: - Production NSSound Backend

/// High-performance NSSound backend managing prototype caching, polyphony, and synthetic fallback.
public final class NSSoundPlayerBackend: AudioPlayerBackendProtocol, @unchecked Sendable {
    public static let shared = NSSoundPlayerBackend()

    private let lock = NSLock()
    private let playbackQueue = DispatchQueue(label: "com.zenith.audio.playback", qos: .userInteractive)
    private var soundPrototypes: [String: NSSound] = [:]
    private var activePlayers: [NSSound] = []
    private static let maxActiveSounds: Int = 8

    public init() {}

    public func playSound(named name: String, volume: Float) -> Bool {
        playbackQueue.async { [weak self] in
            self?.executePlayback(named: name, volume: volume)
        }
        return true
    }

    public func stopAll() {
        playbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            for player in self.activePlayers {
                player.stop()
            }
            self.activePlayers.removeAll()
            for (_, prototype) in self.soundPrototypes {
                prototype.stop()
            }
            self.lock.unlock()
        }
    }

    private func executePlayback(named name: String, volume: Float) {
        guard let sound = resolveSound(named: name) else { return }

        lock.lock()
        activePlayers.removeAll { !$0.isPlaying }

        if !sound.isPlaying {
            sound.volume = volume
            sound.play()
        } else if activePlayers.count < Self.maxActiveSounds {
            if let clone = sound.copy() as? NSSound {
                clone.volume = volume
                activePlayers.append(clone)
                clone.play()
            }
        }
        lock.unlock()
    }

    private func resolveSound(named name: String) -> NSSound? {
        lock.lock()
        if let cached = soundPrototypes[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let sound = loadSound(named: name)
        if let sound = sound {
            lock.lock()
            soundPrototypes[name] = sound
            lock.unlock()
        }
        return sound
    }

    private func loadSound(named name: String) -> NSSound? {
        // Tier 1: NSSound(named:)
        if let s = NSSound(named: name) {
            return s
        }

        // Tier 2: Custom sounds in ~/Library/Application Support/Zenith/Sounds/
        let customDir = SoundChoice.customSoundsDirectoryURL
        let customFileURL = customDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: customFileURL.path),
           let s = NSSound(contentsOfFile: customFileURL.path, byReference: true) {
            return s
        }

        // Direct path check if name is already an absolute path
        if FileManager.default.fileExists(atPath: name),
           let s = NSSound(contentsOfFile: name, byReference: true) {
            return s
        }

        // Tier 3: CoreAudio system sounds & /System/Library/Sounds/
        let systemSounds = [
            "/System/Library/Sounds/\(name).aiff",
            "/System/Library/Sounds/\(name).caf",
            "/System/Library/Sounds/\(name)",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
        ]
        for path in systemSounds {
            if FileManager.default.fileExists(atPath: path),
               let s = NSSound(contentsOfFile: path, byReference: true) {
                return s
            }
        }

        // Tier 4: In-Memory Synthetic Waveform Fallback
        let wavData = SyntheticSoundGenerator.data(for: name)
        return NSSound(data: wavData)
    }
}

// MARK: - Audio Feedback Manager Implementation

/// Production audio feedback engine for tactile acoustic cues across Zenith.
/// Conforms to `SoundServiceProtocol` and `@unchecked Sendable`.
public final class AudioFeedbackManager: SoundServiceProtocol, @unchecked Sendable {
    public static let shared = AudioFeedbackManager()

    private let lock = NSLock()
    private let backend: AudioPlayerBackendProtocol
    private let settingsStore: SettingsStore

    private var _isMutedOverride: Bool?
    private var _volume: Float = 1.0
    private var cancellables = Set<AnyCancellable>()
    private var _lastPlayedSound: String?
    private var _totalPlayedCount: Int = 0

    public init(
        backend: AudioPlayerBackendProtocol = NSSoundPlayerBackend.shared,
        settingsStore: SettingsStore = .shared,
        isMuted: Bool? = nil,
        volume: Float = 1.0
    ) {
        self.backend = backend
        self.settingsStore = settingsStore
        self._isMutedOverride = isMuted
        self._volume = min(max(volume, 0.0), 1.0)

        // Dynamically follow settings changes
        settingsStore.objectWillChange
            .sink { [weak self] in
                self?.handleSettingsChange()
            }
            .store(in: &cancellables)
    }

    // MARK: - SoundServiceProtocol Properties

    public var isMuted: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let override = _isMutedOverride {
                return override
            }
            return !settingsStore.soundEffectsEnabled
        }
        set {
            lock.lock()
            _isMutedOverride = newValue
            lock.unlock()
            settingsStore.soundEffectsEnabled = !newValue
        }
    }

    /// Master volume for sound feedback, clamped strictly between 0.0 and 1.0.
    public var volume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _volume
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _volume = min(max(newValue, 0.0), 1.0)
        }
    }

    /// The name of the most recently played sound effect.
    public var lastPlayedSound: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPlayedSound
    }

    /// Total number of sound feedback requests played.
    public var totalPlayedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalPlayedCount
    }

    // MARK: - Playback Triggers

    public func playNewCopySound() {
        play(SoundEffect.clipboardCopy)
    }

    public func playPasteSound() {
        play(SoundEffect.paste)
    }

    public func playShutterSound() {
        play(SoundEffect.capture)
    }

    public func play(_ effect: SoundEffect) {
        let choice = settingsStore.soundEffectAssignments[effect.rawValue] ?? .system(name: effect.standardSoundName)
        switch choice {
        case .muted:
            return
        case .system(let name):
            playNamed(name)
        case .custom(let relativePath, _):
            playNamed(relativePath)
        }
    }

    public func play(_ type: SoundType) {
        playNamed(type.standardSoundName)
    }

    public func stopAll() {
        backend.stopAll()
    }

    // MARK: - Internal Playback Dispatch

    private func playNamed(_ name: String) {
        let currentVolume: Float
        do {
            lock.lock()
            let muted: Bool
            if let override = _isMutedOverride {
                muted = override
            } else {
                muted = !settingsStore.soundEffectsEnabled
            }

            if muted {
                lock.unlock()
                return
            }

            _lastPlayedSound = name
            _totalPlayedCount += 1
            currentVolume = _volume
            lock.unlock()
        }

        _ = backend.playSound(named: name, volume: currentVolume)
    }

    private func handleSettingsChange() {
        lock.lock()
        _isMutedOverride = nil
        _volume = settingsStore.soundVolume
        lock.unlock()
    }
}
