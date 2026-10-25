import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Coordinate Translation & Multi-Display Geometry Test Suite")
struct CoordinateTranslationTests {
    let primaryScreenHeight: CGFloat = 1080

    @Test("CT-01: Translates AppKit point to CoreGraphics point on primary display")
    func testPointFlipping() {
        let appKitPoint = CGPoint(x: 150, y: 250)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: appKitPoint,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == 150)
        #expect(cgPoint.y == 830) // 1080 - 250
    }

    @Test("CT-02: Single Display Origin Flipping")
    func testOriginFlipping() {
        let appKitPoint = CGPoint(x: 0, y: 0)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: appKitPoint,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == 0)
        #expect(cgPoint.y == 1080)
    }

    @Test("CT-03: Single Display Top-Left Flipping")
    func testTopLeftFlipping() {
        let appKitPoint = CGPoint(x: 0, y: 1080)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: appKitPoint,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == 0)
        #expect(cgPoint.y == 0)
    }

    @Test("CT-04: Involutive property holds: double flip restores original point")
    func testInvolutivePointFlipping() {
        let original = CGPoint(x: 342.5, y: 789.25)
        let flipped = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: original,
            primaryScreenHeight: primaryScreenHeight
        )
        let restored = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            point: flipped,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(restored == original)
    }

    @Test("CT-05: Rect Flipping converts AppKit bottom-left to CoreGraphics top-left rect")
    func testRectFlipping() {
        let appKitRect = CGRect(x: 50, y: 100, width: 300, height: 200)
        let cgRect = CoordinateTranslationService.flipAppKitToCoreGraphics(
            rect: appKitRect,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgRect.origin.x == 50)
        #expect(cgRect.origin.y == 780) // 1080 - (100 + 200)
        #expect(cgRect.width == 300)
        #expect(cgRect.height == 200)
    }

    @Test("CT-06: Rect Flipping Involutive Round-Trip")
    func testInvolutiveRectFlipping() {
        let original = CGRect(x: 123.4, y: 567.8, width: 400, height: 250)
        let flipped = CoordinateTranslationService.flipAppKitToCoreGraphics(
            rect: original,
            primaryScreenHeight: primaryScreenHeight
        )
        let restored = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            rect: flipped,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(restored.origin.x == original.origin.x)
        #expect(restored.origin.y == original.origin.y)
        #expect(restored.width == original.width)
        #expect(restored.height == original.height)
    }

    @Test("CT-07: Translates point on secondary monitor placed to the left with negative X")
    func testNegativeXOriginMonitor() {
        let pointOnSecondary = CGPoint(x: -500, y: 400)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointOnSecondary,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == -500)
        #expect(cgPoint.y == 680) // 1080 - 400
    }

    @Test("CT-08: Translates point on secondary monitor placed vertically above")
    func testVerticalAboveMonitor() {
        let pointOnSecondary = CGPoint(x: 200, y: 1500)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointOnSecondary,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == 200)
        #expect(cgPoint.y == -420) // 1080 - 1500
    }

    @Test("CT-09: Translates point on secondary monitor placed vertically below")
    func testVerticalBelowMonitor() {
        let pointOnSecondary = CGPoint(x: 200, y: -200)
        let cgPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointOnSecondary,
            primaryScreenHeight: primaryScreenHeight
        )
        #expect(cgPoint.x == 200)
        #expect(cgPoint.y == 1280) // 1080 - (-200)
    }

    @Test("CT-10: Scales points to physical backing pixels for 2x Retina display")
    func testRetinaBackingPixelScaling() {
        let pointRect = CGRect(x: 100, y: 150, width: 400, height: 300)
        let pixelRect = CoordinateTranslationService.pointsToPhysicalPixels(rect: pointRect, scale: 2.0)
        #expect(pixelRect.origin.x == 200)
        #expect(pixelRect.origin.y == 300)
        #expect(pixelRect.width == 800)
        #expect(pixelRect.height == 600)
    }

    @Test("CT-11: Points to Physical Pixels on Standard 1x Display")
    func testStandardDisplayScaling() {
        let pointRect = CGRect(x: 100, y: 150, width: 400, height: 300)
        let pixelRect = CoordinateTranslationService.pointsToPhysicalPixels(rect: pointRect, scale: 1.0)
        #expect(pixelRect == pointRect)
    }

    @Test("CT-12: Points to Physical Pixels on High-DPI 3x Display")
    func testHighDPI3xScaling() {
        let pointRect = CGRect(x: 100, y: 150, width: 400, height: 300)
        let pixelRect = CoordinateTranslationService.pointsToPhysicalPixels(rect: pointRect, scale: 3.0)
        #expect(pixelRect.origin.x == 300)
        #expect(pixelRect.origin.y == 450)
        #expect(pixelRect.width == 1200)
        #expect(pixelRect.height == 900)
    }

    @Test("CT-13: Pixel to Point Round-Trip")
    func testPixelToPointRoundTrip() {
        let original = CGRect(x: 120, y: 80, width: 640, height: 480)
        let pixels = CoordinateTranslationService.pointsToPhysicalPixels(rect: original, scale: 2.0)
        let restored = CoordinateTranslationService.physicalPixelsToPoints(rect: pixels, scale: 2.0)
        #expect(restored == original)
    }

    @Test("CT-14: Fractional Point Scale Round-Trip")
    func testFractionalPointScaling() {
        let pt = CGPoint(x: 10.5, y: 20.5)
        let pixelPt = CoordinateTranslationService.pointsToPhysicalPixels(point: pt, scale: 2.0)
        #expect(pixelPt == CGPoint(x: 21, y: 41))
        let restored = CoordinateTranslationService.physicalPixelsToPoints(point: pixelPt, scale: 2.0)
        #expect(restored == pt)
    }

    @Test("CT-15: Screen Boundary Clamping (Right Edge)")
    func testScreenBoundaryClampingRightEdge() {
        let rect = CGRect(x: 1800, y: 100, width: 300, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = CoordinateTranslationService.clamp(rect: rect, to: bounds)
        #expect(clamped == CGRect(x: 1800, y: 100, width: 120, height: 200))
    }

    @Test("CT-16: Screen Boundary Clamping (Bottom Edge)")
    func testScreenBoundaryClampingBottomEdge() {
        let rect = CGRect(x: 100, y: -50, width: 300, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = CoordinateTranslationService.clamp(rect: rect, to: bounds)
        #expect(clamped.origin.y == 0)
        #expect(clamped.height == 150)
    }

    @Test("CT-17: Screen Boundary Clamping (Full Containment / Out of Bounds)")
    func testScreenBoundaryClampingOutOfBounds() {
        let rect = CGRect(x: -500, y: -500, width: 200, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = CoordinateTranslationService.clamp(rect: rect, to: bounds)
        #expect(clamped.width == 0)
        #expect(clamped.height == 0)
    }
}
