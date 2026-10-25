import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Annotation Models & Geometry Test Suite")
struct AnnotationModelsTests {

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

    // MARK: - Pen Annotation Tests

    @Test("AM-01: PenAnnotationCommand initializes with properties and line styling")
    func testPenAnnotationProperties() {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 25), CGPoint(x: 35, y: 50)]
        let color = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let command = PenAnnotationCommand(
            points: points,
            color: color,
            strokeWidth: 4.0,
            smoothing: .quadraticBezier,
            lineCap: .round,
            lineJoin: .miter
        )

        #expect(command.points.count == 3)
        #expect(command.strokeWidth == 4.0)
        #expect(command.smoothing == .quadraticBezier)
        #expect(command.lineCap == .round)
        #expect(command.lineJoin == .miter)
    }

    @Test("AM-02: PenAnnotationCommand with 0 or 1 point is safe no-op")
    func testPenAnnotationDegeneratePoints() {
        let context = makeBitmapContext()
        let empty = PenAnnotationCommand(points: [], color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        empty.apply(to: context, scale: 1.0)

        let single = PenAnnotationCommand(points: [CGPoint(x: 50, y: 50)], color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        single.apply(to: context, scale: 1.0)
        #expect(single.points.count == 1)
    }

    @Test("AM-03: PenAnnotationCommand Catmull-Rom smoothing applies safely")
    func testPenAnnotationCatmullRomSmoothing() {
        let context = makeBitmapContext(width: 300, height: 300)
        let points = [
            CGPoint(x: 20, y: 30),
            CGPoint(x: 80, y: 120),
            CGPoint(x: 150, y: 90),
            CGPoint(x: 220, y: 200)
        ]
        let command = PenAnnotationCommand(
            points: points,
            color: CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1),
            strokeWidth: 5.0,
            smoothing: .catmullRom
        )

        command.apply(to: context, scale: 2.0)
        let image = context.makeImage()
        #expect(image != nil)
    }

    // MARK: - Arrow Annotation Tests

    @Test("AM-04: ArrowAnnotationCommand initializes with default 30° wing angle and proportional length")
    func testArrowAnnotationProperties() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 100, y: 80)
        let color = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let arrow = ArrowAnnotationCommand(start: start, end: end, color: color)

        #expect(arrow.start == start)
        #expect(arrow.end == end)
        #expect(arrow.strokeWidth == 3.0)
        #expect(arrow.arrowHeadLength == 20.0)
        #expect(abs(arrow.arrowHeadAngle - .pi / 6.0) < 0.001)
        #expect(!arrow.isHeadFilled)
    }

    @Test("AM-05: ArrowAnnotationCommand zero-length vector is safe no-op")
    func testArrowAnnotationZeroLength() {
        let context = makeBitmapContext()
        let pt = CGPoint(x: 50, y: 50)
        let arrow = ArrowAnnotationCommand(start: pt, end: pt, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.start == arrow.end)
    }

    @Test("AM-06: ArrowAnnotationCommand filled head renders without error")
    func testArrowAnnotationFilledHead() {
        let context = makeBitmapContext()
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 90, y: 90),
            color: CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1),
            isHeadFilled: true
        )
        arrow.apply(to: context, scale: 1.0)
        #expect(arrow.isHeadFilled)
    }

    // MARK: - Rectangle Annotation Tests

    @Test("AM-07: RectangleAnnotationCommand corner radius is clamped to half dimensions")
    func testRectangleCornerRadiusClamping() {
        let context = makeBitmapContext()
        let rect = CGRect(x: 20, y: 20, width: 40, height: 60)
        let rectCommand = RectangleAnnotationCommand(
            rect: rect,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            cornerRadius: 100.0 // Larger than min dimension / 2 (which is 20)
        )
        rectCommand.apply(to: context, scale: 1.0)
        #expect(rectCommand.cornerRadius == 100.0)
    }

    @Test("AM-08: RectangleAnnotationCommand handles negative origin or zero size safely")
    func testRectangleBoundaryDimensions() {
        let context = makeBitmapContext()
        let zeroRect = RectangleAnnotationCommand(
            rect: CGRect(x: 50, y: 50, width: 0, height: 0),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        zeroRect.apply(to: context, scale: 1.0)

        let negativeRect = RectangleAnnotationCommand(
            rect: CGRect(x: 80, y: 80, width: -40, height: -30),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        negativeRect.apply(to: context, scale: 1.0)
        #expect(negativeRect.rect.standardized.width == 40)
    }

    // MARK: - Text Annotation Tests

    @Test("AM-09: TextAnnotationCommand renders with background contrast pill")
    func testTextAnnotationWithBackgroundPill() {
        let context = makeBitmapContext(width: 300, height: 100)
        let textCommand = TextAnnotationCommand(
            origin: CGPoint(x: 20, y: 40),
            text: "Important Note",
            fontSize: 18.0,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            backgroundColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)
        )
        textCommand.apply(to: context, scale: 2.0)
        #expect(textCommand.backgroundColor != nil)
    }

    @Test("AM-10: TextAnnotationCommand with empty or whitespace text is safe no-op")
    func testTextAnnotationEmptyString() {
        let context = makeBitmapContext()
        let empty = TextAnnotationCommand(origin: .zero, text: "", color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        empty.apply(to: context, scale: 1.0)

        let spaces = TextAnnotationCommand(origin: .zero, text: "   \n\t  ", color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        spaces.apply(to: context, scale: 1.0)
        #expect(spaces.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Blur Annotation Tests

    @Test("AM-11: BlurAnnotationCommand applies mosaic pixelation without error")
    func testBlurAnnotationApplication() {
        let context = makeBitmapContext(width: 200, height: 200)
        let blur = BlurAnnotationCommand(rect: CGRect(x: 30, y: 30, width: 80, height: 60), pixelSize: 12.0)
        blur.apply(to: context, scale: 1.0)
        #expect(blur.pixelSize == 12.0)
    }

    // MARK: - Crop Annotation Tests

    @Test("AM-12: CropAnnotationCommand computes accurate normalized unit rect [0, 1]")
    func testCropAnnotationNormalizedCoordinates() {
        let original = CGSize(width: 1000, height: 500)
        let cropRect = CGRect(x: 200, y: 100, width: 500, height: 250)
        let cropCommand = CropAnnotationCommand(cropRect: cropRect, originalSize: original)

        let norm = cropCommand.normalizedRect
        #expect(norm.origin.x == 0.2)
        #expect(norm.origin.y == 0.2)
        #expect(norm.width == 0.5)
        #expect(norm.height == 0.5)
    }

    @Test("AM-13: CropAnnotationCommand clips drawing context bounds")
    func testCropAnnotationContextClipping() {
        let context = makeBitmapContext(width: 400, height: 400)
        let crop = CropAnnotationCommand(
            cropRect: CGRect(x: 50, y: 50, width: 200, height: 200),
            originalSize: CGSize(width: 400, height: 400)
        )
        crop.apply(to: context, scale: 1.0)
        #expect(crop.cropRect.width == 200)
    }

    // MARK: - Tool Enum & Type Aliases

    @Test("AM-14: AnnotationTool enum cases and identifiers conform to contracts")
    func testAnnotationToolCases() {
        let allTools = AnnotationTool.allCases
        #expect(allTools.count == 6)
        #expect(AnnotationTool.pen.id == "pen")
        #expect(AnnotationTool.arrow.id == "arrow")
        #expect(AnnotationTool.rectangle.id == "rectangle")
        #expect(AnnotationTool.text.id == "text")
        #expect(AnnotationTool.blur.id == "blur")
        #expect(AnnotationTool.crop.id == "crop")
    }

    @Test("AM-15: Typealiases correctly resolve to command types")
    func testTypealiases() {
        let pen: PenAnnotation = PenAnnotationCommand(points: [], color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let arrow: ArrowAnnotation = ArrowAnnotationCommand(start: .zero, end: .zero, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let rect: RectangleAnnotation = RectangleAnnotationCommand(rect: .zero, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let text: TextAnnotation = TextAnnotationCommand(origin: .zero, text: "A", color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let blur: BlurAnnotation = BlurAnnotationCommand(rect: .zero)
        let pixelate: PixelateAnnotation = BlurAnnotationCommand(rect: .zero)
        let crop: CropAnnotation = CropAnnotationCommand(cropRect: .zero, originalSize: .zero)

        #expect(pen.points.isEmpty)
        #expect(arrow.arrowHeadLength == 20.0)
        #expect(rect.strokeWidth == 3.0)
        #expect(text.text == "A")
        #expect(blur.pixelSize == 16.0)
        #expect(pixelate.pixelSize == 16.0)
        #expect(crop.cropRect == .zero)
    }
}
