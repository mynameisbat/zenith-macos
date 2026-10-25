import Testing
import Foundation
import CoreGraphics
import Darwin
@testable import ZenithCore

@Suite("Challenger 2 Empirical Verification: Data Boundaries, Memory Bounds & Coordinate Precision")
struct VisionChallenger2EmpiricalTests {

    private let engine = VisionEngineService()

    // MARK: - Challenge 1: Coordinate Transformations & Precision

    @Test("CH2-01A: Verify 4 corners and center coordinate mapping invariants")
    func testCoordinateInvariantsFourCornersAndCenter() {
        let W = 3840
        let H = 2160
        let boxW: CGFloat = 0.1
        let boxH: CGFloat = 0.05

        // Top-Left corner in visual space (y near 1.0 in Vision bottom-left coords)
        // Vision y = 1.0 - boxH = 0.95
        let topLeftVision = VisionBoundingBox(x: 0.0, y: 1.0 - boxH, width: boxW, height: boxH)
        let topLeftPixel = topLeftVision.toPixelRect(imageWidth: W, imageHeight: H)
        #expect(abs(topLeftPixel.origin.x - 0.0) < 0.001)
        #expect(abs(topLeftPixel.origin.y - 0.0) < 0.001)
        #expect(abs(topLeftPixel.width - (boxW * CGFloat(W))) < 0.001)
        #expect(abs(topLeftPixel.height - (boxH * CGFloat(H))) < 0.001)

        // Bottom-Left corner in visual space (y = 0.0 in Vision coords)
        let bottomLeftVision = VisionBoundingBox(x: 0.0, y: 0.0, width: boxW, height: boxH)
        let bottomLeftPixel = bottomLeftVision.toPixelRect(imageWidth: W, imageHeight: H)
        #expect(abs(bottomLeftPixel.origin.x - 0.0) < 0.001)
        // Expected pixelY = (1.0 - 0.0 - 0.05) * 2160 = 0.95 * 2160 = 2052
        let expectedBottomY = (1.0 - boxH) * CGFloat(H)
        #expect(abs(bottomLeftPixel.origin.y - expectedBottomY) < 0.001)
        #expect(abs(bottomLeftPixel.maxY - CGFloat(H)) < 0.001)

        // Top-Right corner in visual space
        let topRightVision = VisionBoundingBox(x: 1.0 - boxW, y: 1.0 - boxH, width: boxW, height: boxH)
        let topRightPixel = topRightVision.toPixelRect(imageWidth: W, imageHeight: H)
        #expect(abs(topRightPixel.maxX - CGFloat(W)) < 0.001)
        #expect(abs(topRightPixel.origin.y - 0.0) < 0.001)

        // Bottom-Right corner in visual space
        let bottomRightVision = VisionBoundingBox(x: 1.0 - boxW, y: 0.0, width: boxW, height: boxH)
        let bottomRightPixel = bottomRightVision.toPixelRect(imageWidth: W, imageHeight: H)
        #expect(abs(bottomRightPixel.maxX - CGFloat(W)) < 0.001)
        #expect(abs(bottomRightPixel.maxY - CGFloat(H)) < 0.001)

        // Center box: centered at (0.5, 0.5)
        let centerVision = VisionBoundingBox(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let centerPixel = centerVision.toPixelRect(imageWidth: W, imageHeight: H)
        #expect(abs(centerPixel.midX - CGFloat(W) / 2.0) < 0.001)
        #expect(abs(centerPixel.midY - CGFloat(H) / 2.0) < 0.001)
    }

    @Test("CH2-01B: Verify Retina scale conversions across 1x, 2x, 3x, and fractional scales")
    func testRetinaScalePrecision() {
        let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        let imageWidth = 2880
        let imageHeight = 1800

        let pixelRect = box.toPixelRect(imageWidth: imageWidth, imageHeight: imageHeight)

        // 1x scale
        let rect1x = box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 1.0)
        #expect(rect1x == pixelRect)

        // 2x Retina scale (standard macOS MacBook Pro)
        let rect2x = box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 2.0)
        #expect(abs(rect2x.origin.x - (pixelRect.origin.x / 2.0)) < 0.0001)
        #expect(abs(rect2x.origin.y - (pixelRect.origin.y / 2.0)) < 0.0001)
        #expect(abs(rect2x.width - (pixelRect.width / 2.0)) < 0.0001)
        #expect(abs(rect2x.height - (pixelRect.height / 2.0)) < 0.0001)

        // 3x scale
        let rect3x = box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 3.0)
        #expect(abs(rect3x.width - (pixelRect.width / 3.0)) < 0.0001)

        // Fractional scale (e.g., 1.5x scaled display mode)
        let rectFractional = box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 1.5)
        #expect(abs(rectFractional.width - (pixelRect.width / 1.5)) < 0.0001)

        // Degenerate scale guards: scale <= 0 returns pixelRect safely without division by zero
        #expect(box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 0.0) == pixelRect)
        #expect(box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: -2.0) == pixelRect)
    }

    @Test("CH2-01C: Verify sub-pixel precision and aspect ratios (16:9, 16:10, 21:9, 32:9)")
    func testSubpixelPrecisionAndAspectRatios() {
        let aspectRatios: [(w: Int, h: Int)] = [
            (1920, 1080),  // 16:9 Full HD
            (2560, 1600),  // 16:10 MacBook Air / Pro 13"
            (3440, 1440),  // 21:9 Ultra-Wide
            (5120, 1440),  // 32:9 Super Ultra-Wide
            (7680, 4320)   // 16:9 8K Pro Display
        ]

        for ratio in aspectRatios {
            // Micro-box: 0.001 normalized width
            let microBox = VisionBoundingBox(x: 0.5, y: 0.5, width: 0.001, height: 0.001)
            let pixelRect = microBox.toPixelRect(imageWidth: ratio.w, imageHeight: ratio.h)

            let expectedW = CGFloat(ratio.w) * 0.001
            let expectedH = CGFloat(ratio.h) * 0.001
            #expect(abs(pixelRect.width - expectedW) < 0.00001)
            #expect(abs(pixelRect.height - expectedH) < 0.00001)
            #expect(pixelRect.origin.x > 0)
            #expect(pixelRect.origin.y > 0)
        }
    }

    // MARK: - Challenge 2: Degenerate, Oversized & Boundary Inputs

    @Test("CH2-02A: Verify 0-dimension image rejection with strongly typed error")
    func testZeroDimensionsRejection() async {
        // Attempt creating a 0-width or 0-height CGImage via data provider
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let dummyData = Data(count: 16)
        guard let provider = CGDataProvider(data: dummyData as CFData) else { return }

        // CoreGraphics CGImage with width 0 or height 0
        let zeroWidthImage = CGImage(
            width: 0,
            height: 10,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )

        let zeroHeightImage = CGImage(
            width: 10,
            height: 0,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 40,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )

        // If CGImage creation succeeded for 0 dimensions, test engine rejection
        if let img = zeroWidthImage {
            do {
                _ = try await engine.recognizeText(in: img)
                Issue.record("Expected 0-width image to be rejected")
            } catch let error as VisionEngineError {
                if case .invalidImage(let reason) = error {
                    #expect(reason.contains("positive"))
                } else {
                    Issue.record("Unexpected VisionEngineError: \(error)")
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        if let img = zeroHeightImage {
            do {
                _ = try await engine.recognizeText(in: img)
                Issue.record("Expected 0-height image to be rejected")
            } catch let error as VisionEngineError {
                if case .invalidImage(let reason) = error {
                    #expect(reason.contains("positive"))
                } else {
                    Issue.record("Unexpected VisionEngineError: \(error)")
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("CH2-02B: Verify 1x1 and 2x2 micro-images return gracefully without throwing or crashing")
    func testDegenerateMicroImages1x1And2x2() async throws {
        // 1x1 image
        let img1x1 = VisionTestImageGenerator.createDegenerate1x1Image()
        let result1x1 = try await engine.recognizeText(in: img1x1)
        #expect(result1x1.lines.isEmpty)
        #expect(result1x1.fullText.isEmpty)
        #expect(result1x1.imageSize == CGSize(width: 1, height: 1))

        let barcodes1x1 = try await engine.detectBarcodes(in: img1x1)
        #expect(barcodes1x1.isEmpty)

        let analysis1x1 = try await engine.analyze(image: img1x1)
        #expect(analysis1x1.textResult.lines.isEmpty)
        #expect(analysis1x1.barcodes.isEmpty)

        // 2x2 image
        let img2x2 = VisionTestImageGenerator.createBlankImage(width: 2, height: 2)
        let result2x2 = try await engine.recognizeText(in: img2x2)
        #expect(result2x2.lines.isEmpty)
        #expect(result2x2.fullText.isEmpty)
        #expect(result2x2.imageSize == CGSize(width: 2, height: 2))

        let barcodes2x2 = try await engine.detectBarcodes(in: img2x2)
        #expect(barcodes2x2.isEmpty)

        let analysis2x2 = try await engine.analyze(image: img2x2)
        #expect(analysis2x2.textResult.lines.isEmpty)
        #expect(analysis2x2.barcodes.isEmpty)
    }

    @Test("CH2-02C: Verify 32768 exact boundary vs 32769 oversized boundary")
    func testMaxDimensionExactBoundary() async throws {
        // Exact boundary 32768 should pass dimension validation
        let imageAtMax = VisionTestImageGenerator.createOversizedImage(width: 32768, height: 2)
        #expect(imageAtMax.width == 32768)

        // Should not throw invalidImage due to dimensions (may complete or return empty)
        do {
            let res = try await engine.recognizeText(in: imageAtMax, config: VisionTextConfig(level: .fast))
            #expect(res.imageSize.width == 32768)
        } catch let error as VisionEngineError {
            // If Vision framework itself cannot handle 32768 texture, recognitionFailed is acceptable,
            // but invalidImage must NOT be thrown because 32768 <= 32768.
            if case .invalidImage = error {
                Issue.record("Image with width 32768 should NOT throw invalidImage")
            }
        }

        // Exceeding boundary 32769 MUST throw invalidImage
        let imageOverMax = VisionTestImageGenerator.createOversizedImage(width: 32769, height: 2)
        #expect(imageOverMax.width == 32769)

        do {
            _ = try await engine.recognizeText(in: imageOverMax)
            Issue.record("Expected 32769 to throw invalidImage")
        } catch let error as VisionEngineError {
            guard case .invalidImage(let reason) = error else {
                Issue.record("Expected .invalidImage, got \(error)")
                return
            }
            #expect(reason.contains("32768"))
            #expect(reason.contains("32769"))
        }
    }

    // MARK: - Challenge 3: 8K Screen Buffer & Bounded Memory Stress

    @Test("CH2-03A: Verify 8K Retina screen buffer raw footprint and bounded memory across multiple runs")
    func test8KRetinaBufferMemoryStressAcrossRuns() async throws {
        // 8K buffer: 7680 x 4320 x 4 bytes = 132,710,400 bytes
        let expectedBytes = 7680 * 4320 * 4
        #expect(expectedBytes == 132_710_400)

        let initialMem = residentMemoryBytes()

        for iteration in 1...3 {
            let image8K: CGImage = autoreleasepool {
                return VisionTestImageGenerator.create8KRetinaBufferImage(
                    withText: "ZENITH 8K STRESS ITERATION \(iteration)"
                )
            }
            #expect(image8K.width == 7680)
            #expect(image8K.height == 4320)

            let result = try await engine.recognizeText(
                in: image8K,
                config: VisionTextConfig(level: .fast)
            )

            #expect(!result.fullText.isEmpty)
            #expect(result.imageSize.width == 7680)
            #expect(result.imageSize.height == 4320)

            let currentMem = residentMemoryBytes()
            let totalDeltaMB = Double(max(0, currentMem - initialMem)) / (1024.0 * 1024.0)

            // Even after multiple 8K inferences, resident memory delta should remain strictly bounded (< 600 MB)
            #expect(totalDeltaMB < 600.0)
        }
    }
}

/// Helper reading resident memory
private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    return info.resident_size
}
