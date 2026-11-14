import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Seams

/// Takes a picture of the chosen area. The live one captures the screen; tests return parts of a tall image.
public protocol ScrollFrameGrabbing: Sendable {
    func grab() async throws -> CGImage
}

/// Scrolls the content under a point. The live one posts scroll-wheel events (that needs Accessibility); tests
/// record the requests.
public protocol ScrollEventPosting: Sendable {
    /// Whether events can be posted (Accessibility is allowed).
    var canPost: Bool { get }
    /// Scrolls the content under `point` (global CoreGraphics coordinates, points) down by `points`.
    func scrollDown(points: Int, at point: CGPoint)
}

/// Posts real scroll-wheel events at a point.
public struct CGScrollEventPoster: ScrollEventPosting {
    public init() {}

    public var canPost: Bool { AXIsProcessTrusted() }

    public func scrollDown(points: Int, at point: CGPoint) {
        // The scroll goes to the window under the pointer, so the pointer is moved there first. A few smaller events
        // work with more apps than one large one.
        CGWarpMouseCursorPosition(point)
        let steps = 4
        let each = max(1, points / steps)
        for _ in 0..<steps {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-each), wheel2: 0, wheel3: 0) else { continue }
            event.location = point
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Session

/// Captures an area while its content scrolls and joins the frames into one tall picture.
///
/// Automatic: scrolls by a bit more than half the area per step, waits for the content to settle, captures, and stops
/// when two captures in a row show nothing new (the end of the page), at the height limit, or when told to finish.
/// Manual: the user scrolls; frames are taken a few times a second and the ones that moved are added.
@MainActor
public final class ScrollingCaptureSession: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case automatic
        case manual
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case finished
        case cancelled
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Height of the picture so far, in pixels.
    @Published public private(set) var capturedHeight = 0
    @Published public private(set) var frameCount = 0
    /// Set when a frame could not be placed (the user scrolled faster than a frame).
    @Published public private(set) var lostTrack = false
    @Published public private(set) var reachedLimit = false

    public let mode: Mode
    private let grabber: ScrollFrameGrabbing
    private let poster: ScrollEventPosting
    private let scrollPoint: CGPoint
    private let stepPoints: Int
    private let pixelScale: CGFloat
    private let settleDelay: Duration
    private let manualInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var stitcher: ScrollStitcher
    private var finishRequested = false
    private var cancelRequested = false
    /// Automatic mode gives up after this many steps whatever happens.
    private let maxSteps: Int

    public init(
        mode: Mode,
        grabber: ScrollFrameGrabbing,
        poster: ScrollEventPosting,
        scrollPoint: CGPoint,
        areaHeightPoints: CGFloat,
        pixelScale: CGFloat,
        maxHeightPixels: Int = 30_000,
        settleDelay: Duration = .milliseconds(450),
        manualInterval: Duration = .milliseconds(200),
        maxSteps: Int = 400,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.mode = mode
        self.grabber = grabber
        self.poster = poster
        self.scrollPoint = scrollPoint
        self.stepPoints = Self.stepPoints(forAreaHeight: areaHeightPoints)
        self.pixelScale = pixelScale > 0 ? pixelScale : 1
        self.settleDelay = settleDelay
        self.manualInterval = manualInterval
        self.maxSteps = maxSteps
        self.sleep = sleep
        self.stitcher = ScrollStitcher(maxHeight: maxHeightPixels)
    }

    /// How far to scroll per step: 60% of the area, so consecutive frames always overlap.
    public static func stepPoints(forAreaHeight height: CGFloat) -> Int {
        max(20, Int((height * 0.6).rounded()))
    }

    /// Runs until the end of the content, the limit, `finish()` or `cancel()`. Returns the picture, or `nil` when
    /// cancelled or nothing was captured.
    public func run() async -> CGImage? {
        guard phase == .idle else { return nil }
        phase = .capturing
        do {
            try await add(grabber.grab(), expected: nil)
            switch mode {
            case .automatic: try await runAutomatic()
            case .manual: try await runManual()
            }
        } catch is CancellationError {
            cancelRequested = true
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return nil
        }
        if cancelRequested {
            phase = .cancelled
            return nil
        }
        phase = .finished
        return stitcher.makeImage()
    }

    /// Stops and keeps what was captured.
    public func finish() { finishRequested = true }

    /// Stops and throws the capture away.
    public func cancel() { cancelRequested = true }

    private var shouldStop: Bool { finishRequested || cancelRequested || reachedLimit }

    private func runAutomatic() async throws {
        var unchangedInARow = 0
        var steps = 0
        let expected = Int((CGFloat(stepPoints) * pixelScale).rounded())
        while !shouldStop, steps < maxSteps {
            steps += 1
            poster.scrollDown(points: stepPoints, at: scrollPoint)
            try await sleep(settleDelay)
            if shouldStop { break }
            let result = try await add(grabber.grab(), expected: expected)
            if result == .unchanged {
                unchangedInARow += 1
                if unchangedInARow >= 2 { break }  // the end of the page
            } else {
                unchangedInARow = 0
            }
        }
    }

    private func runManual() async throws {
        while !shouldStop {
            try await sleep(manualInterval)
            if shouldStop { break }
            _ = try await add(grabber.grab(), expected: nil)
        }
    }

    @discardableResult
    private func add(_ frame: CGImage, expected: Int?) async throws -> ScrollStitcher.AddResult {
        let result = stitcher.add(frame, expectedOffset: expected)
        switch result {
        case .noMatch:
            lostTrack = true
        case .reachedLimit:
            reachedLimit = true
        case .appended:
            lostTrack = false
        case .first, .unchanged:
            break
        }
        capturedHeight = stitcher.height
        frameCount = stitcher.frameCount
        if stitcher.height >= stitcher.maxHeight { reachedLimit = true }
        return result
    }
}
