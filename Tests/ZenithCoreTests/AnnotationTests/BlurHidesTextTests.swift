import Testing
import CoreGraphics
@testable import ZenithCore

/// The Blur tool exists to hide something before a capture is shared, so the check is the one an attacker would make:
/// can text recognition still read it?
@Suite("Blur hides text from text recognition", .serialized)
struct BlurHidesTextTests {
    @Test("BLUR-OCR-01: A blurred line can no longer be read, and the line next to it still can")
    func blurredLineIsUnreadable() async throws {
        let size = CGSize(width: 800, height: 240)
        let image = VisionTestImageGenerator.createMultiLineTextImage(
            lines: ["Keep this visible", "TOKEN 48213 ALPHA"],
            fontSize: 28,
            size: size
        )
        let engine = VisionEngineService()

        let before = try await engine.recognizeText(in: image)
        let line = try #require(before.lines.first { $0.text.contains("48213") }, "the line is readable before the blur")

        // Vision's box is normalized with the origin bottom left; annotations use image points, origin top left.
        let box = line.normalizedBoundingBox
        let rect = CGRect(
            x: box.minX * size.width,
            y: (1 - box.maxY) * size.height,
            width: box.width * size.width,
            height: box.height * size.height
        ).insetBy(dx: -4, dy: -2)
        let exported = ImageExportService.shared.renderAnnotatedImage(
            baseImage: image,
            commands: [BlurAnnotationCommand(rect: rect, pixelSize: 16)],
            cropRect: nil,
            scale: 1
        )

        let after = try await engine.recognizeText(in: exported)
        #expect(!after.fullText.contains("48213"), "read after the blur: \(after.fullText)")
        #expect(!after.fullText.uppercased().contains("TOKEN"), "read after the blur: \(after.fullText)")
        #expect(after.fullText.contains("visible"), "the line that was not blurred is still readable")
    }

    @Test("TXT-OCR-01: An exported text annotation is upright, so text recognition reads it")
    func exportedTextIsUpright() async throws {
        let size = CGSize(width: 600, height: 200)
        let blank = VisionTestImageGenerator.createMultiLineTextImage(lines: [" "], fontSize: 10, size: size)
        let label = TextAnnotationCommand(
            origin: CGPoint(x: 40, y: 100), text: "Ship it Friday", fontSize: 40,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        let exported = ImageExportService.shared.renderAnnotatedImage(baseImage: blank, commands: [label], cropRect: nil, scale: 1)
        let read = try await VisionEngineService().recognizeText(in: exported)
        #expect(read.fullText.contains("Ship it Friday"), "read: \(read.fullText)")
    }
}
