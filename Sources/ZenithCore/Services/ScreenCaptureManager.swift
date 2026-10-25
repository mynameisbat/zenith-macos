import Foundation
import CoreGraphics

/// Production implementation of ScreenCaptureServiceProtocol with audio shutter integration and backend abstraction.
public final class ScreenCaptureManager: ScreenCaptureServiceProtocol, Sendable {
    private let backend: ScreenCaptureBackendProtocol
    private let soundService: (any SoundServiceProtocol)?

    public static let live = ScreenCaptureManager(
        backend: NativeScreenCaptureBackend(),
        soundService: AudioFeedbackManager.shared
    )

    public init(
        backend: ScreenCaptureBackendProtocol = NativeScreenCaptureBackend(),
        soundService: (any SoundServiceProtocol)? = nil
    ) {
        self.backend = backend
        self.soundService = soundService
    }

    public var hasScreenRecordingPermission: Bool {
        backend.hasScreenRecordingPermission
    }

    public func captureMainDisplay() async throws -> CGImage {
        guard backend.hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }
        let image = try await backend.captureDisplay(displayID: CGMainDisplayID())
        soundService?.playShutterSound()
        return image
    }

    public func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard backend.hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }
        return try await backend.captureDisplay(displayID: displayID)
    }

    public func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        guard backend.hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }
        guard !rect.isNull,
              !rect.isInfinite,
              !rect.origin.x.isNaN,
              !rect.origin.y.isNaN,
              !rect.origin.x.isInfinite,
              !rect.origin.y.isInfinite,
              !rect.size.width.isNaN,
              !rect.size.height.isNaN,
              !rect.size.width.isInfinite,
              !rect.size.height.isInfinite,
              !rect.width.isNaN,
              !rect.height.isNaN,
              !rect.width.isInfinite,
              !rect.height.isInfinite,
              rect.size.width > 0,
              rect.size.height > 0,
              rect.width > 0,
              rect.height > 0,
              rect.size.width <= 32768,
              rect.size.height <= 32768,
              rect.width <= 32768,
              rect.height <= 32768 else {
            throw ScreenCaptureError.invalidRegion(rect)
        }

        let image = try await backend.captureDisplayRegion(rect, displayID: displayID)
        soundService?.playShutterSound()
        return image
    }
}
