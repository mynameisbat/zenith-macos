import Foundation
import CoreGraphics

/// Finite state machine for marquee interaction.
public enum MarqueeState: Equatable, Sendable {
    case idle
    case dragging(start: CGPoint, current: CGPoint)
    case selected(rect: CGRect)
    case dismissed
}

/// Pure geometric mathematics and formatting for screen capture marquee.
public struct MarqueeGeometry: Sendable {
    /// Normalizes arbitrary drag points into a canonical positive bounding CGRect.
    public static func normalizeRect(from p1: CGPoint, to p2: CGPoint) -> CGRect {
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let width = abs(p2.x - p1.x)
        let height = abs(p2.y - p1.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// Clamps rectangle within specified bounds.
    public static func clampRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clampedMinX = max(bounds.minX, min(rect.minX, bounds.maxX))
        let clampedMinY = max(bounds.minY, min(rect.minY, bounds.maxY))
        let clampedMaxX = max(bounds.minX, min(rect.maxX, bounds.maxX))
        let clampedMaxY = max(bounds.minY, min(rect.maxY, bounds.maxY))
        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: max(0, clampedMaxX - clampedMinX),
            height: max(0, clampedMaxY - clampedMinY)
        )
    }

    /// Calculates intersection with a screen frame.
    public static func intersectScreen(rect: CGRect, screenFrame: CGRect) -> CGRect? {
        let intersection = rect.intersection(screenFrame)
        return intersection.isNull || intersection.isEmpty ? nil : intersection
    }

    /// Converts global screen rect to local view coordinates.
    public static func toLocalCoordinates(globalRect: CGRect, screenOrigin: CGPoint) -> CGRect {
        CGRect(
            x: globalRect.origin.x - screenOrigin.x,
            y: globalRect.origin.y - screenOrigin.y,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    /// Formats dimension strings in points and physical backing pixels.
    public static func formatDimensionText(
        rect: CGRect,
        scaleFactor: CGFloat
    ) -> (pointsText: String, pixelsText: String, fullText: String) {
        let ptW = Int(round(rect.width))
        let ptH = Int(round(rect.height))
        let pxW = Int(round(rect.width * scaleFactor))
        let pxH = Int(round(rect.height * scaleFactor))

        let ptStr = "\(ptW) × \(ptH) pt"
        let pxStr = "(\(pxW) × \(pxH) px)"
        let fullStr = "\(ptStr) \(pxStr)"
        return (ptStr, pxStr, fullStr)
    }

    /// Calculates non-obscuring position for dimension HUD badge relative to selection rect.
    public static func calculateBadgePosition(
        selectionRect: CGRect,
        badgeSize: CGSize,
        screenBounds: CGRect,
        margin: CGFloat = 8
    ) -> CGPoint {
        // Horizontally center with selection rect
        var x = selectionRect.midX - badgeSize.width / 2.0
        x = max(screenBounds.minX + margin, min(x, screenBounds.maxX - badgeSize.width - margin))

        // Default: place below selection bottom (minY in AppKit coordinates)
        var y = selectionRect.minY - badgeSize.height - margin

        // Flip above selection if below screen bottom
        if y < screenBounds.minY + margin {
            y = selectionRect.maxY + margin
        }

        // Fallback: if top also exceeds screen bounds, place inside selection
        if y + badgeSize.height > screenBounds.maxY - margin {
            y = selectionRect.minY + margin
        }

        return CGPoint(x: x, y: y)
    }
}

/// State machine engine coordinating selection marquee interactions.
public final class MarqueeSelectionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: MarqueeState = .idle

    public var state: MarqueeState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public init() {}

    public var isDragging: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .dragging = _state { return true }
        return false
    }

    public var normalizedRect: CGRect {
        lock.lock()
        defer { lock.unlock() }
        switch _state {
        case .idle, .dismissed:
            return .zero
        case let .dragging(start, current):
            if start == current { return .zero }
            return MarqueeGeometry.normalizeRect(from: start, to: current)
        case let .selected(rect):
            return rect
        }
    }

    public func beginDrag(at point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        _state = .dragging(start: point, current: point)
    }

    public func updateDrag(to point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        guard case let .dragging(start, _) = _state else { return }
        _state = .dragging(start: start, current: point)
    }

    @discardableResult
    public func endDrag(minimumDimension: CGFloat = 3.0) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .dragging(start, current) = _state else { return nil }
        let rect = MarqueeGeometry.normalizeRect(from: start, to: current)
        if rect.width >= minimumDimension && rect.height >= minimumDimension {
            _state = .selected(rect: rect)
            return rect
        } else {
            _state = .idle
            return nil
        }
    }

    @discardableResult
    public func handleEscapeKey() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _state == .dismissed {
            return false
        }
        _state = .dismissed
        return true
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _state = .idle
    }
}
