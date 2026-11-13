import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// After a recording: cut its start and end (trim) and turn it into a GIF. The time arithmetic is pure and tested; the
// AVFoundation work only reads the recorded file and writes a new one beside it.

/// The part of a clip to keep, in seconds from its start.
public struct TrimRange: Equatable, Sendable {
    public var start: Double
    public var end: Double

    /// The shortest clip a trim may leave.
    public static let minimumLength: Double = 0.1

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { max(0, end - start) }

    /// The range made valid for a clip of `duration` seconds: inside the clip, in order, and at least
    /// `minimumLength` long (or the whole clip when it is shorter than that). `nil` for an empty clip.
    public static func clamped(start: Double, end: Double, duration: Double) -> TrimRange? {
        guard duration.isFinite, duration > 0 else { return nil }
        var s = start.isFinite ? min(max(0, start), duration) : 0
        var e = end.isFinite ? min(max(0, end), duration) : duration
        if e < s { swap(&s, &e) }
        if duration <= minimumLength { return TrimRange(start: 0, end: duration) }
        if e - s < minimumLength {
            e = min(duration, s + minimumLength)
            s = e - minimumLength
        }
        return TrimRange(start: s, end: e)
    }

    /// Whether the range keeps the whole clip (so trimming would change nothing).
    public func isWholeClip(duration: Double, tolerance: Double = 0.01) -> Bool {
        start <= tolerance && end >= duration - tolerance
    }

    public var cmTimeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

// MARK: - GIF

public struct GIFExportOptions: Equatable, Sendable {
    public static let defaultMaxWidth = 640
    public static let defaultFrameRate = 12
    public static let widthRange = 160...1280
    public static let frameRateRange = 5...20
    /// More frames than this make a GIF too large to share; a longer clip gets fewer frames per second instead.
    public static let defaultMaxFrames = 600

    public var maxWidth: Int
    public var framesPerSecond: Int
    public var maxFrames: Int

    public init(maxWidth: Int = defaultMaxWidth, framesPerSecond: Int = defaultFrameRate, maxFrames: Int = defaultMaxFrames) {
        self.maxWidth = Self.clampedWidth(maxWidth)
        self.framesPerSecond = Self.clampedFrameRate(framesPerSecond)
        self.maxFrames = max(1, maxFrames)
    }

    public static func clampedWidth(_ value: Int) -> Int { min(max(value, widthRange.lowerBound), widthRange.upperBound) }
    public static func clampedFrameRate(_ value: Int) -> Int { min(max(value, frameRateRange.lowerBound), frameRateRange.upperBound) }
}

/// Which moments of the clip become GIF frames, and how long each is shown.
public struct GIFFramePlan: Equatable, Sendable {
    /// Seconds from the start of the source clip.
    public var times: [Double]
    /// Seconds each frame stays on screen.
    public var frameDelay: Double

    /// Evenly spaced frames over `range` at `options.framesPerSecond`, thinned to `options.maxFrames` for a long clip.
    public static func make(range: TrimRange, options: GIFExportOptions) -> GIFFramePlan {
        let length = range.length
        guard length > 0 else { return GIFFramePlan(times: [range.start], frameDelay: 0.1) }
        var step = 1.0 / Double(options.framesPerSecond)
        var count = Int((length / step).rounded(.up))
        if count > options.maxFrames {
            count = options.maxFrames
            step = length / Double(count)
        }
        count = max(1, count)
        let times = (0..<count).map { range.start + Double($0) * step }.filter { $0 < range.end || $0 == range.start }
        // GIF delays are stored in hundredths of a second.
        let delay = max(0.02, (step * 100).rounded() / 100)
        return GIFFramePlan(times: times, frameDelay: delay)
    }

    /// The GIF's pixel size: the source scaled down to `maxWidth` (never up), keeping its shape.
    public static func outputSize(source: CGSize, maxWidth: Int) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1, height: 1) }
        let width = min(source.width, CGFloat(max(1, maxWidth)))
        let height = (source.height * width / source.width).rounded()
        return CGSize(width: width.rounded(), height: max(1, height))
    }
}

public enum RecordingExportError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "The file has no video.")
        case .exportFailed(let reason): return reason
        }
    }
}

public enum RecordingExporter {
    /// The display size of the clip's video (its natural size with any rotation applied).
    public static func videoSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingExportError.noVideoTrack }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    public static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    /// Writes the `range` part of `source` to `destination` without re-encoding.
    public static func trim(_ source: URL, range: TrimRange, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingExportError.exportFailed(String(localized: "This file cannot be trimmed."))
        }
        session.outputURL = destination
        session.outputFileType = destination.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        session.timeRange = range.cmTimeRange
        session.shouldOptimizeForNetworkUse = true
        let box = ExportSessionBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            throw RecordingExportError.exportFailed(session.error?.localizedDescription ?? String(localized: "Trimming failed."))
        }
    }

    /// Writes the `range` part of `source` as a looping GIF.
    public static func exportGIF(
        _ source: URL,
        range: TrimRange,
        options: GIFExportOptions,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: source)
        let size = GIFFramePlan.outputSize(source: try await videoSize(of: source), maxWidth: options.maxWidth)
        let plan = GIFFramePlan.make(range: range, options: options)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        let tolerance = CMTime(seconds: plan.frameDelay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, plan.times.count, nil) else {
            throw RecordingExportError.exportFailed(String(localized: "The GIF file could not be created."))
        }
        let fileProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
        CGImageDestinationSetProperties(destinationRef, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: plan.frameDelay,
            kCGImagePropertyGIFUnclampedDelayTime as String: plan.frameDelay
        ]] as CFDictionary

        for (index, time) in plan.times.enumerated() {
            try Task.checkCancellation()
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            CGImageDestinationAddImage(destinationRef, image, frameProperties)
            progress?(Double(index + 1) / Double(plan.times.count))
        }
        guard CGImageDestinationFinalize(destinationRef) else {
            throw RecordingExportError.exportFailed(String(localized: "The GIF file could not be written."))
        }
    }

    /// "Name.mov" → "Name (trimmed).mov", or "Name.gif", free in the same folder.
    public static func siblingURL(for source: URL, suffix: String?, pathExtension: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let name = suffix.map { "\(base) (\($0))" } ?? base
        return RecordingFileNamer.uniqueURL(in: folder, fileName: "\(name).\(pathExtension)")
    }
}

/// `AVAssetExportSession` is not `Sendable`; it is only touched before the export starts and after it ends.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
