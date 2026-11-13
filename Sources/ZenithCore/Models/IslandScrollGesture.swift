import Foundation

/// Turns the scroll events over the island into at most one action per swipe: pull down to open, push up to close,
/// sideways to change track.
///
/// Distances are in the direction the fingers move (`fingersDown`, `fingersRight`), so the gesture feels the same
/// with "natural" scrolling on or off; the caller does that conversion from `NSEvent`.
public struct IslandScrollGesture: Sendable {
    public enum Action: Sendable, Equatable {
        case open, close, nextTrack, previousTrack
    }

    public enum Phase: Sendable, Equatable {
        /// A trackpad or Magic Mouse touch started, moved, or lifted.
        case began, changed, ended
        /// The inertia that follows a lifted swipe. Never part of a decision.
        case momentum
        /// A wheel without touch phases: a pause between notches starts a new swipe.
        case none
    }

    public struct Sample: Sendable, Equatable {
        public var fingersRight: Double
        public var fingersDown: Double
        public var phase: Phase
        public var timestamp: TimeInterval

        public init(fingersRight: Double, fingersDown: Double, phase: Phase, timestamp: TimeInterval) {
            self.fingersRight = fingersRight
            self.fingersDown = fingersDown
            self.phase = phase
            self.timestamp = timestamp
        }
    }

    /// How far the fingers must travel before a swipe counts, in points.
    public static let verticalThreshold = 24.0
    public static let horizontalThreshold = 40.0
    /// Movement before the swipe is taken to be vertical or horizontal.
    static let axisLock = 8.0
    /// A wheel that rests this long starts over.
    static let wheelPause: TimeInterval = 0.3

    private enum Axis { case horizontal, vertical }

    private var axis: Axis?
    private var travelRight = 0.0
    private var travelDown = 0.0
    private var hasFired = false
    private var lastTimestamp: TimeInterval?

    public init() {}

    /// Feeds one scroll event. `isExpanded` decides what a vertical swipe may do; `allowsTrackChange` is false where
    /// a sideways swipe belongs to something else (the shelf scrolls sideways) or nothing is playing.
    public mutating func handle(_ sample: Sample, isExpanded: Bool, allowsTrackChange: Bool) -> Action? {
        defer { lastTimestamp = sample.timestamp }

        switch sample.phase {
        case .momentum:
            return nil
        case .began:
            reset()
        case .none:
            if let last = lastTimestamp, sample.timestamp - last > Self.wheelPause { reset() }
            if lastTimestamp == nil { reset() }
        case .ended:
            reset()
            return nil
        case .changed:
            break
        }
        guard !hasFired else { return nil }

        travelRight += sample.fingersRight
        travelDown += sample.fingersDown

        if axis == nil, max(abs(travelRight), abs(travelDown)) >= Self.axisLock {
            axis = abs(travelRight) > abs(travelDown) ? .horizontal : .vertical
        }

        let action: Action?
        switch axis {
        case .vertical where travelDown >= Self.verticalThreshold && !isExpanded:
            action = .open
        case .vertical where travelDown <= -Self.verticalThreshold && isExpanded:
            action = .close
        case .horizontal where allowsTrackChange && travelRight <= -Self.horizontalThreshold:
            action = .nextTrack
        case .horizontal where allowsTrackChange && travelRight >= Self.horizontalThreshold:
            action = .previousTrack
        default:
            action = nil
        }
        if action != nil { hasFired = true }
        return action
    }

    private mutating func reset() {
        axis = nil
        travelRight = 0
        travelDown = 0
        hasFired = false
    }
}
