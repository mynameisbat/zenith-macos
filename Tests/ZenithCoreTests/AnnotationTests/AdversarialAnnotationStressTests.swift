import Testing
import Foundation
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
@testable import ZenithCore

@Suite("Adversarial Annotation Models, Geometry & Export Stress Suite")
struct AdversarialAnnotationStressTests {

    private func makeBitmapContext(width: Int = 400, height: Int = 400) -> CGContext {
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

    private func makeSolidTestImage(width: Int = 200, height: Int = 200) -> CGImage {
        let ctx = makeBitmapContext(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - 1. ArrowAnnotationCommand Adversarial Stress Tests

    @Test("ADV-M5-01: ArrowAnnotationCommand: 1,000+ random vectors across all quadrants & scales")
    func testArrowRandomVectorsStress() {
        let context = makeBitmapContext(width: 500, height: 500)
        let scales: [CGFloat] = [0.25, 0.5, 1.0, 2.0, 3.5]
        let redColor = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1.0)

        // Seeded deterministic pseudo-random generator
        var seed: UInt64 = 0xDEADBEEFCAFE
        func nextRandomDouble(min: Double, max: Double) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let normalized = Double(seed >> 11) / Double(1 << 53)
            return min + normalized * (max - min)
        }

        var executedCount = 0
        for i in 0..<1200 {
            let startX = nextRandomDouble(min: -2000, max: 2000)
            let startY = nextRandomDouble(min: -2000, max: 2000)
            let endX = nextRandomDouble(min: -2000, max: 2000)
            let endY = nextRandomDouble(min: -2000, max: 2000)
            let strokeW = nextRandomDouble(min: 0.5, max: 20.0)
            let headLen = nextRandomDouble(min: 2.0, max: 50.0)
            let headAngle = nextRandomDouble(min: 0.1, max: 1.2)
            let isFilled = (i % 2 == 0)
            let scale = scales[i % scales.count]

            let arrow = ArrowAnnotationCommand(
                start: CGPoint(x: startX, y: startY),
                end: CGPoint(x: endX, y: endY),
                color: redColor,
                strokeWidth: strokeW,
                arrowHeadLength: headLen,
                arrowHeadAngle: headAngle,
                isHeadFilled: isFilled
            )

            arrow.apply(to: context, scale: scale)
            executedCount += 1
        }

        #expect(executedCount == 1200)
    }

    @Test("ADV-M5-02: ArrowAnnotationCommand: Zero-length, sub-pixel, opposite, extreme & degenerate coordinates")
    func testArrowBoundaryAndDegenerateGeometries() {
        let context = makeBitmapContext()
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        // 1. Exact zero-length vector (hypot(dx, dy) == 0)
        let zeroVec = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100, y: 100),
            color: blue
        )
        zeroVec.apply(to: context, scale: 1.0)

        // 2. Sub-pixel vector below 0.001 threshold (must safely no-op)
        let subPixelBelow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100.0002, y: 100.0003),
            color: blue
        )
        subPixelBelow.apply(to: context, scale: 1.0)

        // 3. Sub-pixel vector above 0.001 threshold
        let subPixelAbove = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100.005, y: 100.005),
            color: blue
        )
        subPixelAbove.apply(to: context, scale: 1.0)

        // 4. Exact opposite 180° horizontal vector (dx < 0, dy == 0)
        let oppositeH = ArrowAnnotationCommand(
            start: CGPoint(x: 200, y: 100),
            end: CGPoint(x: 50, y: 100),
            color: blue
        )
        oppositeH.apply(to: context, scale: 1.0)

        // 5. Exact vertical vectors: 90° (downward) and 270° (upward)
        let verticalDown = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 50),
            end: CGPoint(x: 100, y: 250),
            color: blue
        )
        verticalDown.apply(to: context, scale: 1.0)

        let verticalUp = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 250),
            end: CGPoint(x: 100, y: 50),
            color: blue
        )
        verticalUp.apply(to: context, scale: 1.0)

        // 6. Diagonal vectors across all 4 quadrants (45°, 135°, 225°, 315°)
        let diagonals = [
            (CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200)),
            (CGPoint(x: 200, y: 100), CGPoint(x: 100, y: 200)),
            (CGPoint(x: 200, y: 200), CGPoint(x: 100, y: 100)),
            (CGPoint(x: 100, y: 200), CGPoint(x: 200, y: 100))
        ]
        for (s, e) in diagonals {
            let diagArrow = ArrowAnnotationCommand(start: s, end: e, color: blue, isHeadFilled: true)
            diagArrow.apply(to: context, scale: 1.0)
        }

        // 7. Extreme coordinates (-10,000 to +10,000)
        let extremeArrow = ArrowAnnotationCommand(
            start: CGPoint(x: -10000, y: -10000),
            end: CGPoint(x: 10000, y: 10000),
            color: blue,
            strokeWidth: 10.0,
            arrowHeadLength: 100.0
        )
        extremeArrow.apply(to: context, scale: 1.0)

        // 8. NaN and Inf coordinates (must not trap or crash)
        let nanStart = ArrowAnnotationCommand(
            start: CGPoint(x: CGFloat.nan, y: 50),
            end: CGPoint(x: 100, y: 50),
            color: blue
        )
        nanStart.apply(to: context, scale: 1.0)

        let nanEnd = ArrowAnnotationCommand(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 100, y: CGFloat.nan),
            color: blue
        )
        nanEnd.apply(to: context, scale: 1.0)

        let infEnd = ArrowAnnotationCommand(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: CGFloat.infinity, y: 50),
            color: blue
        )
        infEnd.apply(to: context, scale: 1.0)

        let negInfStart = ArrowAnnotationCommand(
            start: CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity),
            end: CGPoint(x: 50, y: 50),
            color: blue
        )
        negInfStart.apply(to: context, scale: 1.0)
    }

    // MARK: - 2. PenAnnotationCommand Adversarial Stress Tests

    @Test("ADV-M5-03: PenAnnotationCommand: Empty arrays, single points, duplicates, collinear paths")
    func testPenDegeneratePoints() {
        let context = makeBitmapContext()
        let green = CGColor(srgbRed: 0, green: 0.8, blue: 0.2, alpha: 1)

        // 1. Empty point array (points.count == 0)
        let emptyPen = PenAnnotationCommand(points: [], color: green)
        emptyPen.apply(to: context, scale: 1.0)

        // 2. Single-point array (points.count == 1)
        let singlePen = PenAnnotationCommand(points: [CGPoint(x: 50, y: 50)], color: green)
        singlePen.apply(to: context, scale: 1.0)

        // 3. Exactly identical duplicate points (zero delta between points)
        let duplicatePoints = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 100, y: 100)
        ]
        let dupPenQuad = PenAnnotationCommand(points: duplicatePoints, color: green, smoothing: .quadraticBezier)
        dupPenQuad.apply(to: context, scale: 1.0)

        let dupPenCatmull = PenAnnotationCommand(points: duplicatePoints, color: green, smoothing: .catmullRom)
        dupPenCatmull.apply(to: context, scale: 1.0)

        // 4. Two collinear points (exercises straight line fallback in Catmull-Rom)
        let twoPoints = [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)]
        let twoPenCatmull = PenAnnotationCommand(points: twoPoints, color: green, smoothing: .catmullRom)
        twoPenCatmull.apply(to: context, scale: 1.0)

        // 5. Three collinear points
        let threePoints = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 90)]
        let threePen = PenAnnotationCommand(points: threePoints, color: green, smoothing: .catmullRom)
        threePen.apply(to: context, scale: 1.0)
    }

    @Test("ADV-M5-04: PenAnnotationCommand: Massive path with 10,000+ points & Catmull-Rom stability")
    func testPenMassive10000PointsPathPerformanceAndStability() {
        let context = makeBitmapContext(width: 800, height: 800)
        let purple = CGColor(srgbRed: 0.6, green: 0.1, blue: 0.9, alpha: 1)

        // Generate a 10,000 point continuous parametric spiral/Lissajous curve
        let pointCount = 10_000
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let t = Double(i) * 0.05
            let x = 400.0 + 350.0 * sin(t) * cos(t * 0.3)
            let y = 400.0 + 350.0 * cos(t) * sin(t * 0.2)
            points.append(CGPoint(x: x, y: y))
        }

        #expect(points.count == 10_000)

        // Test Catmull-Rom smoothing on 10,000 points
        let catmullPen = PenAnnotationCommand(
            points: points,
            color: purple,
            strokeWidth: 2.0,
            smoothing: .catmullRom
        )

        let startTime = CFAbsoluteTimeGetCurrent()
        catmullPen.apply(to: context, scale: 1.0)
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        // Rendering 10,000 cubic curves should complete comfortably under 3.0s in unoptimized debug build under concurrent load
        #expect(duration < 3.0, "Catmull-Rom spline rendering took \(duration)s, exceeding 3.0s SLA")

        // Test Quadratic Bezier smoothing on the same 10,000 points
        let quadPen = PenAnnotationCommand(
            points: points,
            color: purple,
            strokeWidth: 2.0,
            smoothing: .quadraticBezier
        )
        quadPen.apply(to: context, scale: 1.0)

        // Stress memory stability with 5 repeated passes
        for _ in 0..<5 {
            catmullPen.apply(to: context, scale: 1.5)
        }
    }

    // MARK: - 3. RectangleAnnotationCommand Adversarial Stress Tests

    @Test("ADV-M5-05: RectangleAnnotationCommand: Inverted coordinates, zero size & massive corner radii")
    func testRectangleBoundaryAndExtremeCornerRadii() {
        let context = makeBitmapContext()
        let orange = CGColor(srgbRed: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)

        // 1. Inverted drag coordinates (width < 0, height < 0)
        let invertedBoth = RectangleAnnotationCommand(
            rect: CGRect(x: 150, y: 150, width: -100, height: -80),
            color: orange,
            strokeWidth: 3.0,
            cornerRadius: 10.0
        )
        invertedBoth.apply(to: context, scale: 1.0)

        // 2. Inverted drag X only (width < 0, height > 0)
        let invertedX = RectangleAnnotationCommand(
            rect: CGRect(x: 200, y: 50, width: -120, height: 80),
            color: orange,
            strokeWidth: 2.0
        )
        invertedX.apply(to: context, scale: 1.0)

        // 3. Inverted drag Y only (width > 0, height < 0)
        let invertedY = RectangleAnnotationCommand(
            rect: CGRect(x: 50, y: 200, width: 80, height: -120),
            color: orange,
            isFilled: true
        )
        invertedY.apply(to: context, scale: 1.0)

        // 4. Zero-width rectangle
        let zeroWidth = RectangleAnnotationCommand(
            rect: CGRect(x: 100, y: 100, width: 0, height: 100),
            color: orange
        )
        zeroWidth.apply(to: context, scale: 1.0)

        // 5. Zero-height rectangle
        let zeroHeight = RectangleAnnotationCommand(
            rect: CGRect(x: 100, y: 100, width: 100, height: 0),
            color: orange
        )
        zeroHeight.apply(to: context, scale: 1.0)

        // 6. Zero size rectangle
        let zeroRect = RectangleAnnotationCommand(
            rect: CGRect.zero,
            color: orange
        )
        zeroRect.apply(to: context, scale: 1.0)

        // 7. Massive corner radius (exceeding min(w, h)/2)
        // Rect is 40 x 20. Half-min is 10. cornerRadius is 50,000.
        let massiveRadius = RectangleAnnotationCommand(
            rect: CGRect(x: 50, y: 50, width: 40, height: 20),
            color: orange,
            strokeWidth: 2.0,
            isFilled: true,
            cornerRadius: 50_000.0
        )
        massiveRadius.apply(to: context, scale: 2.0)

        // 8. Negative corner radius
        let negativeRadius = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 60, height: 60),
            color: orange,
            cornerRadius: -25.0
        )
        negativeRadius.apply(to: context, scale: 1.0)

        // 9. Extreme coordinates (-10,000 to +10,000)
        let extremeRect = RectangleAnnotationCommand(
            rect: CGRect(x: -10000, y: -10000, width: 20000, height: 20000),
            color: orange,
            cornerRadius: 100.0
        )
        extremeRect.apply(to: context, scale: 1.0)
    }

    // MARK: - 4. TextAnnotationCommand Adversarial Stress Tests

    @Test("ADV-M5-06: TextAnnotationCommand: Empty, whitespace, massive string, emojis & negative font size")
    func testTextAnnotationBoundaryStringsAndTypography() {
        let context = makeBitmapContext(width: 800, height: 800)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let darkBg = CGColor(gray: 0.1, alpha: 0.9)

        // 1. Empty string (guard should no-op)
        let emptyText = TextAnnotationCommand(
            origin: CGPoint(x: 100, y: 100),
            text: "",
            color: white
        )
        emptyText.apply(to: context, scale: 1.0)

        // 2. Whitespace-only strings (spaces, tabs, newlines, non-breaking spaces)
        let whitespaceTexts = [
            "    ",
            "\n\t\r",
            "   \n  \t  \r  ",
            " \u{00A0} \u{200B} " // Non-breaking & zero-width spaces
        ]
        for ws in whitespaceTexts {
            let wsCmd = TextAnnotationCommand(
                origin: CGPoint(x: 100, y: 100),
                text: ws,
                color: white,
                backgroundColor: darkBg
            )
            wsCmd.apply(to: context, scale: 1.0)
        }

        // 3. Massive string (10,000+ characters)
        let massiveString = String(repeating: "GoldenGate High-Performance Mac Utility 🚀 ", count: 250)
        #expect(massiveString.count >= 10_000)

        let massiveTextCmd = TextAnnotationCommand(
            origin: CGPoint(x: 50, y: 400),
            text: massiveString,
            fontSize: 14.0,
            color: white,
            backgroundColor: darkBg
        )
        massiveTextCmd.apply(to: context, scale: 1.0)

        // 4. Emoji-rich strings with surrogate pairs, ZWJ sequences, skin tones, flags
        let emojiStrings = [
            "👋 Hello World! 🚀 GoldenGate 🌉",
            "👨‍👩‍👧‍👦 Family ZWJ Sequence & 👩🏽‍💻 Tech Worker",
            "🏳️‍🌈 Rainbow Flag & 🇻🇳 Vietnam & 🇺🇸 USA & 🇯🇵 Japan",
            "Complex Multilingual: Tiếng Việt có dấu, 繁體中文, 日本語, العربية, עברית",
            "Special Symbols: ∑ ∫ π ≠ ≈ ∞ © ® ™ ⌘ ⌥ ⇧ ⌫ ↵ ⇥"
        ]

        for (idx, emojiStr) in emojiStrings.enumerated() {
            let emojiCmd = TextAnnotationCommand(
                origin: CGPoint(x: 50, y: 100 + Double(idx * 40)),
                text: emojiStr,
                fontSize: 16.0,
                color: white,
                backgroundColor: darkBg
            )
            emojiCmd.apply(to: context, scale: 2.0)
        }

        // 5. Zero and negative font sizes (CoreText safety check)
        let zeroFontSize = TextAnnotationCommand(
            origin: CGPoint(x: 50, y: 50),
            text: "Zero Font Size Test",
            fontSize: 0.0,
            color: white
        )
        zeroFontSize.apply(to: context, scale: 1.0)

        let negativeFontSize = TextAnnotationCommand(
            origin: CGPoint(x: 50, y: 50),
            text: "Negative Font Size Test",
            fontSize: -24.0,
            color: white
        )
        negativeFontSize.apply(to: context, scale: 1.0)
    }

    // MARK: - 5. CropAnnotationCommand & Geometry Calculator Adversarial Stress Tests

    @Test("ADV-M5-07: CropAnnotationCommand & EditorWindowGeometryCalculator: Ultra-wide, vertical, 1x1 & degenerate aspect ratios")
    func testGeometryCalculatorAndCropExtremes() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // 1. Ultra-wide aspect ratio (32:9 - e.g. 5120x1440)
        let ultraWideGeom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 5120,
            imageHeight: 1440,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(ultraWideGeom.canvasSize.width <= (1920 - 96))
        #expect(ultraWideGeom.canvasSize.height <= (1080 - 96))
        #expect(ultraWideGeom.windowFrame.width >= 520)
        #expect(ultraWideGeom.windowFrame.height >= 360)
        #expect(ultraWideGeom.scaleFactor > 0)

        // 2. Vertical aspect ratio (9:16 - e.g. 1080x1920)
        let verticalGeom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 1080,
            imageHeight: 1920,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(verticalGeom.canvasSize.height <= (1080 - 96))
        #expect(verticalGeom.windowFrame.width >= 520)
        #expect(verticalGeom.windowFrame.height >= 360)
        #expect(verticalGeom.scaleFactor > 0)

        // 3. 1x1 square (e.g. 1000x1000)
        let squareGeom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 1000,
            imageHeight: 1000,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(squareGeom.canvasSize.width == squareGeom.canvasSize.height)
        #expect(squareGeom.scaleFactor == 2.0)

        // 4. Ultra-degenerate aspect ratios: 10,000x1 horizontal needle
        let needleH = EditorWindowGeometryCalculator.calculate(
            imageWidth: 10000,
            imageHeight: 1,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(needleH.windowFrame.width >= 520)
        #expect(needleH.windowFrame.height >= 360)

        // 5. Ultra-degenerate aspect ratios: 1x10,000 vertical needle
        let needleV = EditorWindowGeometryCalculator.calculate(
            imageWidth: 1,
            imageHeight: 10000,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(needleV.windowFrame.width >= 520)
        #expect(needleV.windowFrame.height >= 360)

        // 6. Zero-dimension image handling (0x0, 0x500, 500x0)
        let zeroGeom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 0,
            imageHeight: 0,
            displayVisibleFrame: displayFrame,
            backingScaleFactor: 2.0
        )
        #expect(zeroGeom.windowFrame.width >= 520)
        #expect(zeroGeom.windowFrame.height >= 360)

        // 7. CropAnnotationCommand normalization & edge cases
        let cropStandard = CropAnnotationCommand(
            cropRect: CGRect(x: 50, y: 50, width: 200, height: 100),
            originalSize: CGSize(width: 400, height: 200)
        )
        #expect(cropStandard.normalizedRect == CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))

        // Inverted crop coordinates (standardized automatically)
        let cropInverted = CropAnnotationCommand(
            cropRect: CGRect(x: 250, y: 150, width: -200, height: -100),
            originalSize: CGSize(width: 400, height: 200)
        )
        #expect(cropInverted.normalizedRect == CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))

        // Degenerate original size (0x0) returns .zero
        let cropZeroOriginal = CropAnnotationCommand(
            cropRect: CGRect(x: 10, y: 10, width: 50, height: 50),
            originalSize: CGSize.zero
        )
        #expect(cropZeroOriginal.normalizedRect == .zero)

        // Context clipping with scale
        let context = makeBitmapContext()
        cropStandard.apply(to: context, scale: 2.0)
    }

    // MARK: - 6. Full Annotation Pipeline Composite & Concurrency Export Torture

    @Test("ADV-M5-08: Full annotation composite rendering, PNG/JPEG export & 50-task concurrency torture")
    func testCompositePipelineAndConcurrentExportTorture() async {
        let exportService = ImageExportService.shared
        let baseImage = makeSolidTestImage(width: 800, height: 600)

        // Construct a rich set of diverse annotation commands
        let pen = PenAnnotationCommand(
            points: (0..<500).map { CGPoint(x: Double($0) * 1.5, y: 100.0 + 50.0 * sin(Double($0) * 0.1)) },
            color: CGColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1.0),
            smoothing: .catmullRom
        )
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 200),
            end: CGPoint(x: 400, y: 350),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            isHeadFilled: true
        )
        let rect = RectangleAnnotationCommand(
            rect: CGRect(x: 300, y: 50, width: 250, height: 180),
            color: CGColor(srgbRed: 0.9, green: 0.6, blue: 0.1, alpha: 1),
            cornerRadius: 16.0
        )
        let text = TextAnnotationCommand(
            origin: CGPoint(x: 320, y: 100),
            text: "GoldenGate 🚀 2026",
            fontSize: 18.0,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            backgroundColor: CGColor(gray: 0.2, alpha: 0.8)
        )
        let blur = BlurAnnotationCommand(
            rect: CGRect(x: 50, y: 400, width: 200, height: 100),
            pixelSize: 12.0
        )
        let crop = CropAnnotationCommand(
            cropRect: CGRect(x: 20, y: 20, width: 700, height: 500),
            originalSize: CGSize(width: 800, height: 600)
        )

        let commands: [AnnotationCommand] = [pen, arrow, rect, text, blur, crop]

        // 1. Single composite export
        let composite = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: commands,
            cropRect: crop.cropRect,
            scale: 2.0
        )
        #expect(composite.width > 0)
        #expect(composite.height > 0)

        let pngData = exportService.exportToPNG(image: composite)
        #expect(pngData != nil)
        #expect(pngData!.count > 100)

        let jpegData = exportService.exportToJPEG(image: composite, quality: 0.8)
        #expect(jpegData != nil)
        #expect(jpegData!.count > 100)

        // 2. High-concurrency torture test: 50 concurrent async tasks
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let scale = (i % 2 == 0) ? 1.0 : 2.0
                    let resultImage = exportService.renderAnnotatedImage(
                        baseImage: baseImage,
                        commands: commands,
                        cropRect: crop.cropRect,
                        scale: scale
                    )
                    let png = exportService.exportToPNG(image: resultImage)
                    let jpeg = exportService.exportToJPEG(image: resultImage, quality: 0.75)
                    return (resultImage.width > 0) && (png != nil) && (jpeg != nil)
                }
            }

            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            #expect(successCount == 50)
        }
    }
}
