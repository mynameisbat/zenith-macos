import CoreGraphics

/// Lets a plain mouse wheel scroll the clipboard strip, which only scrolls sideways: a wheel sends vertical deltas, and
/// a horizontal scroll view ignores them. Trackpads and Magic Mice (precise deltas, gesture phases, momentum) already
/// scroll sideways natively and are left alone.
public enum ClipboardWheelScroll {
    /// How far one wheel unit (a notch at normal speed is about 1) moves the row.
    public static let pointsPerWheelUnit: CGFloat = 40

    /// How much to move the row's content offset, or nil when the event is not a vertical-only wheel event.
    /// `scrollingDeltaY` already follows the "natural scrolling" setting, so wheel-down (negative) moves toward the
    /// later cards (a larger offset) whichever way the user set it.
    public static func offsetChange(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool,
        hasPhase: Bool
    ) -> CGFloat? {
        guard !hasPreciseDeltas, !hasPhase else { return nil }
        guard scrollingDeltaY != 0, abs(scrollingDeltaY) > abs(scrollingDeltaX) else { return nil }
        return -scrollingDeltaY * pointsPerWheelUnit
    }

    /// The offset after `change`, kept inside the content.
    public static func clampedOffset(current: CGFloat, change: CGFloat, contentWidth: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        min(max(0, current + change), max(0, contentWidth - visibleWidth))
    }
}
