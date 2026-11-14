import Foundation
import CoreGraphics
import ScreenCaptureKit

/// Captures one area of a display for scrolling capture, without the shutter sound. On macOS 14+ it uses
/// ScreenCaptureKit and leaves Zenith's own windows (the progress panel, the outline) out; macOS 13 has no such
/// screenshot API, so there the panel is placed outside the area instead.
public final class ScreenRegionFrameGrabber: ScrollFrameGrabbing, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    /// Display-local points, origin at the top-left of the display.
    private let rect: CGRect
    private let scale: CGFloat
    private let fallback = NativeScreenCaptureBackend()
    private let lock = NSLock()
    private var cachedFilter: AnyObject?

    public init(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.rect = rect
        self.scale = scale > 0 ? scale : 1
    }

    public func grab() async throws -> CGImage {
        if #available(macOS 14, *) {
            if let image = try? await grabWithScreenCaptureKit() {
                return image
            }
        }
        return try await fallback.captureDisplayRegion(rect, displayID: displayID)
    }

    @available(macOS 14, *)
    private func grabWithScreenCaptureKit() async throws -> CGImage {
        let filter: SCContentFilter
        if let cached = lock.withLock({ cachedFilter }) as? SCContentFilter {
            filter = cached
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenCaptureError.displayNotFound(displayID: displayID)
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
            lock.withLock { cachedFilter = filter }
        }
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false
        config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
