import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Production macOS screen capture backend using CoreGraphics Quartz Display Services (CGDisplayCreateImage)
/// and ScreenCaptureKit (SCScreenshotManager) for modern macOS 14+ Retina display capture.
public final class NativeScreenCaptureBackend: ScreenCaptureBackendProtocol, Sendable {
    public init() {}

    /// Real-time authorization check against macOS TCC Screen Recording permissions.
    public var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Captures the full surface of the specified display.
    /// - Parameter displayID: Direct display identifier.
    /// - Returns: High-resolution native CGImage of the display.
    /// - Throws: `ScreenCaptureError.permissionDenied` if unauthorized, or `.captureFailed` if WindowServer fails.
    public func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }

        let effectiveID = (displayID != 0) ? displayID : CGMainDisplayID()

        // 1. Primary native CoreGraphics display capture (<1ms latency)
        if let image = CGDisplayCreateImage(effectiveID) {
            return image
        }

        // 2. Modern ScreenCaptureKit fallback for macOS 14+
        if let scImage = try? await captureViaScreenCaptureKit(displayID: effectiveID) {
            return scImage
        }

        // 3. Fallback to main display if external display ID was stale
        if effectiveID != CGMainDisplayID(), let mainImage = CGDisplayCreateImage(CGMainDisplayID()) {
            return mainImage
        }

        throw ScreenCaptureError.captureFailed(reason: "CGDisplayCreateImage and ScreenCaptureKit returned nil for displayID \(effectiveID)")
    }

    /// Captures a cropped region of the specified display.
    /// - Parameters:
    ///   - rect: Bounding box in display-local coordinates (points).
    ///   - displayID: Direct display identifier.
    /// - Returns: Cropped CGImage matching the target region at Retina pixel resolution.
    /// - Throws: `ScreenCaptureError.permissionDenied` or `ScreenCaptureError.captureFailed`.
    public func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        guard hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }

        let effectiveID = (displayID != 0) ? displayID : CGMainDisplayID()
        let bounds = CGDisplayBounds(effectiveID)
        let displayWidth = max(1.0, bounds.width > 0 ? bounds.width : 1920.0)
        let displayHeight = max(1.0, bounds.height > 0 ? bounds.height : 1080.0)

        // Capture full display first, then perform crisp pixel-accurate crop
        let fullImage = try await captureDisplay(displayID: effectiveID)

        // A region that cannot be cut out is an error. (It used to hand back the whole screen, which is more than
        // the user chose to capture.)
        guard let cropRect = Self.pixelCropRect(
                for: rect,
                imageWidth: fullImage.width,
                imageHeight: fullImage.height,
                displaySize: CGSize(width: displayWidth, height: displayHeight)
              ),
              let cropped = fullImage.cropping(to: cropRect) else {
            throw ScreenCaptureError.invalidRegion(rect)
        }
        return cropped
    }

    /// The part of the display image, in pixels, that a region in display points covers; `nil` if none of it is on
    /// the display.
    static func pixelCropRect(for rect: CGRect, imageWidth: Int, imageHeight: Int, displaySize: CGSize) -> CGRect? {
        let scaleX = CGFloat(imageWidth) / displaySize.width
        let scaleY = CGFloat(imageHeight) / displaySize.height

        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        let crop = pixelRect.intersection(imageBounds)
        return crop.isNull || crop.isEmpty ? nil : crop
    }

    // MARK: - ScreenCaptureKit Helper

    /// The size in pixels a capture of a display should have. ScreenCaptureKit reports a display's size in points but
    /// takes the capture size in pixels, so using the points gives a half-resolution image on a Retina display.
    static func capturePixelSize(pointWidth: Int, pointHeight: Int, pointPixelScale: Float) -> (width: Int, height: Int) {
        let scale = pointPixelScale > 0 ? CGFloat(pointPixelScale) : 1
        return (max(1, Int((CGFloat(pointWidth) * scale).rounded())), max(1, Int((CGFloat(pointHeight) * scale).rounded())))
    }

    /// Captures a display with ScreenCaptureKit alone. This is the fallback of `captureDisplay`; it is public so the
    /// `--check-screen-capture` diagnostic can exercise it directly.
    public func captureViaScreenCaptureKit(displayID: CGDirectDisplayID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            return nil
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let size = Self.capturePixelSize(pointWidth: display.width, pointHeight: display.height, pointPixelScale: filter.pointPixelScale)
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
