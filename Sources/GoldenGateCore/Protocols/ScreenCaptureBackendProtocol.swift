import Foundation
import CoreGraphics

/// Low-level abstraction decoupling ScreenCaptureManager from macOS WindowServer & ScreenCaptureKit.
public protocol ScreenCaptureBackendProtocol: Sendable {
    /// Indicates whether the backend has authorization to capture display surfaces.
    var hasScreenRecordingPermission: Bool { get }

    /// Captures the entire display surface for the given display ID.
    /// - Parameter displayID: Direct display identifier.
    /// - Returns: A native resolution CGImage of the display.
    /// - Throws: `ScreenCaptureError` on failure or permission denial.
    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage

    /// Captures a cropped subregion from the given display.
    /// - Parameters:
    ///   - rect: Bounding rectangle in display coordinates.
    ///   - displayID: Direct display identifier.
    /// - Returns: A cropped CGImage matching the target area.
    /// - Throws: `ScreenCaptureError` on failure or invalid region.
    func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage
}
