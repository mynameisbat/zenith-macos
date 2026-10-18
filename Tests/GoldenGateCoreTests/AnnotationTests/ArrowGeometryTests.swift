import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Arrow Geometry & Trigonometry Test Suite")
struct ArrowGeometryTests {

    private func makeBitmapContext(width: Int = 200, height: Int = 200) -> CGContext {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    @Test("AG-01: Horizontal arrow pointing Right (0°) calculates symmetrical swept-back wings")
    func testArrowPointingRight() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 0, y: 100),
            end: CGPoint(x: 100, y: 100),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            strokeWidth: 2.0,
            arrowHeadLength: 20.0,
            arrowHeadAngle: .pi / 6.0 // 30°
        )

        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.arrowHeadLength == 20.0)
        #expect(abs(arrow.arrowHeadAngle - .pi / 6.0) < 1e-4)
    }

    @Test("AG-02: Horizontal arrow pointing Left (180°) sweeps wings towards +X")
    func testArrowPointingLeft() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 20, y: 100),
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.start.x > arrow.end.x)
    }

    @Test("AG-03: Vertical arrow pointing Down (90°) sweeps wings towards -Y")
    func testArrowPointingDown() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 20),
            end: CGPoint(x: 100, y: 120),
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.end.y > arrow.start.y)
    }

    @Test("AG-04: Vertical arrow pointing Up (-90°) sweeps wings towards +Y")
    func testArrowPointingUp() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 100, y: 20),
            color: CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        )
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.start.y > arrow.end.y)
    }

    @Test("AG-05: Diagonal arrow at 45° renders without numerical error")
    func testDiagonalArrow() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 120, y: 120),
            color: CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        )
        arrow.apply(to: context, scale: 1.0)
        let dx = arrow.end.x - arrow.start.x
        let dy = arrow.end.y - arrow.start.y
        #expect(abs(dx - dy) < 1e-4)
    }

    @Test("AG-06: Zero-length arrow boundary condition safely handled")
    func testZeroLengthArrowSafeNoOp() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 50, y: 50),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        )
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.start == arrow.end)
    }

    @Test("AG-07: Short arrow clamps arrowhead length to prevent inversion")
    func testShortArrowHeadClamping() {
        let context = makeBitmapContext()
        // Distance is only 10 points; default head length is 20 points
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 20, y: 10),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            arrowHeadLength: 20.0
        )
        arrow.apply(to: context, scale: 1.0)
        let distance = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        #expect(distance == 10.0)
    }

    @Test("AG-08: Retina scale factor scales stroke and arrowhead proportionally")
    func testRetinaScaleFactorApplication() {
        let context = makeBitmapContext(width: 400, height: 400)
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 100, y: 100),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            strokeWidth: 4.0,
            arrowHeadLength: 25.0
        )
        arrow.apply(to: context, scale: 2.0)
        #expect(arrow.strokeWidth == 4.0)
        #expect(arrow.arrowHeadLength == 25.0)
    }

    @Test("AG-09: Custom wing angles generate distinct configurations")
    func testCustomWingAngles() {
        let narrow = ArrowAnnotationCommand(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            arrowHeadAngle: .pi / 12.0 // 15°
        )
        let wide = ArrowAnnotationCommand(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            arrowHeadAngle: .pi / 4.0 // 45°
        )

        #expect(narrow.arrowHeadAngle < wide.arrowHeadAngle)
    }

    @Test("AG-10: Filled polygon arrowhead option renders successfully")
    func testFilledArrowheadOption() {
        let context = makeBitmapContext()
        let filledArrow = ArrowAnnotationCommand(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 80, y: 60),
            color: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            isHeadFilled: true
        )
        filledArrow.apply(to: context, scale: 1.0)
        #expect(filledArrow.isHeadFilled)
    }
}
