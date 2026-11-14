import Foundation

/// Where finished recordings go.
public enum RecordingSaveLocation: String, CaseIterable, Sendable, Identifiable {
    case movies
    case desktop
    case custom

    public var id: String { rawValue }
}

/// The screen recording switches, saved in `UserDefaults`.
@MainActor
public final class ScreenRecordingSettings: ObservableObject {
    public static let shared = ScreenRecordingSettings()

    public enum Keys {
        public static let systemAudio = "zenith_recording_system_audio"
        public static let microphone = "zenith_recording_microphone"
        public static let showsCursor = "zenith_recording_shows_cursor"
        public static let highlightsClicks = "zenith_recording_highlights_clicks"
        public static let frameRate = "zenith_recording_frame_rate"
        public static let codec = "zenith_recording_codec"
        public static let format = "zenith_recording_format"
        public static let countdown = "zenith_recording_countdown"
        public static let saveLocation = "zenith_recording_save_location"
        public static let customFolder = "zenith_recording_custom_folder"
        public static let gifMaxWidth = "zenith_recording_gif_max_width"
        public static let gifFrameRate = "zenith_recording_gif_frame_rate"
    }

    @Published public var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: Keys.systemAudio) } }
    /// Off by default: the microphone permission is asked for only when the user turns this on.
    @Published public var microphone: Bool { didSet { defaults.set(microphone, forKey: Keys.microphone) } }
    @Published public var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: Keys.showsCursor) } }
    @Published public var highlightsClicks: Bool { didSet { defaults.set(highlightsClicks, forKey: Keys.highlightsClicks) } }
    @Published public var frameRate: RecordingFrameRate { didSet { defaults.set(frameRate.rawValue, forKey: Keys.frameRate) } }
    @Published public var codec: RecordingVideoCodec { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }
    @Published public var format: RecordingFileFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    /// 3-2-1 before recording starts.
    @Published public var countdown: Bool { didSet { defaults.set(countdown, forKey: Keys.countdown) } }
    @Published public var saveLocation: RecordingSaveLocation { didSet { defaults.set(saveLocation.rawValue, forKey: Keys.saveLocation) } }
    @Published public var customFolder: URL? { didSet { defaults.set(customFolder?.path, forKey: Keys.customFolder) } }
    /// GIF export: widest picture (pixels) and frames per second.
    @Published public var gifMaxWidth: Int { didSet { defaults.set(gifMaxWidth, forKey: Keys.gifMaxWidth) } }
    @Published public var gifFrameRate: Int { didSet { defaults.set(gifFrameRate, forKey: Keys.gifFrameRate) } }

    private let defaults: UserDefaults
    private let homeDirectory: URL

    public init(userDefaults: UserDefaults = .standard, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = userDefaults
        self.homeDirectory = homeDirectory
        systemAudio = userDefaults.object(forKey: Keys.systemAudio) as? Bool ?? true
        microphone = userDefaults.object(forKey: Keys.microphone) as? Bool ?? false
        showsCursor = userDefaults.object(forKey: Keys.showsCursor) as? Bool ?? true
        highlightsClicks = userDefaults.object(forKey: Keys.highlightsClicks) as? Bool ?? false
        frameRate = RecordingFrameRate(rawValue: userDefaults.integer(forKey: Keys.frameRate)) ?? .fps30
        codec = userDefaults.string(forKey: Keys.codec).flatMap(RecordingVideoCodec.init(rawValue:)) ?? .h264
        format = userDefaults.string(forKey: Keys.format).flatMap(RecordingFileFormat.init(rawValue:)) ?? .mov
        countdown = userDefaults.object(forKey: Keys.countdown) as? Bool ?? true
        saveLocation = userDefaults.string(forKey: Keys.saveLocation).flatMap(RecordingSaveLocation.init(rawValue:)) ?? .movies
        customFolder = userDefaults.string(forKey: Keys.customFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        gifMaxWidth = GIFExportOptions.clampedWidth(userDefaults.object(forKey: Keys.gifMaxWidth) as? Int ?? GIFExportOptions.defaultMaxWidth)
        gifFrameRate = GIFExportOptions.clampedFrameRate(userDefaults.object(forKey: Keys.gifFrameRate) as? Int ?? GIFExportOptions.defaultFrameRate)
    }

    /// The folder recordings are saved in. A custom folder that is gone falls back to Movies.
    public var saveFolder: URL {
        Self.folder(for: saveLocation, custom: customFolder, home: homeDirectory)
    }

    public static func folder(for location: RecordingSaveLocation, custom: URL?, home: URL, fileManager: FileManager = .default) -> URL {
        switch location {
        case .movies:
            return home.appendingPathComponent("Movies", isDirectory: true)
        case .desktop:
            return home.appendingPathComponent("Desktop", isDirectory: true)
        case .custom:
            var isDirectory: ObjCBool = false
            if let custom, fileManager.fileExists(atPath: custom.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return custom
            }
            return home.appendingPathComponent("Movies", isDirectory: true)
        }
    }

    public var gifOptions: GIFExportOptions {
        GIFExportOptions(maxWidth: gifMaxWidth, framesPerSecond: gifFrameRate)
    }

    public func resetToDefaults() {
        systemAudio = true
        microphone = false
        showsCursor = true
        highlightsClicks = false
        frameRate = .fps30
        codec = .h264
        format = .mov
        countdown = true
        saveLocation = .movies
        customFolder = nil
        gifMaxWidth = GIFExportOptions.defaultMaxWidth
        gifFrameRate = GIFExportOptions.defaultFrameRate
    }
}
