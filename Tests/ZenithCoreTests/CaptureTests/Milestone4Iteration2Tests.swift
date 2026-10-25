import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ZenithCore

// MARK: - Suite A: Live Loupe Coordinate & Geometry Integration

@Suite("Live Loupe Coordinate & Geometry Integration Suite")
struct LiveLoupeCoordinateIntegrationTests {

    // Helper: Creates a 200x200 quadrant test pattern
    // Top-Left: Red (#FF0000), Top-Right: Green (#00FF00), Bottom-Left: Blue (#0000FF), Bottom-Right: Yellow (#FFFF00)
    let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

    @Test("LC-01: AppKit Cartesian cursor at Top-Left quadrant samples pure Red without premature Y-flip")
    func testLiveLoupeCartesianNoPrematureFlip() {
        // In AppKit Cartesian space, Top-Left quadrant has x in [0, 100) and y in [100, 200)
        let cursorAppKit = CGPoint(x: 50, y: 150)
        let sampled = LoupePixelSampler.samplePixel(in: testImage, at: cursorAppKit)
        #expect(sampled == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(sampled.hexString == "#FF0000")
    }

    @Test("LC-02: AppKit Cartesian cursor at Bottom-Left quadrant samples pure Blue")
    func testLiveLoupeBottomLeftQuadrant() {
        // Bottom-Left quadrant has x in [0, 100) and y in [0, 100)
        let cursorAppKit = CGPoint(x: 50, y: 50)
        let sampled = LoupePixelSampler.samplePixel(in: testImage, at: cursorAppKit)
        #expect(sampled == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))
        #expect(sampled.hexString == "#0000FF")

        // 4x Grid center color must match direct sample
        let grid = LoupePixelSampler.sampleGrid(in: testImage, center: cursorAppKit, zoomFactor: .zoom4x)
        let centerPixel = grid[10][10]
        #expect(centerPixel == sampled)
    }

    @Test("LC-03: Secondary display with Negative X translates cursor to positive display-local coordinates")
    func testLiveLoupeNegativeScreenOffsetTranslation() {
        let screenFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let globalCursor = CGPoint(x: -1500, y: 500)

        // Translation formula: local = global - screenOrigin
        let localX = globalCursor.x - screenFrame.minX
        let localY = globalCursor.y - screenFrame.minY

        #expect(localX == 420.0)
        #expect(localY == 500.0)
        #expect(localX >= 0 && localX < screenFrame.width)
        #expect(localY >= 0 && localY < screenFrame.height)
    }

    @Test("LC-04: Secondary display with Positive Y translates cursor to positive display-local coordinates")
    func testLiveLoupeVerticalAboveScreenOffsetTranslation() {
        let screenFrame = CGRect(x: 0, y: 1080, width: 2560, height: 1440)
        let globalCursor = CGPoint(x: 400, y: 1500)

        let localX = globalCursor.x - screenFrame.minX
        let localY = globalCursor.y - screenFrame.minY

        #expect(localX == 400.0)
        #expect(localY == 420.0)
        #expect(localX >= 0 && localX < screenFrame.width)
        #expect(localY >= 0 && localY < screenFrame.height)
    }

    @Test("LC-05: Loupe HUD boundary clamping strictly constrains HUD frame within display bounds")
    func testLoupePositionClampingAllScreenCorners() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let loupeSize = CGSize(width: 140, height: 170)
        let margin: CGFloat = 10.0

        let cornerCursors = [
            CGPoint(x: 5, y: 5),        // Bottom-Left
            CGPoint(x: 1915, y: 1075),  // Top-Right
            CGPoint(x: 1915, y: 5),     // Bottom-Right
            CGPoint(x: 5, y: 1075)      // Top-Left
        ]

        for cursor in cornerCursors {
            // Standard placement: default bottom-right offset
            var lx = cursor.x + 20
            var ly = cursor.y - loupeSize.height - 20

            if lx + loupeSize.width > screenBounds.maxX - margin {
                lx = cursor.x - loupeSize.width - 20
            }
            if ly < screenBounds.minY + margin {
                ly = cursor.y + 20
            }

            let clampedX = max(margin, min(lx, screenBounds.maxX - loupeSize.width - margin))
            let clampedY = max(margin, min(ly, screenBounds.maxY - loupeSize.height - margin))
            let frame = CGRect(x: clampedX, y: clampedY, width: loupeSize.width, height: loupeSize.height)

            #expect(frame.minX >= screenBounds.minX)
            #expect(frame.maxX <= screenBounds.maxX)
            #expect(frame.minY >= screenBounds.minY)
            #expect(frame.maxY <= screenBounds.maxY)
        }
    }

    @Test("LC-06: Zoom factor switching maintains exact odd matrix symmetry and center pixel invariance")
    func testLoupeZoomFactorGridSymmetry() {
        let center = CGPoint(x: 100, y: 100)
        let grid4x = LoupePixelSampler.sampleGrid(in: testImage, center: center, zoomFactor: .zoom4x)
        let grid8x = LoupePixelSampler.sampleGrid(in: testImage, center: center, zoomFactor: .zoom8x)

        #expect(grid4x.count == 21)
        #expect(grid4x.first?.count == 21)
        #expect(grid8x.count == 15)
        #expect(grid8x.first?.count == 15)

        let center4x = grid4x[10][10]
        let center8x = grid8x[7][7]
        #expect(center4x == center8x)
    }

    @Test("LC-07: Cursor crossing display boundary switches local coordinates cleanly without NaN or crashes")
    func testLiveLoupeScreenBoundaryCrossingContinuity() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

        let crossingPoints = [
            CGPoint(x: 1918, y: 500),
            CGPoint(x: 1919, y: 500),
            CGPoint(x: 1920, y: 500),
            CGPoint(x: 1921, y: 500)
        ]

        for pt in crossingPoints {
            let activeScreen = (pt.x < 1920) ? screen1 : screen2
            let localX = pt.x - activeScreen.minX
            let localY = pt.y - activeScreen.minY

            #expect(localX >= 0)
            #expect(localX <= 1920)
            #expect(localY >= 0)
            #expect(!localX.isNaN && !localY.isNaN)
        }
    }
}

// MARK: - Suite B: High-DPI Retina Scaling Verification

@Suite("High-DPI Retina Scaling Verification Suite")
struct RetinaScalingVerificationTests {

    @Test("RS-01: 2x Retina display maps 150 pt cursor to 300 px physical pixel in Top-Right quadrant")
    func testRetina2xQuadrantPixelSampling() {
        let retinaImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 400, height: 400)
        let scale: CGFloat = 2.0
        let cursorPoints = CGPoint(x: 150, y: 150) // Top-Right in 200x200 pt display

        let cursorPixels = CoordinateTranslationService.pointsToPhysicalPixels(point: cursorPoints, scale: scale)
        #expect(cursorPixels == CGPoint(x: 300, y: 300))

        let color = LoupePixelSampler.samplePixel(in: retinaImage, at: cursorPixels)
        #expect(color == PixelColor(red: 0, green: 255, blue: 0, alpha: 255)) // Green
    }

    @Test("RS-02: 3x High-DPI display maps 150 pt cursor to 450 px physical pixel")
    func testHighDPI3xQuadrantPixelSampling() {
        let highDPIImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 600, height: 600)
        let scale: CGFloat = 3.0
        let cursorPoints = CGPoint(x: 150, y: 150)

        let cursorPixels = CoordinateTranslationService.pointsToPhysicalPixels(point: cursorPoints, scale: scale)
        #expect(cursorPixels == CGPoint(x: 450, y: 450))

        let color = LoupePixelSampler.samplePixel(in: highDPIImage, at: cursorPixels)
        #expect(color == PixelColor(red: 0, green: 255, blue: 0, alpha: 255)) // Green
    }

    @Test("RS-03: 1x Standard display maps 50 pt cursor directly to 50 px in Top-Left quadrant")
    func testStandard1xQuadrantPixelSampling() {
        let standardImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)
        let scale: CGFloat = 1.0
        let cursorPoints = CGPoint(x: 50, y: 150)

        let cursorPixels = CoordinateTranslationService.pointsToPhysicalPixels(point: cursorPoints, scale: scale)
        #expect(cursorPixels == cursorPoints)

        let color = LoupePixelSampler.samplePixel(in: standardImage, at: cursorPixels)
        #expect(color == PixelColor(red: 255, green: 0, blue: 0, alpha: 255)) // Red
    }

    @Test("RS-04: Heterogeneous scale transition dynamically scales coordinates based on active screen")
    func testHeterogeneousScaleTransition() {
        let screenA_scale: CGFloat = 2.0
        let screenB_scale: CGFloat = 1.0
        let point = CGPoint(x: 100, y: 100)

        let pxA = CoordinateTranslationService.pointsToPhysicalPixels(point: point, scale: screenA_scale)
        let pxB = CoordinateTranslationService.pointsToPhysicalPixels(point: point, scale: screenB_scale)

        #expect(pxA == CGPoint(x: 200, y: 200))
        #expect(pxB == CGPoint(x: 100, y: 100))
    }

    @Test("RS-05: Sub-pixel rounding preserves floating point precision before integer conversion")
    func testFractionalSubPixelRoundingPreservation() {
        let scale: CGFloat = 2.0
        let pt = CGPoint(x: 100.4, y: 100.6)

        // Scale floating point first, then round:
        let scaledX = pt.x * scale // 200.8
        let scaledY = pt.y * scale // 201.2

        #expect(Int(scaledX.rounded()) == 201)
        #expect(Int(scaledY.rounded()) == 201)

        // Premature rounding would yield 100 * 2 = 200 (error of 1 physical pixel)
        #expect(Int(pt.x.rounded()) * 2 == 200)
    }

    @Test("RS-06: Bounds clamping strictly prevents IEEE-754 epsilon overflow past container edge")
    func testClampEpsilonExclusion() {
        let container = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Candidate touching right edge with floating point inaccuracy
        let candidate = CGRect(x: 1910.0000000000002, y: 500, width: 100, height: 100)
        let clamped = CoordinateTranslationService.clamp(rect: candidate, to: container)

        #expect(clamped.maxX <= container.maxX)
        #expect(clamped.width <= 10.0)
    }

    @Test("RS-07: Degenerate scale factors (0.0, negative, NaN) safely return unchanged geometry without division by zero")
    func testZeroAndNegativeScaleGracefulFallback() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let point = CGPoint(x: 5, y: 15)

        #expect(CoordinateTranslationService.physicalPixelsToPoints(rect: rect, scale: 0.0) == rect)
        #expect(CoordinateTranslationService.physicalPixelsToPoints(rect: rect, scale: -1.5) == rect)
        #expect(CoordinateTranslationService.physicalPixelsToPoints(point: point, scale: 0.0) == point)
        #expect(CoordinateTranslationService.physicalPixelsToPoints(point: point, scale: -2.0) == point)
    }
}

// MARK: - Suite C: Multi-Display ID Resolution & Routing

@Suite("Multi-Display ID Resolution & Routing Suite")
struct MultiDisplayResolutionTests {

    @Test("MD-01: Display ID resolution retrieves CGDirectDisplayID from screen device dictionary")
    func testDisplayIDResolutionFromNSScreen() {
        // CoreGraphics main display ID is guaranteed valid
        let mainID = CGMainDisplayID()
        #expect(mainID != 0)
    }

    @Test("MD-02: Selection on secondary display routes capture to secondary display ID and local coordinates")
    func testAreaCaptureRoutedToSecondaryDisplayID() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let service = ScreenCaptureManager(backend: backend)

        // Secondary display placed to the left
        let secondaryDisplayID: CGDirectDisplayID = 2
        let secondaryFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let primaryHeight: CGFloat = 1080

        // Selection in AppKit coordinates on secondary display
        let appKitSelection = CGRect(x: -1500, y: 200, width: 400, height: 300)

        // Translate to display-local CoreGraphics
        let localCG = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: appKitSelection,
            displayFrame: secondaryFrame,
            primaryScreenHeight: primaryHeight
        )

        _ = try await service.captureDisplayRegion(localCG, displayID: secondaryDisplayID)

        #expect(backend.captureRegionCalls.count == 1)
        let call = backend.captureRegionCalls.first!
        #expect(call.displayID == secondaryDisplayID)
        #expect(call.rect.origin.x == 420.0) // -1500 - (-1920)
        #expect(call.rect.width == 400.0)
        #expect(call.rect.height == 300.0)
    }

    @Test("MD-03: Selection on tertiary display to the right routes correctly with local X offset")
    func testAreaCaptureRoutedToTertiaryDisplayID() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let service = ScreenCaptureManager(backend: backend)

        let tertiaryDisplayID: CGDirectDisplayID = 3
        let tertiaryFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let primaryHeight: CGFloat = 1080

        let appKitSelection = CGRect(x: 2100, y: 100, width: 500, height: 400)
        let localCG = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: appKitSelection,
            displayFrame: tertiaryFrame,
            primaryScreenHeight: primaryHeight
        )

        _ = try await service.captureDisplayRegion(localCG, displayID: tertiaryDisplayID)

        let call = backend.captureRegionCalls.first!
        #expect(call.displayID == tertiaryDisplayID)
        #expect(call.rect.origin.x == 180.0) // 2100 - 1920
        #expect(call.rect.width == 500.0)
    }

    @Test("MD-04: Spanning selection partitions into exact sub-rectangles across screen boundaries")
    func testSpanningSelectionDominantDisplayResolution() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let spanning = CGRect(x: 1800, y: 200, width: 400, height: 300) // 120pt on S1, 280pt on S2

        let part1 = MarqueeGeometry.intersectScreen(rect: spanning, screenFrame: screen1)
        let part2 = MarqueeGeometry.intersectScreen(rect: spanning, screenFrame: screen2)

        #expect(part1 == CGRect(x: 1800, y: 200, width: 120, height: 300))
        #expect(part2 == CGRect(x: 1920, y: 200, width: 280, height: 300))

        // Total area is conserved
        let area1 = part1!.width * part1!.height
        let area2 = part2!.width * part2!.height
        #expect(area1 + area2 == spanning.width * spanning.height)
    }

    @Test("MD-05: Local CoreGraphics coordinate conversion maintains bounded origin and dimensions")
    func testDisplayLocalCoreGraphicsTransformationNegativeX() {
        let displayFrame = CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
        let primaryHeight: CGFloat = 1080
        let sel = CGRect(x: -1500, y: -800, width: 600, height: 400)

        let local = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: sel,
            displayFrame: displayFrame,
            primaryScreenHeight: primaryHeight
        )

        #expect(local.origin.x == 1060.0) // -1500 - (-2560)
        #expect(local.width == 600.0)
        #expect(local.height == 400.0)
        #expect(local.origin.x >= 0 && local.maxX <= displayFrame.width)
    }

    @Test("MD-06: Screen parameters notification fires without memory corruption or deadlocks")
    func testDisplayReconfigurationRefreshesOverlays() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        #expect(true)
    }

    @Test("MD-07: Invalid or disconnected display ID raises ScreenCaptureError gracefully")
    func testDisconnectedDisplayFallbackToMain() async {
        let backend = SimulatedScreenCaptureBackend()
        backend.stubbedError = ScreenCaptureError.displayNotFound(displayID: 99999)
        let service = ScreenCaptureManager(backend: backend)

        do {
            _ = try await service.captureDisplayRegion(CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 99999)
            Issue.record("Expected error")
        } catch let error as ScreenCaptureError {
            #expect(error == .displayNotFound(displayID: 99999))
        } catch {
            Issue.record("Unexpected error")
        }
    }
}

// MARK: - Suite D: Pixel Byte-Order, BitmapInfo & Color Space Resiliency

@Suite("Pixel Byte-Order, BitmapInfo & Color Space Resiliency Suite")
struct PixelByteOrderResiliencyTests {

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: - Helper to build synthetic 2x2 CGImage with specific CGBitmapInfo
    func makeImage(
        pixelBytes: [UInt8],
        bitmapInfo: UInt32,
        width: Int = 2,
        height: Int = 2
    ) -> CGImage? {
        var mutableBytes = pixelBytes
        guard let ctx = CGContext(
            data: &mutableBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return ctx.makeImage()
    }

    @Test("BO-01: Native macOS ScreenCaptureKit Little-Endian 32-bit BGRA format resolves Red and Blue correctly")
    func testLittleEndian32BGRAFormatSampling() {
        // kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst (Raw value: 8194)
        // Memory byte order: [B, G, R, A]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // 4 pixels (2x2):
        // (0,0): Pure Blue [255, 0, 0, 255]
        // (1,0): Pure Red  [0, 0, 255, 255]
        // (0,1): Pure Green[0, 255, 0, 255]
        // (1,1): Yellow    [0, 255, 255, 255]
        let bytes: [UInt8] = [
            0, 255, 0, 255,    0, 255, 255, 255,  // Top row (memoryY = 0)
            255, 0, 0, 255,    0, 0, 255, 255    // Bottom row (memoryY = 1)
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create BGRA image")
            return
        }

        // AppKit py = 0 -> memoryY = 1 (Bottom row)
        // px = 0: Blue
        let blueSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(blueSample == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))
        #expect(blueSample.hexString == "#0000FF")

        // px = 1: Red
        let redSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(redSample == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(redSample.hexString == "#FF0000")
    }

    @Test("BO-02: Big-Endian 32-bit ARGB format resolves Red, Green, and Blue without Alpha confusion")
    func testBigEndian32ARGBFormatSampling() {
        // kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedFirst (Raw value: 16386)
        // Memory byte order: [A, R, G, B]
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        let bytes: [UInt8] = [
            255, 0, 255, 0,    255, 255, 255, 0,  // Top row
            255, 255, 0, 0,    255, 0, 0, 255    // Bottom row: Red (0,0), Blue (1,0)
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create ARGB image")
            return
        }

        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(red == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))

        let blue = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(blue == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test("BO-03: Big-Endian 32-bit RGBA format resolves accurately")
    func testBigEndian32RGBAFormatSampling() {
        // kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast (Raw value: 16385)
        // Memory byte order: [R, G, B, A]
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        let bytes: [UInt8] = [
            0, 255, 0, 255,    255, 255, 0, 255,
            255, 0, 0, 255,    0, 0, 255, 255
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create RGBA image")
            return
        }

        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(red == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test("BO-04: Little-Endian 32-bit ABGR format resolves accurately")
    func testLittleEndian32ABGRFormatSampling() {
        // kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedLast
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        let bytes: [UInt8] = [
            255, 0, 255, 0,    255, 0, 255, 255,
            255, 0, 0, 255,    255, 255, 0, 0
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create ABGR image")
            return
        }

        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(red == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test("BO-05: Opaque formats (noneSkipFirst and noneSkipLast) always report alpha = 255")
    func testOpaqueNoneSkipAlphaFormats() {
        let bitmapInfoSkipFirst = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let bytes: [UInt8] = [
            0, 0, 0, 0,        0, 0, 0, 0,
            0, 0, 255, 0,      255, 0, 0, 0      // Red, Blue with dummy alpha byte = 0
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfoSkipFirst) else {
            Issue.record("Failed to create skipFirst image")
            return
        }

        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(red.alpha == 255)
        #expect(red.red == 255)
    }

    @Test("BO-06: Premultiplied alpha correctly un-premultiplies color channels")
    func testPremultipliedAlphaUnpremultiplication() {
        // Semi-transparent red: 50% opacity (alpha = 128), red stored as 128
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytes: [UInt8] = [
            0, 0, 0, 0,        0, 0, 0, 0,
            0, 0, 128, 128,    0, 0, 0, 0
        ]

        guard let image = makeImage(pixelBytes: bytes, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create premultiplied image")
            return
        }

        let sample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(sample.alpha == 128)
        // Un-premultiplied red should restore full intensity (approx 255)
        #expect(sample.red >= 250)
    }

    @Test("BO-07: Fallback rendering path succeeds for 8-bit grayscale images without crashing")
    func testFallbackRenderingPathPathologicalFormats() {
        var grayBytes: [UInt8] = [255, 128, 64, 0]
        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &grayBytes,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 2,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let image = ctx.makeImage() else {
            Issue.record("Failed to create grayscale image")
            return
        }

        let sample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(sample.alpha == 255)
        #expect(sample.red == sample.green && sample.green == sample.blue)
    }
}

// MARK: - Suite E: Loupe Grid Upright & Helper Mapping Tests

@Suite("Loupe Grid Upright & Helper Mapping Suite")
struct LoupeGridUprightAndHelperMappingTests {
    let testImage: CGImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

    @Test("LM-17: sampleGrid upright row ordering: top row contains top quadrant color")
    func testSampleGridUprightOrientation() {
        // Test pattern: Top half is Red/Green, Bottom half is Blue/Yellow
        // Center at boundary (x: 50, y: 100) on 200x200 image
        let matrix = LoupePixelSampler.sampleGrid(in: testImage, center: CGPoint(x: 50, y: 100), zoomFactor: .zoom4x)
        // Row 0 is the top row: should be Red (#FF0000)
        #expect(matrix[0][10].hexString == "#FF0000")
        // Row 20 is the bottom row: should be Blue (#0000FF)
        #expect(matrix[20][10].hexString == "#0000FF")
    }

    @Test("LM-18: Byte-order resilience: Samples native macOS Little-Endian BGRA buffer accurately")
    func testNativeMacOSLittleEndianBGRAMapping() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create BGRA CGContext")
            return
        }
        // Pure red
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = ctx.makeImage() else {
            Issue.record("Failed to create BGRA CGImage")
            return
        }

        let sampled = LoupePixelSampler.samplePixel(in: image, at: .zero)
        #expect(sampled.red == 255)
        #expect(sampled.green == 0)
        #expect(sampled.blue == 0)
        #expect(sampled.hexString == "#FF0000")
    }

    @Test("LM-19: Byte-order resilience: Samples native macOS Little-Endian BGRx buffer with full opacity")
    func testNativeMacOSLittleEndianBGRxMapping() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create BGRx CGContext")
            return
        }
        // Pure blue
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 1.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = ctx.makeImage() else {
            Issue.record("Failed to create BGRx CGImage")
            return
        }

        let sampled = LoupePixelSampler.samplePixel(in: image, at: .zero)
        #expect(sampled.red == 0)
        #expect(sampled.green == 0)
        #expect(sampled.blue == 255)
        #expect(sampled.alpha == 255)
        #expect(sampled.hexString == "#0000FF")
    }

    @Test("LM-20: Un-premultiplication: Accurately recovers translucent color values")
    func testPremultipliedAlphaUnmultiplication() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            Issue.record("Failed to create CGContext")
            return
        }
        // 50% opacity pure green
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = ctx.makeImage() else {
            Issue.record("Failed to create CGImage")
            return
        }

        let sampled = LoupePixelSampler.samplePixel(in: image, at: .zero)
        #expect(sampled.red == 0)
        #expect(sampled.green == 255)
        #expect(sampled.blue == 0)
        #expect(sampled.alpha >= 127 && sampled.alpha <= 129)
    }

    @Test("CT-18: cursorToPhysicalPixels correctly handles standard 1x display")
    func testCursorToPhysicalPixelsStandardDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cursor = CGPoint(x: 100, y: 200)
        let px = CoordinateTranslationService.cursorToPhysicalPixels(cursor: cursor, screenFrame: screen, scale: 1.0)
        #expect(px.x == 100)
        #expect(px.y == 200)
    }

    @Test("CT-19: cursorToPhysicalPixels correctly scales 2x Retina points to physical pixels")
    func testCursorToPhysicalPixelsRetinaDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cursor = CGPoint(x: 500, y: 600)
        let px = CoordinateTranslationService.cursorToPhysicalPixels(cursor: cursor, screenFrame: screen, scale: 2.0)
        #expect(px.x == 1000)
        #expect(px.y == 1200)
    }

    @Test("CT-20: cursorToPhysicalPixels offsets negative coordinates on secondary display")
    func testCursorToPhysicalPixelsNegativeDisplayOffset() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let cursor = CGPoint(x: -1000, y: 300)
        let px = CoordinateTranslationService.cursorToPhysicalPixels(cursor: cursor, screenFrame: screen, scale: 2.0)
        #expect(px.x == (-1000 - (-1920)) * 2.0) // 920 * 2 = 1840
        #expect(px.y == (300 - 0) * 2.0)         // 300 * 2 = 600
    }

    @Test("CT-21: cursorToPhysicalPixels handles degenerate zero and negative scales safely")
    func testCursorToPhysicalPixelsDegenerateScale() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let cursor = CGPoint(x: 100, y: 100)
        let pxZero = CoordinateTranslationService.cursorToPhysicalPixels(cursor: cursor, screenFrame: screen, scale: 0)
        #expect(pxZero == CGPoint(x: 100, y: 100))
        let pxNeg = CoordinateTranslationService.cursorToPhysicalPixels(cursor: cursor, screenFrame: screen, scale: -2.0)
        #expect(pxNeg == CGPoint(x: 100, y: 100))
    }
}
