import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import GoldenGateCore

@Suite("Adversarial M7 Capture, Loupe & Multi-Display Hardening Suite")
struct AdversarialM7CaptureAndLoupeHardeningTests {

    private let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private final class MockCaptureBackend: ScreenCaptureBackendProtocol, @unchecked Sendable {
        var hasScreenRecordingPermission: Bool = true
        var capturedRect: CGRect?
        var capturedDisplayID: CGDirectDisplayID?
        let stubbedImage: CGImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 10, height: 10)

        func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
            stubbedImage
        }

        func captureDisplayRegion(_ rect: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
            capturedRect = rect
            capturedDisplayID = displayID
            return stubbedImage
        }
    }

    // MARK: - 1. ScreenCaptureManager Adversarial Boundary & Audio Verification

    @Test("ADV-M7-SC-01: Maximum permissible geometry bound (32768 x 32768) accepted; 32768.1 rejected")
    func testScreenCaptureManagerMaximumGeometryBound() async throws {
        let backend = MockCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        // Exact maximum boundary (32768 x 32768)
        let maxRect = CGRect(x: 0, y: 0, width: 32768, height: 32768)
        _ = try await manager.captureDisplayRegion(maxRect, displayID: 1)
        #expect(backend.capturedRect == maxRect)
        #expect(backend.capturedDisplayID == 1)
        #expect(soundService.shutterSoundCount == 1)

        // Exceeding maximum by 0.1 pt on width
        let oversizedWidth = CGRect(x: 0, y: 0, width: 32768.1, height: 100)
        await #expect(throws: ScreenCaptureError.invalidRegion(oversizedWidth)) {
            _ = try await manager.captureDisplayRegion(oversizedWidth, displayID: 1)
        }

        // Exceeding maximum by 0.1 pt on height
        let oversizedHeight = CGRect(x: 0, y: 0, width: 100, height: 32768.1)
        await #expect(throws: ScreenCaptureError.invalidRegion(oversizedHeight)) {
            _ = try await manager.captureDisplayRegion(oversizedHeight, displayID: 1)
        }

        // Shutter sound was only triggered for the 1 successful capture
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("ADV-M7-SC-02: Negative origin with positive dimensions in multi-display topology")
    func testScreenCaptureManagerNegativeOriginMultiDisplay() async throws {
        let backend = MockCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        // Negative coordinates represent secondary display to the left or below primary
        let leftDisplayRect = CGRect(x: -1920, y: -1080, width: 800, height: 600)
        _ = try await manager.captureDisplayRegion(leftDisplayRect, displayID: 2)

        #expect(backend.capturedRect == leftDisplayRect)
        #expect(backend.capturedDisplayID == 2)
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("ADV-M7-SC-03: Sub-pixel positive dimensions (0.01 pt) accepted; zero/negative rejected")
    func testScreenCaptureManagerSubPixelGeometry() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        // Sub-pixel positive dimensions (> 0)
        let subPixelRect = CGRect(x: 10, y: 10, width: 0.01, height: 0.01)
        _ = try await manager.captureDisplayRegion(subPixelRect, displayID: 1)
        #expect(soundService.shutterSoundCount == 1)

        // Zero width
        let zeroWidth = CGRect(x: 10, y: 10, width: 0.0, height: 50)
        await #expect(throws: ScreenCaptureError.invalidRegion(zeroWidth)) {
            _ = try await manager.captureDisplayRegion(zeroWidth, displayID: 1)
        }

        // Negative height
        let negativeHeight = CGRect(x: 10, y: 10, width: 50, height: -0.01)
        await #expect(throws: ScreenCaptureError.invalidRegion(negativeHeight)) {
            _ = try await manager.captureDisplayRegion(negativeHeight, displayID: 1)
        }

        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("ADV-M7-SC-04: Audio shutter sound invariant: strictly zero on permission denied or backend error")
    func testScreenCaptureManagerShutterSoundFailureInvariant() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        // 1. Permission Denied
        backend.hasScreenRecordingPermission = false
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await manager.captureMainDisplay()
        }
        await #expect(throws: ScreenCaptureError.permissionDenied) {
            _ = try await manager.captureDisplayRegion(CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1)
        }
        #expect(soundService.shutterSoundCount == 0)

        // 2. Backend Error Propagation
        backend.hasScreenRecordingPermission = true
        backend.stubbedError = ScreenCaptureError.captureFailed(reason: "VRAM Allocation Exhausted")
        await #expect(throws: ScreenCaptureError.captureFailed(reason: "VRAM Allocation Exhausted")) {
            _ = try await manager.captureMainDisplay()
        }
        await #expect(throws: ScreenCaptureError.captureFailed(reason: "VRAM Allocation Exhausted")) {
            _ = try await manager.captureDisplayRegion(CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1)
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    // MARK: - 2. LoupePixelSampler Memory Safety, Bitmaps & Byte-Order Hardening

    private func makeCustomCGImage(
        width: Int,
        height: Int,
        bitsPerComponent: Int = 8,
        bitsPerPixel: Int = 32,
        bytesPerRow: Int? = nil,
        space: CGColorSpace? = nil,
        bitmapInfo: UInt32,
        buffer: [UInt8]
    ) -> CGImage? {
        var mutableBuffer = buffer
        let stride = bytesPerRow ?? (width * (bitsPerPixel / 8))
        guard let ctx = CGContext(
            data: &mutableBuffer,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: stride,
            space: space ?? sRGBSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return ctx.makeImage()
    }

    @Test("ADV-M7-LM-01: Non-standard padded bytesPerRow (64-byte row alignment) memory stride safety")
    func testLoupePaddedBytesPerRowStride() {
        let width = 4
        let height = 2
        // Natural stride = 16 bytes. Padded stride = 64 bytes
        let bytesPerRow = 64
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Row 0 in memory (AppKit y = 1):
        // Pixel at x = 2: pure Magenta (R=255, G=0, B=255, A=255)
        // Little-Endian BGRA: [255, 0, 255, 255]
        let offsetRow0Px2 = 0 * bytesPerRow + 2 * 4
        buffer[offsetRow0Px2 + 0] = 255 // B
        buffer[offsetRow0Px2 + 1] = 0   // G
        buffer[offsetRow0Px2 + 2] = 255 // R
        buffer[offsetRow0Px2 + 3] = 255 // A

        // Row 1 in memory (AppKit y = 0):
        // Pixel at x = 1: pure Cyan (R=0, G=255, B=255, A=255)
        // Little-Endian BGRA: [255, 255, 0, 255]
        let offsetRow1Px1 = 1 * bytesPerRow + 1 * 4
        buffer[offsetRow1Px1 + 0] = 255 // B
        buffer[offsetRow1Px1 + 1] = 255 // G
        buffer[offsetRow1Px1 + 2] = 0   // R
        buffer[offsetRow1Px1 + 3] = 255 // A

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let image = makeCustomCGImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bitmapInfo: bitmapInfo,
            buffer: buffer
        ) else {
            Issue.record("Failed to create padded stride CGImage")
            return
        }

        #expect(image.bytesPerRow == 64)

        // Sample Magenta at AppKit (x: 2, y: 1) -> memory row 0
        let magenta = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 2, y: 1))
        #expect(magenta.red == 255)
        #expect(magenta.green == 0)
        #expect(magenta.blue == 255)
        #expect(magenta.alpha == 255)
        #expect(magenta.hexString == "#FF00FF")

        // Sample Cyan at AppKit (x: 1, y: 0) -> memory row 1
        let cyan = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(cyan.red == 0)
        #expect(cyan.green == 255)
        #expect(cyan.blue == 255)
        #expect(cyan.alpha == 255)
        #expect(cyan.hexString == "#00FFFF")
    }

    @Test("ADV-M7-LM-02: Extreme alpha un-premultiplication edge cases (alpha = 1 and alpha = 254)")
    func testLoupeAlphaUnpremultiplicationBoundaries() {
        // Little-Endian BGRA: [B, G, R, A]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // 2x1 image:
        // px 0: alpha = 1, premultiplied R = 1 -> un-premultiplied R should restore to 255!
        // px 1: alpha = 254, premultiplied R = 254 -> un-premultiplied R should restore to 255!
        let buffer: [UInt8] = [
            0, 0, 1,   1,    // px 0: B=0, G=0, R=1, A=1
            0, 0, 254, 254   // px 1: B=0, G=0, R=254, A=254
        ]

        guard let image = makeCustomCGImage(
            width: 2,
            height: 1,
            bitmapInfo: bitmapInfo,
            buffer: buffer
        ) else {
            Issue.record("Failed to create CGImage")
            return
        }

        // Sample px 0 (alpha = 1)
        let sampleLowAlpha = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(sampleLowAlpha.alpha == 1)
        #expect(sampleLowAlpha.red == 255)
        #expect(sampleLowAlpha.green == 0)
        #expect(sampleLowAlpha.blue == 0)

        // Sample px 1 (alpha = 254)
        let sampleHighAlpha = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(sampleHighAlpha.alpha == 254)
        #expect(sampleHighAlpha.red == 255)
        #expect(sampleHighAlpha.green == 0)
        #expect(sampleHighAlpha.blue == 0)
    }

    @Test("ADV-M7-LM-03: Fallback renderer safely processes 8-bit Grayscale CGImages without crash")
    func testLoupeGrayscaleFallbackRenderer() {
        let width = 2
        let height = 2
        let graySpace = CGColorSpaceCreateDeviceGray()
        // 8 bits per pixel, 1 byte per pixel
        let grayBuffer: [UInt8] = [
            0,   255, // Memory Row 0: Black, White
            128, 64   // Memory Row 1: 50% Gray, 25% Gray
        ]

        var mutable = grayBuffer
        guard let ctx = CGContext(
            data: &mutable,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let image = ctx.makeImage() else {
            Issue.record("Failed to create 8-bit Gray CGImage")
            return
        }

        #expect(image.bitsPerPixel == 8)

        // Memory row 0 (AppKit y = 1):
        let black = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        #expect(black.hexString == "#000000")

        let white = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1))
        #expect(white.red >= 254 && white.green >= 254 && white.blue >= 254)
        #expect(white.hexString == "#FFFFFF")

        // Memory row 1 (AppKit y = 0):
        let midGray = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(abs(Int(midGray.red) - 128) <= 2)
    }

    @Test("ADV-M7-LM-04: sampleGrid across 4 extreme screen corners with fractional offsets")
    func testLoupeSampleGridCornersAndFractionalOffsets() {
        let image = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 100, height: 100)

        // 1. Top-Left Corner (x: 0.2, y: 98.8) with Zoom 4x (21x21)
        let gridTL = LoupePixelSampler.sampleGrid(in: image, center: CGPoint(x: 0.2, y: 98.8), zoomFactor: .zoom4x)
        #expect(gridTL.count == 21)
        #expect(gridTL[0].count == 21)
        // Center pixel (10, 10) must match Top-Left quadrant color (Red: #FF0000)
        #expect(gridTL[10][10].hexString == "#FF0000")
        // Off-screen pixel outside top-left (e.g. [0][0]) must be clear
        #expect(gridTL[0][0] == .clear)

        // 2. Bottom-Right Corner (x: 98.8, y: 0.2) with Zoom 8x (15x15)
        let gridBR = LoupePixelSampler.sampleGrid(in: image, center: CGPoint(x: 98.8, y: 0.2), zoomFactor: .zoom8x)
        #expect(gridBR.count == 15)
        #expect(gridBR[0].count == 15)
        // Center pixel (7, 7) must match Bottom-Right quadrant color (Yellow: #FFFF00)
        #expect(gridBR[7][7].hexString == "#FFFF00")
        // Off-screen pixel outside bottom-right (e.g. [14][14]) must be clear
        #expect(gridBR[14][14] == .clear)

        // 3. Completely off-screen grid (x: -500, y: -500) returns all clear
        let gridOffscreen = LoupePixelSampler.sampleGrid(in: image, center: CGPoint(x: -500, y: -500), zoomFactor: .zoom4x)
        for row in gridOffscreen {
            for col in row {
                #expect(col == .clear)
            }
        }
    }

    // MARK: - 3. CoordinateTranslationService Defensive Scales & Involutive Geometry

    @Test("ADV-M7-CT-01: Non-positive scale factors (scale <= 0) safely fallback or return original")
    func testCoordinateTranslationNonPositiveScaleFactors() {
        let testRect = CGRect(x: 50, y: 100, width: 200, height: 150)
        let testPoint = CGPoint(x: 75, y: 125)

        // physicalPixelsToPoints with scale == 0 returns original rect/point
        let rectZeroScale = CoordinateTranslationService.physicalPixelsToPoints(rect: testRect, scale: 0)
        #expect(rectZeroScale == testRect)

        let pointZeroScale = CoordinateTranslationService.physicalPixelsToPoints(point: testPoint, scale: 0)
        #expect(pointZeroScale == testPoint)

        // physicalPixelsToPoints with negative scale returns original rect/point
        let rectNegativeScale = CoordinateTranslationService.physicalPixelsToPoints(rect: testRect, scale: -2.0)
        #expect(rectNegativeScale == testRect)

        let pointNegativeScale = CoordinateTranslationService.physicalPixelsToPoints(point: testPoint, scale: -2.0)
        #expect(pointNegativeScale == testPoint)

        // cursorToPhysicalPixels with scale <= 0 defaults effective scale to 1.0
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cursorZeroScale = CoordinateTranslationService.cursorToPhysicalPixels(
            cursor: testPoint,
            screenFrame: screenFrame,
            scale: 0
        )
        #expect(cursorZeroScale == testPoint)

        let cursorNegativeScale = CoordinateTranslationService.cursorToPhysicalPixels(
            cursor: testPoint,
            screenFrame: screenFrame,
            scale: -1.5
        )
        #expect(cursorNegativeScale == testPoint)
    }

    @Test("ADV-M7-CT-02: Clamp boundary behavior on degenerate, inverted, and disjoint rects")
    func testCoordinateTranslationClampEdgeCases() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // 1. Completely disjoint rect far outside bounds
        let farRect = CGRect(x: 5000, y: 5000, width: 500, height: 500)
        let clampedFar = CoordinateTranslationService.clamp(rect: farRect, to: bounds)
        #expect(clampedFar.origin.x == 1920)
        #expect(clampedFar.origin.y == 1080)
        #expect(clampedFar.width == 0)
        #expect(clampedFar.height == 0)

        // 2. Straddling across bottom-left border
        let straddleRect = CGRect(x: -100, y: -100, width: 300, height: 300)
        let clampedStraddle = CoordinateTranslationService.clamp(rect: straddleRect, to: bounds)
        #expect(clampedStraddle.origin.x == 0)
        #expect(clampedStraddle.origin.y == 0)
        #expect(clampedStraddle.width == 200)
        #expect(clampedStraddle.height == 200)

        // 3. Fully encompassing bounds
        let hugeRect = CGRect(x: -500, y: -500, width: 3000, height: 2500)
        let clampedHuge = CoordinateTranslationService.clamp(rect: hugeRect, to: bounds)
        #expect(clampedHuge == bounds)
    }

    // MARK: - 4. MarqueeSelectionEngine & Geometry State Machine Hardening

    @Test("ADV-M7-MQ-01: calculateBadgePosition flips above on bottom edge, below on top edge, inside on full screen")
    func testMarqueeCalculateBadgePositionAllBranches() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let badgeSize = CGSize(width: 140, height: 30)

        // 1. Selection near bottom of screen (y = 10 in AppKit):
        // y - badgeSize.height - margin would be 10 - 30 - 8 = -28 < screen.minY + margin (8)
        // Must flip ABOVE selection: selectionRect.maxY + margin = 110 + 8 = 118
        let bottomSelection = CGRect(x: 500, y: 10, width: 400, height: 100)
        let bottomBadgePos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: bottomSelection,
            badgeSize: badgeSize,
            screenBounds: screen
        )
        #expect(bottomBadgePos.y == 118)

        // 2. Selection near top of screen (y = 900 in AppKit):
        // Default below selection: selectionRect.minY - badgeSize.height - margin = 900 - 30 - 8 = 862
        let topSelection = CGRect(x: 500, y: 900, width: 400, height: 100)
        let topBadgePos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: topSelection,
            badgeSize: badgeSize,
            screenBounds: screen
        )
        #expect(topBadgePos.y == 862)

        // 3. Selection spanning entire screen height (minY = 0, maxY = 1080):
        // Bottom flip fails, top flip (1080 + 8 = 1088 > screen.maxY - margin 1072) fails
        // Fallback: inside selection at minY + margin = 0 + 8 = 8
        let fullSelection = CGRect(x: 500, y: 0, width: 400, height: 1080)
        let fullBadgePos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: fullSelection,
            badgeSize: badgeSize,
            screenBounds: screen
        )
        #expect(fullBadgePos.y == 8)
    }

    @Test("ADV-M7-MQ-02: MarqueeSelectionEngine state machine transitions & escape idempotence")
    func testMarqueeSelectionEngineStateTransitions() {
        let engine = MarqueeSelectionEngine()

        #expect(engine.state == .idle)
        #expect(!engine.isDragging)
        #expect(engine.normalizedRect == .zero)

        // Update drag without beginDrag is safe no-op
        engine.updateDrag(to: CGPoint(x: 50, y: 50))
        #expect(engine.state == .idle)

        // End drag without beginDrag returns nil
        #expect(engine.endDrag() == nil)

        // Begin drag
        engine.beginDrag(at: CGPoint(x: 100, y: 100))
        #expect(engine.isDragging)
        #expect(engine.normalizedRect == .zero) // start == current

        // Update drag
        engine.updateDrag(to: CGPoint(x: 150, y: 140))
        #expect(engine.isDragging)
        #expect(engine.normalizedRect == CGRect(x: 100, y: 100, width: 50, height: 40))

        // Re-begin drag while already dragging (e.g. secondary click without release)
        engine.beginDrag(at: CGPoint(x: 200, y: 200))
        #expect(engine.isDragging)
        engine.updateDrag(to: CGPoint(x: 202, y: 202)) // 2x2 rect (< minimumDimension 3.0)

        // End drag below minimum dimension (3.0 pt) resets to .idle and returns nil
        let tooSmall = engine.endDrag(minimumDimension: 3.0)
        #expect(tooSmall == nil)
        #expect(engine.state == .idle)

        // Begin drag and end drag with valid dimensions
        engine.beginDrag(at: CGPoint(x: 50, y: 50))
        engine.updateDrag(to: CGPoint(x: 150, y: 200))
        let valid = engine.endDrag(minimumDimension: 3.0)
        #expect(valid == CGRect(x: 50, y: 50, width: 100, height: 150))
        #expect(engine.state == .selected(rect: CGRect(x: 50, y: 50, width: 100, height: 150)))
        #expect(engine.normalizedRect == CGRect(x: 50, y: 50, width: 100, height: 150))

        // Escape Key cancellation: first call returns true, second call returns false
        #expect(engine.handleEscapeKey() == true)
        #expect(engine.state == .dismissed)
        #expect(engine.handleEscapeKey() == false)
        #expect(engine.state == .dismissed)

        // Reset restores .idle
        engine.reset()
        #expect(engine.state == .idle)
    }

    @Test("ADV-M7-MQ-03: 80 concurrent async tasks hammering MarqueeSelectionEngine without data race")
    func testMarqueeSelectionEngineConcurrentHammer() async {
        let engine = MarqueeSelectionEngine()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask {
                    let step = i % 5
                    switch step {
                    case 0:
                        engine.beginDrag(at: CGPoint(x: CGFloat(i), y: CGFloat(i)))
                    case 1:
                        engine.updateDrag(to: CGPoint(x: CGFloat(i + 20), y: CGFloat(i + 30)))
                    case 2:
                        _ = engine.endDrag(minimumDimension: 3.0)
                    case 3:
                        _ = engine.handleEscapeKey()
                    default:
                        engine.reset()
                    }
                    _ = engine.isDragging
                    _ = engine.normalizedRect
                }
            }
        }

        // Post-concurrency reset
        engine.reset()
        #expect(engine.state == .idle)
    }
}
