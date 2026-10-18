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

        let scaleX = CGFloat(fullImage.width) / displayWidth
        let scaleY = CGFloat(fullImage.height) / displayHeight

        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral

        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(fullImage.width), height: CGFloat(fullImage.height))
        let cropRect = pixelRect.intersection(imageBounds)

        if !cropRect.isNull && !cropRect.isEmpty, let cropped = fullImage.cropping(to: cropRect) {
            return cropped
        }
        return fullImage
    }

    // MARK: - ScreenCaptureKit Helper

    private func captureViaScreenCaptureKit(displayID: CGDirectDisplayID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            return nil
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
