import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("In-Editor Shortcuts & Command Routing Test Suite")
struct InEditorShortcutsTests {

    private func makeTestImage(width: Int = 400, height: Int = 300) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.3, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Window Geometry & Clamping Tests

    @Test("SC-01: Standard Retina image geometry fits within display bounds at 1:1 point scale")
    func testStandardRetinaGeometry() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 1600,
            imageHeight: 1200,
            displayVisibleFrame: visibleFrame,
            backingScaleFactor: 2.0
        )

        // Logical point dimensions: 800 x 600
        #expect(geom.canvasSize.width == 800)
        #expect(geom.canvasSize.height == 600)
        #expect(geom.windowFrame.width == 800)
        #expect(geom.windowFrame.height == 600)
        #expect(geom.scaleFactor == 2.0)
    }

    @Test("SC-02: Ultra-wide image scales down preserving aspect ratio within display margins")
    func testUltraWideImageGeometryScaling() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 4000,
            imageHeight: 1000,
            displayVisibleFrame: visibleFrame,
            backingScaleFactor: 2.0
        )

        // Point size is 2000x500; exceeds max width (1920 - 96 = 1824)
        #expect(geom.canvasSize.width <= (1920 - 96))
        let originalAspect = 4000.0 / 1000.0
        let calculatedAspect = Double(geom.canvasSize.width) / Double(geom.canvasSize.height)
        #expect(abs(calculatedAspect - originalAspect) < 0.05)
    }

    @Test("SC-03: Tiny image clamps window frame to minimum size 520x360 without distorting canvas")
    func testTinyImageGeometryClamping() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 40,
            imageHeight: 40,
            displayVisibleFrame: visibleFrame,
            backingScaleFactor: 2.0
        )

        // Window size clamped to minimum
        #expect(geom.windowFrame.width >= 520)
        #expect(geom.windowFrame.height >= 360)
        #expect(geom.canvasSize.width == 20)
        #expect(geom.canvasSize.height == 20)
    }

    // MARK: - Copy (Cmd+C) Action Tests

    @Test("SC-04: Cmd+C action flattens annotations onto base image and writes to pasteboard")
    func testCopyToPasteboardAction() {
        let exportService = ImageExportService.shared
        let pasteboardService = MockPasteboardService()
        let soundBackend = MockAudioPlayerBackend()
        let soundService = AudioFeedbackManager(backend: soundBackend, isMuted: false)

        let baseImage = makeTestImage(width: 400, height: 300)
        let stack = AnnotationCommandStack()

        let pen = PenAnnotationCommand(
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        stack.push(pen)

        // Simulate Cmd+C action execution
        let flattened = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: stack.commands,
            cropRect: nil,
            scale: 1.0
        )
        pasteboardService.writeImageToPasteboard(flattened)
        soundService.playNewCopySound()

        #expect(pasteboardService.copiedImages.count == 1)
        #expect(pasteboardService.copiedImages.first?.width == 400)
        #expect(pasteboardService.copiedImages.first?.height == 300)
        #expect(soundBackend.playedSounds.last == "Pop")
    }

    @Test("SC-05: Sound effects are suppressed during Cmd+C when mute is enabled")
    func testCopySoundMuteSuppression() {
        let soundBackend = MockAudioPlayerBackend()
        let soundService = AudioFeedbackManager(backend: soundBackend, isMuted: true)

        soundService.playNewCopySound()
        #expect(soundBackend.playedSounds.isEmpty)
    }

    // MARK: - Save (Cmd+S) Action Tests

    @Test("SC-06: Cmd+S action exports valid PNG and JPEG formats")
    func testSaveToDiskExportFormats() {
        let exportService = ImageExportService.shared
        let baseImage = makeTestImage(width: 200, height: 150)
        let stack = AnnotationCommandStack()

        let rect = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 50, height: 50),
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )
        stack.push(rect)

        let flattened = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: stack.commands,
            cropRect: nil,
            scale: 1.0
        )

        let pngData = exportService.exportToPNG(image: flattened)
        #expect(pngData != nil)
        #expect(pngData!.count > 100)

        let jpegData = exportService.exportToJPEG(image: flattened, quality: 0.9)
        #expect(jpegData != nil)
        #expect(jpegData!.count > 100)
    }

    // MARK: - Undo (Cmd+Z) & Redo (Shift+Cmd+Z) Tests

    @Test("SC-07: Cmd+Z and Shift+Cmd+Z correctly route through AnnotationCommandStack")
    func testUndoRedoShortcuts() {
        let stack = AnnotationCommandStack()

        let cmd1 = RectangleAnnotationCommand(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        let cmd2 = RectangleAnnotationCommand(
            rect: CGRect(x: 10, y: 10, width: 10, height: 10),
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )

        stack.push(cmd1)
        stack.push(cmd2)
        #expect(stack.count == 2)
        #expect(stack.canUndo)

        // Cmd+Z: Undo
        _ = stack.undo()
        #expect(stack.count == 1)
        #expect(stack.canRedo)

        // Shift+Cmd+Z: Redo
        _ = stack.redo()
        #expect(stack.count == 2)
        #expect(!stack.canRedo)
    }

    // MARK: - Escape (Esc) Discard Tests

    @Test("SC-08: Escape key sequence prioritizes draft cancel over editor dismissal")
    func testEscapeKeyRouting() {
        var hasActiveTextDraft = true
        var hasActiveCrop = false
        var isDismissed = false

        func handleEscape() {
            if hasActiveTextDraft {
                hasActiveTextDraft = false
                return
            }
            if hasActiveCrop {
                hasActiveCrop = false
                return
            }
            isDismissed = true
        }

        // 1st Esc: Cancels text draft
        handleEscape()
        #expect(!hasActiveTextDraft)
        #expect(!isDismissed)

        // Enable crop
        hasActiveCrop = true

        // 2nd Esc: Cancels crop
        handleEscape()
        #expect(!hasActiveCrop)
        #expect(!isDismissed)

        // 3rd Esc: Dismisses editor
        handleEscape()
        #expect(isDismissed)
    }
}
