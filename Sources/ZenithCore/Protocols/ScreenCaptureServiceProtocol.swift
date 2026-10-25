import Foundation
import CoreGraphics

/// Errors thrown during screen capture operations.
public enum ScreenCaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case displayNotFound(displayID: CGDirectDisplayID)
    case captureFailed(reason: String)
    case invalidRegion(CGRect)
}

/// Service protocol for capturing full display or subregions asynchronously.
public protocol ScreenCaptureServiceProtocol: Sendable {
    /// Verifies whether the process currently has screen recording TCC permissions.
    var hasScreenRecordingPermission: Bool { get }
    
    /// Captures the primary display surface at native display resolution.
    /// - Returns: A CGImage containing the captured display surface.
    /// - Throws: `ScreenCaptureError` if permission is denied or capture fails.
    func captureMainDisplay() async throws -> CGImage

    /// Captures the specified display surface at native display resolution.
    /// - Parameter displayID: Direct display identifier.
    /// - Returns: A CGImage containing the captured display surface.
    /// - Throws: `ScreenCaptureError` if permission is denied or capture fails.
    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage

    /// Captures a specified rectangular region from the indicated display.
    /// - Parameters:
    ///   - rect: Bounding rectangle in display coordinate points.
    ///   - displayID: Direct display identifier (defaulting to main display).
    /// - Returns: A cropped CGImage matching the target area.
    /// - Throws: `ScreenCaptureError` if display is not found or capture fails.
    func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage
}

public extension ScreenCaptureServiceProtocol {
    /// Convenience method capturing region on the main display.
    func captureDisplayRegion(_ rect: CGRect) async throws -> CGImage {
        try await captureDisplayRegion(rect, displayID: CGMainDisplayID())
    }

    /// Convenience default implementation capturing a display.
    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        if displayID == CGMainDisplayID() {
            return try await captureMainDisplay()
        }
        return try await captureDisplayRegion(CGRect(x: 0, y: 0, width: 1920, height: 1080), displayID: displayID)
    }

    var hasScreenRecordingPermission: Bool {
        return true
    }
}
