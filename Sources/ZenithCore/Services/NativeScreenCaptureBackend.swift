import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit
import Synchronization

/// Windows a capture leaves out: the dimmed overlay Zenith puts over every screen while the user picks an area.
/// `CaptureOverlayController` (App) registers its panels here while they are on screen. ScreenCaptureKit answers tens
/// of milliseconds after it is asked, by which time the overlay is showing, so without this the loupe's cached image
/// would be the screen darkened by the overlay.
public enum ScreenCaptureExclusions {
    private static let windowIDs = Mutex<Set<CGWindowID>>([])

    public static func set(_ ids: some Sequence<CGWindowID>) {
        windowIDs.withLock { $0 = Set(ids) }
    }

    public static var current: Set<CGWindowID> {
        windowIDs.withLock { $0 }
    }
}

/// Production macOS screen capture backend: ScreenCaptureKit (`SCScreenshotManager`), at the display's pixel size.
/// (The CoreGraphics call it used before, `CGDisplayCreateImage`, is obsolete since macOS 15.)
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
        do {
            // A display ID that went stale (a display was unplugged) falls back to the first display.
            if let image = try await captureViaScreenCaptureKit(displayID: effectiveID) {
                return image
            }
        } catch {
            throw ScreenCaptureError.captureFailed(reason: "ScreenCaptureKit failed for displayID \(effectiveID): \(error.localizedDescription)")
        }
        throw ScreenCaptureError.captureFailed(reason: "ScreenCaptureKit found no display for displayID \(effectiveID)")
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

    /// Captures a display (the first one if `displayID` is not among them), without the windows in
    /// `ScreenCaptureExclusions`; `nil` if there is no display at all. Public so the `--check-screen-capture`
    /// diagnostic can call it.
    public func captureViaScreenCaptureKit(displayID: CGDirectDisplayID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            return nil
        }
        let excluded = ScreenCaptureExclusions.current
        let excludedWindows = excluded.isEmpty ? [] : content.windows.filter { excluded.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        let size = Self.capturePixelSize(pointWidth: display.width, pointHeight: display.height, pointPixelScale: filter.pointPixelScale)
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
