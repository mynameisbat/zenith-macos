import Foundation
import CoreGraphics

/// Service handling coordinate system transformations between AppKit (bottom-left origin)
/// and CoreGraphics/Quartz (top-left origin), multi-display offsets, and Retina scale factors.
public struct CoordinateTranslationService: Sendable {

    // MARK: - Point Transformations

    /// Translates an AppKit global point (Cartesian, bottom-left origin) to
    /// CoreGraphics global display coordinates (top-left origin).
    public static func flipAppKitToCoreGraphics(
        point: CGPoint,
        primaryScreenHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Translates a CoreGraphics global point (top-left origin) to
    /// AppKit global display coordinates (bottom-left origin).
    public static func flipCoreGraphicsToAppKit(
        point: CGPoint,
        primaryScreenHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    // MARK: - Rect Transformations

    /// Translates an AppKit global rectangle to CoreGraphics global display coordinates.
    /// In AppKit, rect.origin is bottom-left. In CoreGraphics, origin is top-left.
    public static func flipAppKitToCoreGraphics(
        rect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let cgY = primaryScreenHeight - (rect.origin.y + rect.size.height)
        return CGRect(
            x: rect.origin.x,
            y: cgY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Translates a CoreGraphics global rectangle to AppKit global display coordinates.
    public static func flipCoreGraphicsToAppKit(
        rect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let appKitY = primaryScreenHeight - (rect.origin.y + rect.size.height)
        return CGRect(
            x: rect.origin.x,
            y: appKitY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    // MARK: - Retina Scaling (Points <-> Physical Backing Pixels)

    /// Converts a logical point rectangle to physical backing pixels given display scale.
    public static func pointsToPhysicalPixels(
        rect: CGRect,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )
    }

    /// Converts a physical backing pixel rectangle back to logical points.
    public static func physicalPixelsToPoints(
        rect: CGRect,
        scale: CGFloat
    ) -> CGRect {
        guard scale > 0 else { return rect }
        return CGRect(
            x: rect.origin.x / scale,
            y: rect.origin.y / scale,
            width: rect.size.width / scale,
            height: rect.size.height / scale
        )
    }

    /// Converts a logical point to physical backing pixels.
    public static func pointsToPhysicalPixels(
        point: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// Converts physical backing pixels to a logical point.
    public static func physicalPixelsToPoints(
        point: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }

    // MARK: - Bounds Clamping

    /// Clamps rectangle strictly inside container bounds.
    public static func clamp(
        rect: CGRect,
        to bounds: CGRect
    ) -> CGRect {
        let clampedMinX = max(bounds.minX, min(rect.minX, bounds.maxX))
        let clampedMinY = max(bounds.minY, min(rect.minY, bounds.maxY))
        let clampedMaxX = max(bounds.minX, min(rect.maxX, bounds.maxX))
        let clampedMaxY = max(bounds.minY, min(rect.maxY, bounds.maxY))
        let width = max(0, min(clampedMaxX - clampedMinX, bounds.maxX - clampedMinX))
        let height = max(0, min(clampedMaxY - clampedMinY, bounds.maxY - clampedMinY))
        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: width,
            height: height
        )
    }

    /// Translates an AppKit global selection rect to target display-local CoreGraphics rect.
    public static func appKitToDisplayLocalCoreGraphics(
        rect: CGRect,
        displayFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let globalCG = flipAppKitToCoreGraphics(rect: rect, primaryScreenHeight: primaryScreenHeight)
        let displayCGOrigin = flipAppKitToCoreGraphics(
            point: CGPoint(x: displayFrame.minX, y: displayFrame.maxY),
            primaryScreenHeight: primaryScreenHeight
        )
        return CGRect(
            x: globalCG.origin.x - displayCGOrigin.x,
            y: globalCG.origin.y - displayCGOrigin.y,
            width: globalCG.width,
            height: globalCG.height
        )
    }

    // MARK: - Loupe & Cursor Coordinate Mapping

    /// Translates an AppKit global cursor coordinate (bottom-left origin) to Cartesian
    /// physical backing pixels relative to the display containing the cursor.
    ///
    /// - Parameters:
    ///   - cursor: Global AppKit mouse location in logical points.
    ///   - screenFrame: The bounding frame of the target display in AppKit points.
    ///   - scale: The backing scale factor (e.g. 1.0, 2.0).
    /// - Returns: A Cartesian physical pixel coordinate (bottom-left origin) suitable for `LoupePixelSampler`.
    public static func cursorToPhysicalPixels(
        cursor: CGPoint,
        screenFrame: CGRect,
        scale: CGFloat
    ) -> CGPoint {
        let localX = cursor.x - screenFrame.minX
        let localY = cursor.y - screenFrame.minY
        let effectiveScale = scale > 0 ? scale : 1.0
        return CGPoint(x: localX * effectiveScale, y: localY * effectiveScale)
    }
}
