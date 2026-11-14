import Foundation
import CoreGraphics

// Plain values that describe a screen recording: what is recorded, how, and with which sound. Everything here is pure
// so the decisions (sizes, audio sources, file names) can be tested without recording anything.

/// What a recording shows.
public enum RecordingTarget: Equatable, Sendable {
    /// A whole display.
    case display(displayID: CGDirectDisplayID)
    /// Part of a display. `rect` is in display-local points with the origin at the display's top-left corner (the
    /// coordinates `SCStreamConfiguration.sourceRect` takes).
    case region(displayID: CGDirectDisplayID, rect: CGRect)
    /// One window, wherever it moves. Other windows that cover it are not recorded.
    case window(windowID: CGWindowID)
}

public enum RecordingFrameRate: Int, CaseIterable, Sendable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }
}

public enum RecordingVideoCodec: String, CaseIterable, Sendable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }

    /// The largest width or height the hardware encoder takes. H.264 encoders stop at 4096; HEVC goes to 8192.
    public var maximumDimension: Int {
        switch self {
        case .h264: return 4096
        case .hevc: return 8192
        }
    }

    /// Bits per pixel per frame used to pick a bit rate. HEVC needs fewer for the same picture.
    var bitsPerPixel: Double {
        switch self {
        case .h264: return 0.12
        case .hevc: return 0.08
        }
    }
}

public enum RecordingFileFormat: String, CaseIterable, Sendable, Identifiable {
    case mov
    case mp4

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

/// A sound a recording can carry.
public enum RecordingAudioSource: String, CaseIterable, Sendable, Hashable {
    /// What the Mac plays, from ScreenCaptureKit (macOS 13+). Zenith's own sounds are left out.
    case system
    /// The microphone, from `AVAudioEngine` on every supported macOS (ScreenCaptureKit's microphone output needs
    /// macOS 15; the owner chose one path for all versions).
    case microphone
}

/// Microphone permission as macOS reports it, read without asking.
public enum MicrophoneAccess: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Asking would end the process: this build has no `NSMicrophoneUsageDescription` (`swift run`).
    case unavailable
}

/// Why a sound the user asked for is not in the recording.
public enum RecordingAudioNotice: Sendable, Equatable {
    case microphoneDenied
    case microphoneUnavailable
    case noMicrophoneDevice

    public var message: String {
        switch self {
        case .microphoneDenied:
            return String(localized: "Recording without the microphone: Zenith is not allowed to use it. Allow it in System Settings → Privacy & Security → Microphone.")
        case .microphoneUnavailable:
            return String(localized: "Recording without the microphone: only the bundled Zenith.app can ask for it, not a build started with swift run.")
        case .noMicrophoneDevice:
            return String(localized: "Recording without the microphone: no microphone was found.")
        }
    }
}

/// Which sounds go into a recording, decided from the user's switches and the microphone permission.
public struct RecordingAudioPlan: Equatable, Sendable {
    public var sources: Set<RecordingAudioSource>
    public var notice: RecordingAudioNotice?

    public init(sources: Set<RecordingAudioSource>, notice: RecordingAudioNotice? = nil) {
        self.sources = sources
        self.notice = notice
    }

    public var capturesSystemAudio: Bool { sources.contains(.system) }
    public var capturesMicrophone: Bool { sources.contains(.microphone) }
    public var hasAudio: Bool { !sources.isEmpty }

    /// Whether the microphone permission has to be asked for before recording: only when the user turned the
    /// microphone on and macOS has never asked.
    public static func needsMicrophoneRequest(microphoneOn: Bool, access: MicrophoneAccess) -> Bool {
        microphoneOn && access == .notDetermined
    }

    /// The sounds to record. `access` is the permission after any request was answered.
    public static func resolve(systemAudio: Bool, microphone: Bool, access: MicrophoneAccess) -> RecordingAudioPlan {
        var sources: Set<RecordingAudioSource> = []
        if systemAudio { sources.insert(.system) }
        guard microphone else { return RecordingAudioPlan(sources: sources) }
        switch access {
        case .granted:
            sources.insert(.microphone)
            return RecordingAudioPlan(sources: sources)
        case .denied, .notDetermined:
            return RecordingAudioPlan(sources: sources, notice: .microphoneDenied)
        case .unavailable:
            return RecordingAudioPlan(sources: sources, notice: .microphoneUnavailable)
        }
    }
}

/// Sizes in pixels for the encoder.
public enum RecordingGeometry {
    /// The pixel size to record a `pointSize` area at, on a display with `scale` pixels per point. Both sides are
    /// even (the encoders need it) and the longest side fits `maximumDimension`, keeping the shape.
    public static func outputPixelSize(pointSize: CGSize, scale: CGFloat, maximumDimension: Int) -> (width: Int, height: Int) {
        let s = scale > 0 && scale.isFinite ? scale : 1
        var width = max(2, Double(pointSize.width * s))
        var height = max(2, Double(pointSize.height * s))
        let longest = max(width, height)
        let cap = Double(max(2, maximumDimension))
        if longest > cap {
            let factor = cap / longest
            width *= factor
            height *= factor
        }
        return (evenDown(width), evenDown(height))
    }

    private static func evenDown(_ value: Double) -> Int {
        let floored = Int(value.rounded(.down))
        return max(2, floored - floored % 2)
    }

    /// A bit rate that keeps screen text sharp without huge files.
    public static func averageBitRate(width: Int, height: Int, frameRate: Int, codec: RecordingVideoCodec) -> Int {
        let raw = Double(width * height * max(1, frameRate)) * codec.bitsPerPixel
        return Int(min(max(raw, 2_000_000), 80_000_000))
    }
}

/// Names for recorded files, like macOS names screenshots.
public enum RecordingFileNamer {
    public static func fileName(date: Date, format: RecordingFileFormat, prefix: String = "Zenith Recording", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// A URL in `folder` that does not exist yet: "name.mov", then "name 2.mov", "name 3.mov" …
    public static func uniqueURL(in folder: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

/// Everything the recording backend needs to start.
public struct RecordingRequest: Sendable, Equatable {
    public var target: RecordingTarget
    public var frameRate: RecordingFrameRate
    public var codec: RecordingVideoCodec
    public var format: RecordingFileFormat
    public var showsCursor: Bool
    public var highlightsClicks: Bool
    public var audio: RecordingAudioPlan
    public var outputURL: URL
    /// Pixels per point of the display the target is on.
    public var pixelScale: CGFloat
    /// The target's size in points (for a window, its frame when recording starts).
    public var pointSize: CGSize
    /// Zenith windows that must appear in the recording although Zenith's windows are excluded (the click rings).
    public var includedOwnWindowIDs: [CGWindowID]

    public init(
        target: RecordingTarget,
        frameRate: RecordingFrameRate = .fps30,
        codec: RecordingVideoCodec = .h264,
        format: RecordingFileFormat = .mov,
        showsCursor: Bool = true,
        highlightsClicks: Bool = false,
        audio: RecordingAudioPlan = RecordingAudioPlan(sources: []),
        outputURL: URL,
        pixelScale: CGFloat = 2,
        pointSize: CGSize,
        includedOwnWindowIDs: [CGWindowID] = []
    ) {
        self.target = target
        self.frameRate = frameRate
        self.codec = codec
        self.format = format
        self.showsCursor = showsCursor
        self.highlightsClicks = highlightsClicks
        self.audio = audio
        self.outputURL = outputURL
        self.pixelScale = pixelScale
        self.pointSize = pointSize
        self.includedOwnWindowIDs = includedOwnWindowIDs
    }

    public var outputPixelSize: (width: Int, height: Int) {
        RecordingGeometry.outputPixelSize(pointSize: pointSize, scale: pixelScale, maximumDimension: codec.maximumDimension)
    }
}

/// A finished recording.
public struct RecordingResult: Sendable, Equatable {
    public var url: URL
    public var duration: TimeInterval

    public init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }
}

public enum ScreenRecordingError: Error, Equatable, Sendable, LocalizedError {
    case permissionDenied
    case targetNotFound
    case alreadyRecording
    case notRecording
    case noFramesRecorded
    case writerFailed(String)
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Zenith needs the Screen Recording permission to record the screen.")
        case .targetNotFound:
            return String(localized: "The screen or window to record is no longer there.")
        case .alreadyRecording:
            return String(localized: "A recording is already running.")
        case .notRecording:
            return String(localized: "Nothing is being recorded.")
        case .noFramesRecorded:
            return String(localized: "The recording has no picture: macOS sent no frames.")
        case .writerFailed(let reason), .streamFailed(let reason):
            return reason
        }
    }
}

// MARK: - Window under the pointer

/// A window as `CGWindowListCopyWindowInfo` describes it (front to back), reduced to what picking needs.
public struct OnScreenWindowInfo: Equatable, Sendable {
    public var windowID: CGWindowID
    public var ownerPID: pid_t
    public var layer: Int
    /// Global CoreGraphics coordinates (origin at the top-left of the main display), in points.
    public var bounds: CGRect
    public var alpha: Double

    public init(windowID: CGWindowID, ownerPID: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`.
    public init?(dictionary: [String: Any]) {
        guard let number = dictionary[kCGWindowNumber as String] as? NSNumber,
              let pid = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = dictionary[kCGWindowLayer as String] as? NSNumber,
              let boundsDict = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        self.windowID = CGWindowID(number.uint32Value)
        self.ownerPID = pid_t(pid.int32Value)
        self.layer = layer.intValue
        self.bounds = bounds
        self.alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    }
}

public enum WindowPicker {
    /// The front-most ordinary window (layer 0, visible, not tiny, not Zenith's) under `point`. `windows` must be in
    /// front-to-back order, as `CGWindowListCopyWindowInfo` returns them.
    public static func window(at point: CGPoint, in windows: [OnScreenWindowInfo], excludingPID: pid_t) -> OnScreenWindowInfo? {
        windows.first { info in
            info.layer == 0
                && info.ownerPID != excludingPID
                && info.alpha > 0.01
                && info.bounds.width >= 40 && info.bounds.height >= 40
                && info.bounds.contains(point)
        }
    }
}
