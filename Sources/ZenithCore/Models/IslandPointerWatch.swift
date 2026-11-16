import CoreGraphics
import Foundation

/// Decides when the island needs to see every mouse and scroll event.
///
/// A global event monitor makes the window server send this process each event the user produces anywhere, which
/// cost 4–10% of a core whenever the pointer moved or something scrolled. The island only cares while the pointer
/// is near it, so the pointer's position is read on a slow timer instead (no events involved) and the monitors are
/// installed only while it is inside `zone` or the island is already taking mouse events.
public struct IslandPointerWatch: Sendable {
    /// How often the position is read while the pointer is moving. Also the longest a hover can start late.
    public static let movingInterval: TimeInterval = 0.1
    /// How often it is read once the pointer has rested for `restAfter`.
    public static let restingInterval: TimeInterval = 0.5
    public static let restAfter: TimeInterval = 2
    /// How far around the island's panel the monitors are already on, so a pointer resting close by is followed
    /// event by event and not at the resting rate.
    public static let zoneMargin: CGFloat = 80

    public struct Decision: Equatable, Sendable {
        /// Install the global mouse and scroll monitors (true) or remove them (false).
        public var wantsEventMonitors: Bool
        /// The pointer is somewhere else than at the last reading.
        public var moved: Bool
        /// When to read the position again.
        public var nextInterval: TimeInterval
    }

    private var lastLocation: CGPoint?
    private var lastMoveTime: TimeInterval?

    public init() {}

    public static func zone(around panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: -zoneMargin, dy: -zoneMargin)
    }

    /// - Parameters:
    ///   - zone: where the monitors must be on, in screen coordinates.
    ///   - isEngaged: the island is taking mouse events (hovered, open, a preview showing), wherever the pointer is.
    ///   - now: a monotonic time in seconds.
    public mutating func sample(location: CGPoint, zone: CGRect, isEngaged: Bool, now: TimeInterval) -> Decision {
        let moved = lastLocation != location
        lastLocation = location
        if moved || lastMoveTime == nil { lastMoveTime = now }
        let resting = now - (lastMoveTime ?? now) >= Self.restAfter
        return Decision(
            wantsEventMonitors: isEngaged || zone.contains(location),
            moved: moved,
            nextInterval: resting ? Self.restingInterval : Self.movingInterval
        )
    }
}
