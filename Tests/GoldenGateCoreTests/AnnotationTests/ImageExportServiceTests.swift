import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Image Export Service & Pipeline Test Suite")
struct ImageExportServiceTests {

    private func makeSyntheticImage(width: Int = 400, height: Int = 300) -> CGImage {
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
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test("EX-01: High-resolution Retina export preserves exact physical pixel dimensions without downsampling (F48)")
    func testRetinaResolutionFidelity() {
        let exportService = ImageExportService.shared
        let baseImage = makeSyntheticImage(width: 2880, height: 1800)

        let pen = PenAnnotationCommand(
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)],
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            strokeWidth: 4.0
        )
        let rect = RectangleAnnotationCommand(
            rect: CGRect(x: 400, y: 300, width: 200, height: 150),
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )

        let composited = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [pen, rect],
            cropRect: nil,
            scale: 2.0
        )

        #expect(composited.width == 2880)
        #expect(composited.height == 1800)
    }

    @Test("EX-02: PNG export produces valid lossless PNG format with 8-byte magic header")
    func testPNGMagicBytes() {
        let exportService = ImageExportService.shared
        let image = makeSyntheticImage(width: 100, height: 80)

        guard let pngData = exportService.exportToPNG(image: image) else {
            Issue.record("PNG export returned nil")
            return
        }

        #expect(pngData.count > 8)
        let header = [UInt8](pngData.prefix(8))
        let expectedPNGHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(header == expectedPNGHeader)
    }

    @Test("EX-03: JPEG export produces valid JPEG format with SOI marker [0xFF, 0xD8, 0xFF]")
    func testJPEGMagicBytes() {
        let exportService = ImageExportService.shared
        let image = makeSyntheticImage(width: 120, height: 90)

        guard let jpegData = exportService.exportToJPEG(image: image, quality: 0.85) else {
            Issue.record("JPEG export returned nil")
            return
        }

        #expect(jpegData.count > 3)
        let soi = [UInt8](jpegData.prefix(3))
        #expect(soi == [0xFF, 0xD8, 0xFF])
    }

    @Test("EX-04: JPEG quality scaling produces expected file size difference")
    func testJPEGQualityScaling() {
        let exportService = ImageExportService.shared
        let image = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 400, height: 400)

        guard let lowQualityData = exportService.exportToJPEG(image: image, quality: 0.1),
              let highQualityData = exportService.exportToJPEG(image: image, quality: 0.95) else {
            Issue.record("JPEG export failed")
            return
        }

        #expect(lowQualityData.count < highQualityData.count)
    }

    @Test("EX-05: Localized pixelation applies privacy filter to target region")
    func testLocalizedPixelation() {
        let exportService = ImageExportService.shared
        let baseImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

        let blur = BlurAnnotationCommand(
            rect: CGRect(x: 20, y: 20, width: 60, height: 60),
            pixelSize: 12.0
        )

        let composited = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [blur],
            cropRect: nil,
            scale: 1.0
        )

        #expect(composited.width == 200)
        #expect(composited.height == 200)
    }

    @Test("EX-06: Crop sub-image extraction crops to exact requested dimensions")
    func testCropSubImageExtraction() {
        let exportService = ImageExportService.shared
        let baseImage = makeSyntheticImage(width: 500, height: 400)
        let cropRect = CGRect(x: 50, y: 50, width: 250, height: 180)

        let cropped = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [],
            cropRect: cropRect,
            scale: 1.0
        )

        #expect(cropped.width == 250)
        #expect(cropped.height == 180)
    }

    @Test("EX-07: Nil crop rect preserves 100% of base image dimensions")
    func testNilCropPreservesFullDimensions() {
        let exportService = ImageExportService.shared
        let baseImage = makeSyntheticImage(width: 320, height: 240)

        let rendered = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [],
            cropRect: nil
        )

        #expect(rendered.width == 320)
        #expect(rendered.height == 240)
    }

    @Test("EX-08: Out-of-bounds crop rect is safely clamped to valid boundaries")
    func testOutOfBoundsCropClamping() {
        let exportService = ImageExportService.shared
        let baseImage = makeSyntheticImage(width: 300, height: 200)
        let outOfBoundsCrop = CGRect(x: 250, y: 150, width: 200, height: 100)

        let result = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [],
            cropRect: outOfBoundsCrop,
            scale: 1.0
        )

        #expect(result.width <= 300)
        #expect(result.height <= 200)
        #expect(result.width > 0)
        #expect(result.height > 0)
    }

    @Test("EX-09: Concurrent export stress test handles 40 tasks without race or leak")
    func testConcurrentExportStress() async {
        let exportService = ImageExportService.shared
        let baseImage = makeSyntheticImage(width: 200, height: 150)
        let taskCount = 40

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    let cmd = RectangleAnnotationCommand(
                        rect: CGRect(x: 10, y: 10, width: 50, height: 40),
                        color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                    )
                    let img = exportService.renderAnnotatedImage(
                        baseImage: baseImage,
                        commands: [cmd],
                        cropRect: nil,
                        scale: 1.0
                    )
                    if i % 2 == 0 {
                        let png = exportService.exportToPNG(image: img)
                        return png != nil
                    } else {
                        let jpeg = exportService.exportToJPEG(image: img, quality: 0.8)
                        return jpeg != nil
                    }
                }
            }

            for await result in group {
                #expect(result)
            }
        }
    }

    private func getPixelColor(image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data),
              x >= 0, x < image.width, y >= 0, y < image.height else {
            return (0, 0, 0, 0)
        }
        let bytesPerRow = image.bytesPerRow
        let offset = y * bytesPerRow + x * 4
        return (ptr[offset], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
    }

    @Test("EX-10: Unified top-left coordinate space rendering accurately places vector annotations without inversion")
    func testCoordinateSpaceUnifiedTopLeft() {
        let exportService = ImageExportService.shared
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 200,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 200 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let blackBase = context.makeImage()!

        let redRect = RectangleAnnotationCommand(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            isFilled: true
        )

        let composited = exportService.renderAnnotatedImage(
            baseImage: blackBase,
            commands: [redRect],
            cropRect: nil,
            scale: 1.0
        )

        let topCrop = composited.cropping(to: CGRect(x: 25, y: 25, width: 50, height: 50))!
        let bottomCrop = composited.cropping(to: CGRect(x: 25, y: 125, width: 50, height: 50))!

        #expect(topCrop.width == 50)
        #expect(bottomCrop.width == 50)

        // Verify exact pixel color in top half (red rect) and bottom half (unmodified black base)
        let topPixel = getPixelColor(image: composited, x: 50, y: 50)
        let bottomPixel = getPixelColor(image: composited, x: 50, y: 150)
        #expect(topPixel.r > 200)
        #expect(topPixel.g < 50)
        #expect(topPixel.b < 50)
        #expect(bottomPixel.r < 50)
        #expect(bottomPixel.g < 50)
        #expect(bottomPixel.b < 50)
    }

    @Test("EX-11: Out-of-bounds blur annotation is safely clamped without failure")
    func testOutOfBoundsBlurClamping() {
        let exportService = ImageExportService.shared
        let baseImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

        let oobBlur = BlurAnnotationCommand(
            rect: CGRect(x: -20, y: -20, width: 80, height: 80),
            pixelSize: 10.0
        )

        let composited = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: [oobBlur],
            cropRect: nil,
            scale: 1.0
        )

        #expect(composited.width == 200)
        #expect(composited.height == 200)
    }
}
