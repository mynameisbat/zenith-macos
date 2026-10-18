#if DEBUG
import Foundation
import CoreGraphics

/// Headless screen capture mock that generates synthetic bitmap patterns without triggering TCC -3801.
public final class MockScreenCaptureService: ScreenCaptureServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var stubbedMainDisplayImage: CGImage?
    public var stubbedRegionImage: CGImage?
    public var stubbedError: Error?
    public private(set) var captureMainDisplayCallCount: Int = 0
    public private(set) var capturedRegions: [CGRect] = []
    public var hasScreenRecordingPermission: Bool = true

    public init() {}

    // MARK: - Synchronous Scoped State Accessors (Swift 6 Concurrency Safe)

    private func recordMainCapture() -> (error: Error?, stub: CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        captureMainDisplayCallCount += 1
        return (stubbedError, stubbedMainDisplayImage)
    }

    private func recordRegionCapture(_ rect: CGRect) -> (error: Error?, stub: CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        capturedRegions.append(rect)
        return (stubbedError, stubbedRegionImage)
    }

    // MARK: - ScreenCaptureServiceProtocol

    public func captureMainDisplay() async throws -> CGImage {
        let (error, stub) = recordMainCapture()
        if let error = error { throw error }
        return stub ?? Self.makeSyntheticPattern(width: 1920, height: 1080)
    }

    public func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        let (error, stub) = recordMainCapture()
        if let error = error { throw error }
        return stub ?? Self.makeSyntheticPattern(width: 1920, height: 1080)
    }

    public func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
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

        let (error, stub) = recordRegionCapture(rect)
        if let error = error { throw error }
        let w = Int(rect.width)
        let h = Int(rect.height)
        return stub ?? Self.makeSyntheticPattern(width: max(1, w), height: max(1, h))
    }

    /// Synthesizes a deterministic RGB test pattern without making any macOS display or window server calls.
    public static func makeSyntheticPattern(width: Int = 800, height: Int = 600) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate synthetic CGContext bitmap buffer")
        }

        // Draw deep blue background
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw translucent center badge
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.3))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

        return context.makeImage()!
    }

    /// Resets all mock recording state.
    public func reset() {
        lock.lock()
        captureMainDisplayCallCount = 0
        capturedRegions.removeAll()
        stubbedMainDisplayImage = nil
        stubbedRegionImage = nil
        stubbedError = nil
        hasScreenRecordingPermission = true
        lock.unlock()
    }
}
#endif
