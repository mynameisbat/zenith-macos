#if DEBUG
import Foundation
import CoreGraphics

/// In-memory screen capture backend generating deterministic pixel matrices for headless testing.
public final class SimulatedScreenCaptureBackend: ScreenCaptureBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var hasScreenRecordingPermission: Bool = true
    public var stubbedError: Error?
    public var displayImages: [CGDirectDisplayID: CGImage] = [:]
    public var defaultDisplaySize: CGSize = CGSize(width: 1920, height: 1080)
    public var defaultScale: CGFloat = 2.0

    public private(set) var captureDisplayCalls: [CGDirectDisplayID] = []
    public private(set) var captureRegionCalls: [(rect: CGRect, displayID: CGDirectDisplayID)] = []

    public init() {}

    private func recordCaptureDisplay(displayID: CGDirectDisplayID) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }

        if let error = stubbedError { throw error }
        guard hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }

        captureDisplayCalls.append(displayID)

        if let existing = displayImages[displayID] {
            return existing
        }

        let w = Int(defaultDisplaySize.width * defaultScale)
        let h = Int(defaultDisplaySize.height * defaultScale)
        let image = Self.makeQuadrantPattern(width: w, height: h)
        displayImages[displayID] = image
        return image
    }

    public func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        try recordCaptureDisplay(displayID: displayID)
    }

    private func recordCaptureRegion(rect: CGRect, displayID: CGDirectDisplayID) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }

        if let error = stubbedError { throw error }
        guard hasScreenRecordingPermission else {
            throw ScreenCaptureError.permissionDenied
        }

        captureRegionCalls.append((rect, displayID))

        let fullImage: CGImage
        if let existing = displayImages[displayID] {
            fullImage = existing
        } else {
            let w = Int(defaultDisplaySize.width * defaultScale)
            let h = Int(defaultDisplaySize.height * defaultScale)
            fullImage = Self.makeQuadrantPattern(width: w, height: h)
            displayImages[displayID] = fullImage
        }

        guard let cropped = fullImage.cropping(to: rect) else {
            throw ScreenCaptureError.captureFailed(reason: "Failed to crop CGImage to \(rect)")
        }
        return cropped
    }

    public func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        try recordCaptureRegion(rect: rect, displayID: displayID)
    }

    public static func makeQuadrantPattern(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext")
        }

        let halfW = CGFloat(width) / 2.0
        let halfH = CGFloat(height) / 2.0

        // Quadrant 1 (Top-Left): Red #FF0000
        let redColor = CGColor(colorSpace: colorSpace, components: [1.0, 0.0, 0.0, 1.0])!
        ctx.setFillColor(redColor)
        ctx.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))

        // Quadrant 2 (Top-Right): Green #00FF00
        let greenColor = CGColor(colorSpace: colorSpace, components: [0.0, 1.0, 0.0, 1.0])!
        ctx.setFillColor(greenColor)
        ctx.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))

        // Quadrant 3 (Bottom-Left): Blue #0000FF
        let blueColor = CGColor(colorSpace: colorSpace, components: [0.0, 0.0, 1.0, 1.0])!
        ctx.setFillColor(blueColor)
        ctx.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))

        // Quadrant 4 (Bottom-Right): Yellow #FFFF00
        let yellowColor = CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 0.0, 1.0])!
        ctx.setFillColor(yellowColor)
        ctx.fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH))

        return ctx.makeImage()!
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hasScreenRecordingPermission = true
        stubbedError = nil
        displayImages.removeAll()
        captureDisplayCalls.removeAll()
        captureRegionCalls.removeAll()
    }
}
#endif
