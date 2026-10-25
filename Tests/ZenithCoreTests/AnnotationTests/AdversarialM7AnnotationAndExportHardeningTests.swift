import Testing
import Foundation
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
@testable import ZenithCore

@Suite("Adversarial M7 Annotation, Command Stack & High-Resolution Export Hardening Suite")
struct AdversarialM7AnnotationAndExportHardeningTests {

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
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.9, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - 1. AnnotationModels White-Box Branch Hardening

    @Test("ADV-M7-AN-01: PenAnnotationCommand: 0, 1 point no-op; 2-point line; coincident points across algorithms")
    func testPenAnnotationCommandBranches() {
        let ctx = makeBitmapContext()
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        // 0 points: safe no-op
        let pen0 = PenAnnotationCommand(points: [], color: red)
        pen0.apply(to: ctx, scale: 2.0)

        // 1 point: safe no-op
        let pen1 = PenAnnotationCommand(points: [CGPoint(x: 50, y: 50)], color: red)
        pen1.apply(to: ctx, scale: 2.0)

        // 2 points with Catmull-Rom: straight line branch
        let penCatmull2 = PenAnnotationCommand(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)],
            color: red,
            smoothing: .catmullRom
        )
        penCatmull2.apply(to: ctx, scale: 2.0)

        // 2 points with Quadratic Bezier
        let penQuad2 = PenAnnotationCommand(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)],
            color: red,
            smoothing: .quadraticBezier
        )
        penQuad2.apply(to: ctx, scale: 2.0)

        // Coincident identical points
        let penCoincident = PenAnnotationCommand(
            points: [CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50)],
            color: red,
            smoothing: .catmullRom
        )
        penCoincident.apply(to: ctx, scale: 1.0)
    }

    @Test("ADV-M7-AN-02: ArrowAnnotationCommand: Proportional head clamping to 45% of distance & filled vs stroked")
    func testArrowAnnotationHeadClampingAndStyles() {
        let ctx = makeBitmapContext()
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        // Short vector (length = 10 pt) with huge arrowHeadLength (50 pt)
        // Must clamp head length to 10 * scale * 0.45 = 4.5 pt
        let arrowClamped = ArrowAnnotationCommand(
            start: CGPoint(x: 20, y: 20),
            end: CGPoint(x: 30, y: 20),
            color: blue,
            strokeWidth: 2.0,
            arrowHeadLength: 50.0,
            isHeadFilled: true
        )
        arrowClamped.apply(to: ctx, scale: 1.0)

        // Unfilled arrow head branch
        let arrowUnfilled = ArrowAnnotationCommand(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 150, y: 150),
            color: blue,
            strokeWidth: 3.0,
            arrowHeadLength: 15.0,
            isHeadFilled: false
        )
        arrowUnfilled.apply(to: ctx, scale: 1.0)

        // Sub-pixel degenerate vector <= 0.001 distance (safe no-op)
        let arrowDegenerate = ArrowAnnotationCommand(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100.0005, y: 100.0005),
            color: blue
        )
        arrowDegenerate.apply(to: ctx, scale: 1.0)
    }

    @Test("ADV-M7-AN-03: RectangleAnnotationCommand: Inverted coordinates, negative cornerRadius & maximum clamping")
    func testRectangleAnnotationBranches() {
        let ctx = makeBitmapContext()
        let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

        // Inverted rect (negative width and height): standardized internally
        let invertedRect = RectangleAnnotationCommand(
            rect: CGRect(x: 150, y: 150, width: -100, height: -80),
            color: green,
            strokeWidth: 2.0,
            isFilled: false,
            cornerRadius: 10.0
        )
        invertedRect.apply(to: ctx, scale: 1.5)

        // Negative cornerRadius: clamped to 0 (sharp rect path)
        let negativeRadius = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 100, height: 100),
            color: green,
            cornerRadius: -5.0
        )
        negativeRadius.apply(to: ctx, scale: 1.0)

        // Excessive cornerRadius (100 pt for a 50x50 rect): clamped to 25 pt (half min dimension)
        let excessiveRadius = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 50, height: 50),
            color: green,
            isFilled: true,
            cornerRadius: 100.0
        )
        excessiveRadius.apply(to: ctx, scale: 1.0)

        // Zero area rect: safe no-op
        let zeroRect = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 0, height: 50),
            color: green
        )
        zeroRect.apply(to: ctx, scale: 1.0)
    }

    @Test("ADV-M7-AN-04: TextAnnotationCommand: Whitespace trimming no-op & background pill rendering")
    func testTextAnnotationBranches() {
        let ctx = makeBitmapContext()
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)

        // Whitespace-only text: safe no-op
        let whitespaceText = TextAnnotationCommand(
            origin: CGPoint(x: 20, y: 20),
            text: "   \t\n  ",
            color: white
        )
        whitespaceText.apply(to: ctx, scale: 1.0)

        // Normal text with background pill
        let textWithPill = TextAnnotationCommand(
            origin: CGPoint(x: 50, y: 50),
            text: "Adversarial GoldenGate M7",
            fontSize: 18.0,
            color: white,
            backgroundColor: black
        )
        textWithPill.apply(to: ctx, scale: 2.0)
    }

    @Test("ADV-M7-AN-05: CropAnnotationCommand: Non-positive original sizes & scale application")
    func testCropAnnotationCommandBranches() {
        let ctx = makeBitmapContext()

        // Zero original size returns .zero normalizedRect
        let zeroCrop = CropAnnotationCommand(
            cropRect: CGRect(x: 10, y: 10, width: 50, height: 50),
            originalSize: .zero
        )
        #expect(zeroCrop.normalizedRect == .zero)

        // Negative original size returns .zero normalizedRect
        let negCrop = CropAnnotationCommand(
            cropRect: CGRect(x: 10, y: 10, width: 50, height: 50),
            originalSize: CGSize(width: -100, height: 100)
        )
        #expect(negCrop.normalizedRect == .zero)

        // Valid original size: normalized to [0, 1] range
        let validCrop = CropAnnotationCommand(
            cropRect: CGRect(x: 25, y: 50, width: 50, height: 100),
            originalSize: CGSize(width: 100, height: 200)
        )
        #expect(validCrop.normalizedRect == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        // Clip context
        validCrop.apply(to: ctx, scale: 2.0)
    }

    // MARK: - 2. ImageExportService Pipeline & Quality Clamping Hardening

    @Test("ADV-M7-IE-01: Zero-size baseImage guard, out-of-bounds crops & JPEG quality clamping")
    func testImageExportServiceEdgeCases() {
        let service = ImageExportService.shared
        let baseImage = makeSolidTestImage(width: 200, height: 200)

        // 1. Out-of-bounds crop rect completely outside base image
        let outsideCrop = CGRect(x: 500, y: 500, width: 100, height: 100)
        let compositeOutside = service.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [],
            cropRect: outsideCrop,
            scale: 1.0
        )
        // When clamped crop rect is zero area, cropping is bypassed and composite is returned
        #expect(compositeOutside.width == 200)
        #expect(compositeOutside.height == 200)

        // 2. Crop partially exceeding base image (clamped to valid subregion)
        let partialCrop = CGRect(x: 150, y: 150, width: 100, height: 100)
        let compositePartial = service.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [],
            cropRect: partialCrop,
            scale: 1.0
        )
        #expect(compositePartial.width == 50)
        #expect(compositePartial.height == 50)

        // 3. High-DPI Retina scale 2.0 with BlurAnnotationCommand
        let blurCmd = BlurAnnotationCommand(rect: CGRect(x: 10, y: 10, width: 40, height: 40), pixelSize: 8.0)
        let rectCmd = RectangleAnnotationCommand(rect: CGRect(x: 60, y: 60, width: 30, height: 30), color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let compositeRetina = service.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [blurCmd, rectCmd],
            cropRect: nil,
            scale: 2.0
        )
        #expect(compositeRetina.width == 200)
        #expect(compositeRetina.height == 200)

        // 4. JPEG Quality clamping: negative quality clamped to 0.0; > 1.0 clamped to 1.0
        let dataLowQ = service.exportToJPEG(image: compositeRetina, quality: -0.5)
        #expect(dataLowQ != nil && !dataLowQ!.isEmpty)

        let dataHighQ = service.exportToJPEG(image: compositeRetina, quality: 1.8)
        #expect(dataHighQ != nil && !dataHighQ!.isEmpty)

        // PNG export
        let dataPNG = service.exportToPNG(image: compositeRetina)
        #expect(dataPNG != nil && !dataPNG!.isEmpty)
    }

    // MARK: - 3. AnnotationCommandStack Capacity & Concurrency Torture

    @Test("ADV-M7-CS-01: maxCapacity non-positive clamping, initialCommands suffix truncation & replaceTop")
    func testAnnotationCommandStackBoundaries() {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let cmd1 = PenAnnotationCommand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], color: red)
        let cmd2 = PenAnnotationCommand(points: [CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3)], color: red)
        let cmd3 = PenAnnotationCommand(points: [CGPoint(x: 4, y: 4), CGPoint(x: 5, y: 5)], color: red)

        // 1. maxCapacity <= 0 is clamped to 1
        let stackZeroCap = AnnotationCommandStack(maxCapacity: 0)
        #expect(stackZeroCap.maxCapacity == 1)

        stackZeroCap.push(cmd1)
        stackZeroCap.push(cmd2)
        #expect(stackZeroCap.count == 1)
        #expect((stackZeroCap.commands.first as? PenAnnotationCommand)?.id == cmd2.id)

        // 2. initialCommands with count > maxCapacity takes suffix
        let stackInitial = AnnotationCommandStack(maxCapacity: 2, initialCommands: [cmd1, cmd2, cmd3])
        #expect(stackInitial.count == 2)
        #expect((stackInitial.commands[0] as? PenAnnotationCommand)?.id == cmd2.id)
        #expect((stackInitial.commands[1] as? PenAnnotationCommand)?.id == cmd3.id)

        // 3. replaceTop on empty stack appends
        let emptyStack = AnnotationCommandStack(maxCapacity: 10)
        #expect(emptyStack.count == 0)
        emptyStack.replaceTop(cmd1)
        #expect(emptyStack.count == 1)
        #expect((emptyStack.commands.first as? PenAnnotationCommand)?.id == cmd1.id)

        // replaceTop on non-empty stack replaces top element
        emptyStack.replaceTop(cmd2)
        #expect(emptyStack.count == 1)
        #expect((emptyStack.commands.first as? PenAnnotationCommand)?.id == cmd2.id)

        // 4. Undo and redo on empty stack returns nil safely
        emptyStack.clear()
        #expect(emptyStack.undo() == nil)
        #expect(emptyStack.redo() == nil)
        #expect(!emptyStack.canUndo)
        #expect(!emptyStack.canRedo)
    }

    @Test("ADV-M7-CS-02: activeCrop tracking through push, undo, redo, and clear lifecycle")
    func testAnnotationCommandStackActiveCropTracking() {
        let stack = AnnotationCommandStack(maxCapacity: 10)
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let pen = PenAnnotationCommand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], color: red)
        let crop1 = CropAnnotationCommand(cropRect: CGRect(x: 0, y: 0, width: 50, height: 50), originalSize: CGSize(width: 100, height: 100))
        let crop2 = CropAnnotationCommand(cropRect: CGRect(x: 10, y: 10, width: 30, height: 30), originalSize: CGSize(width: 100, height: 100))

        #expect(stack.activeCrop == nil)

        stack.push(pen)
        #expect(stack.activeCrop == nil)

        stack.push(crop1)
        #expect(stack.activeCrop?.id == crop1.id)

        stack.push(crop2)
        #expect(stack.activeCrop?.id == crop2.id)

        // Undo crop2 -> activeCrop restores to crop1
        _ = stack.undo()
        #expect(stack.activeCrop?.id == crop1.id)

        // Undo crop1 -> activeCrop becomes nil
        _ = stack.undo()
        #expect(stack.activeCrop == nil)

        // Redo crop1 -> activeCrop restores to crop1
        _ = stack.redo()
        #expect(stack.activeCrop?.id == crop1.id)

        // Push pen clears redo stack and keeps crop1 active
        stack.push(pen)
        #expect(stack.activeCrop?.id == crop1.id)
        #expect(!stack.canRedo)

        stack.clear()
        #expect(stack.activeCrop == nil)
    }

    @Test("ADV-M7-CS-03: 80 concurrent async tasks hammering AnnotationCommandStack with NSLock verification")
    func testAnnotationCommandStackConcurrentHammer() async {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask {
                    let step = i % 5
                    switch step {
                    case 0:
                        let pen = PenAnnotationCommand(points: [CGPoint(x: CGFloat(i), y: CGFloat(i)), CGPoint(x: CGFloat(i + 1), y: CGFloat(i + 1))], color: red)
                        stack.push(pen)
                    case 1:
                        _ = stack.undo()
                    case 2:
                        _ = stack.redo()
                    case 3:
                        let crop = CropAnnotationCommand(cropRect: CGRect(x: 0, y: 0, width: CGFloat(i + 1), height: CGFloat(i + 1)), originalSize: CGSize(width: 100, height: 100))
                        stack.push(crop)
                    default:
                        if i % 10 == 0 { stack.clear() }
                    }
                    _ = stack.canUndo
                    _ = stack.canRedo
                    _ = stack.count
                    _ = stack.activeCrop
                }
            }
        }

        #expect(stack.count <= stack.maxCapacity)
    }
}
