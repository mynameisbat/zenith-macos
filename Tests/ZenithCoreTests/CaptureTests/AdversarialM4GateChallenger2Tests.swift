import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ZenithCore

@Suite("Adversarial M4 Gate Challenger 2 Empirical Stress Suite")
struct AdversarialM4GateChallenger2Tests {

    let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Helper: Create synthetic CGImage with specific width, height, bytesPerRow, and bitmapInfo
    func createSyntheticImage(
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        bitmapInfo: UInt32,
        pixelBuffer: [UInt8]
    ) -> CGImage? {
        var mutableBytes = pixelBuffer
        let stride = bytesPerRow ?? (width * 4)
        guard let ctx = CGContext(
            data: &mutableBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: sRGBSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - 1. Pixel Byte-Order Resilience: All Supported Pixel Formats

    @Test("CH2-BO-01: Little-Endian 32-bit BGRA opaque and translucent sampling with un-premultiplication")
    func testLittleEndianBGRAUnpremultiplication() {
        // Native macOS ScreenCaptureKit: Little-Endian 32-bit BGRA
        // Memory order: [B, G, R, A]
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // 2x2 image:
        // Top row (memoryY = 0):
        //   px 0: 50% opacity Red -> A=128, R_prem=128, G=0, B=0 -> [0, 0, 128, 128]
        //   px 1: 25% opacity Green -> A=64, R=0, G_prem=64, B=0 -> [0, 64, 0, 64]
        // Bottom row (memoryY = 1):
        //   px 0: 75% opacity Blue -> A=191, R=0, G=0, B_prem=191 -> [191, 0, 0, 191]
        //   px 1: Opaque Yellow -> A=255, R=255, G=255, B=0 -> [0, 255, 255, 255]
        let pixels: [UInt8] = [
            0,   0,   128, 128,    0,   64,  0,   64,
            191, 0,   0,   191,    0,   255, 255, 255
        ]

        guard let image = createSyntheticImage(width: 2, height: 2, bitmapInfo: bitmapInfo, pixelBuffer: pixels) else {
            Issue.record("Failed to create BGRA CGImage")
            return
        }

        // AppKit py = 1 -> memoryY = 2 - 1 - 1 = 0 (Top row)
        // px = 0: 50% opacity Red
        let redSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(redSample.alpha == 128)
        #expect(redSample.red >= 254 && redSample.red <= 255)
        #expect(redSample.green == 0)
        #expect(redSample.blue == 0)

        // px = 1: 25% opacity Green
        let greenSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1))
        #expect(greenSample.alpha == 64)
        #expect(greenSample.red == 0)
        #expect(greenSample.green >= 254 && greenSample.green <= 255)
        #expect(greenSample.blue == 0)

        // AppKit py = 0 -> memoryY = 2 - 1 - 0 = 1 (Bottom row)
        // px = 0: 75% opacity Blue
        let blueSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(blueSample.alpha == 191)
        #expect(blueSample.red == 0)
        #expect(blueSample.green == 0)
        #expect(blueSample.blue >= 254 && blueSample.blue <= 255)

        // px = 1: Opaque Yellow
        let yellowSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(yellowSample.alpha == 255)
        #expect(yellowSample.red == 255)
        #expect(yellowSample.green == 255)
        #expect(yellowSample.blue == 0)
        #expect(yellowSample.hexString == "#FFFF00")
    }

    @Test("CH2-BO-02: Little-Endian 32-bit BGRx format forces opaque alpha 255 regardless of dummy byte")
    func testLittleEndianBGRxOpaqueEnforcement() {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

        // Dummy byte at index 3 is set to 0, 42, 100, etc.
        // Memory order: [B, G, R, X]
        let pixels: [UInt8] = [
            0,   0,   255, 0,      0,   255, 0,   42,    // memoryY = 0: Red, Green
            255, 0,   0,   100,    0,   0,   0,   200    // memoryY = 1: Blue, Black
        ]

        guard let image = createSyntheticImage(width: 2, height: 2, bitmapInfo: bitmapInfo, pixelBuffer: pixels) else {
            Issue.record("Failed to create BGRx CGImage")
            return
        }

        // py = 1 (Top row): px 0 = Red
        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(red == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))

        // py = 1 (Top row): px 1 = Green
        let green = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1))
        #expect(green == PixelColor(red: 0, green: 255, blue: 0, alpha: 255))

        // py = 0 (Bottom row): px 0 = Blue
        let blue = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(blue == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test("CH2-BO-03: Big-Endian 32-bit ARGB format parses [A, R, G, B] and un-premultiplies correctly")
    func testBigEndianARGBUnpremultiplication() {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // Memory order: [A, R, G, B]
        // memoryY = 0: 50% opacity pure green -> [128, 0, 128, 0], pure blue opaque -> [255, 0, 0, 255]
        let pixels: [UInt8] = [
            128, 0,   128, 0,      255, 0,   0,   255,
            255, 255, 0,   0,      255, 255, 255, 255
        ]

        guard let image = createSyntheticImage(width: 2, height: 2, bitmapInfo: bitmapInfo, pixelBuffer: pixels) else {
            Issue.record("Failed to create ARGB CGImage")
            return
        }

        // py = 1 -> memoryY = 0
        let green = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(green.alpha == 128)
        #expect(green.red == 0)
        #expect(green.green >= 254 && green.green <= 255)
        #expect(green.blue == 0)

        let blue = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1))
        #expect(blue == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test("CH2-BO-04: Big-Endian 32-bit RGBA format parses [R, G, B, A] and un-premultiplies correctly")
    func testBigEndianRGBAUnpremultiplication() {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        // Memory order: [R, G, B, A]
        // memoryY = 0: 50% opacity pure red -> [128, 0, 0, 128], 100% white -> [255, 255, 255, 255]
        let pixels: [UInt8] = [
            128, 0,   0,   128,    255, 255, 255, 255,
            0,   128, 0,   128,    0,   0,   128, 128
        ]

        guard let image = createSyntheticImage(width: 2, height: 2, bitmapInfo: bitmapInfo, pixelBuffer: pixels) else {
            Issue.record("Failed to create RGBA CGImage")
            return
        }

        let red = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1))
        #expect(red.alpha == 128)
        #expect(red.red >= 254 && red.red <= 255)
        #expect(red.green == 0)
        #expect(red.blue == 0)

        let white = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1))
        #expect(white == PixelColor(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test("CH2-BO-05: Pathological alpha values: pure zero alpha, 1/255 alpha, and 254/255 alpha")
    func testPathologicalAlphaBoundaryValues() {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // [B, G, R, A]
        // px 0: Alpha = 0, R=0, G=0, B=0 -> [0, 0, 0, 0] (no div-by-zero)
        // px 1: Alpha = 1, R_prem = 1 -> [0, 0, 1, 1] -> (1 * 255 + 0) / 1 = 255
        // px 2: Alpha = 254, R_prem = 254 -> [0, 0, 254, 254] -> (254 * 255 + 127) / 254 = 255
        let pixels: [UInt8] = [
            0, 0, 0,   0,     0, 0, 1,   1,     0, 0, 254, 254
        ]

        guard let image = createSyntheticImage(width: 3, height: 1, bitmapInfo: bitmapInfo, pixelBuffer: pixels) else {
            Issue.record("Failed to create pathological alpha CGImage")
            return
        }

        // px 0: Clear
        let clearSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0))
        #expect(clearSample.alpha == 0)
        #expect(clearSample.red == 0)
        #expect(clearSample.green == 0)
        #expect(clearSample.blue == 0)

        // px 1: Alpha = 1
        let minAlphaSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0))
        #expect(minAlphaSample.alpha == 1)
        #expect(minAlphaSample.red == 255)

        // px 2: Alpha = 254
        let maxAlphaSample = LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 2, y: 0))
        #expect(maxAlphaSample.alpha == 254)
        #expect(maxAlphaSample.red == 255)
    }

    // MARK: - 2. Memory Safety & Non-Standard Row Strides

    @Test("CH2-MEM-01: Non-standard bytesPerRow padding stride is strictly respected without row bleeding")
    func testNonStandardRowStrideHandling() {
        // 3x2 image: width = 3 (12 bytes of pixel data), but bytesPerRow = 32 (20 bytes of padding per row)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var buffer = [UInt8](repeating: 0xEE, count: 64) // Fill with sentinel 0xEE

        // Row 0 (memoryY = 0):
        //   px 0: Red [0, 0, 255, 255]
        //   px 1: Green [0, 255, 0, 255]
        //   px 2: Blue [255, 0, 0, 255]
        //   bytes 12..31: padding sentinel
        buffer[0] = 0; buffer[1] = 0; buffer[2] = 255; buffer[3] = 255
        buffer[4] = 0; buffer[5] = 255; buffer[6] = 0; buffer[7] = 255
        buffer[8] = 255; buffer[9] = 0; buffer[10] = 0; buffer[11] = 255

        // Row 1 (memoryY = 1, starts at offset 32):
        //   px 0: White [255, 255, 255, 255]
        //   px 1: Black [0, 0, 0, 255]
        //   px 2: Yellow [0, 255, 255, 255]
        let r1 = 32
        buffer[r1 + 0] = 255; buffer[r1 + 1] = 255; buffer[r1 + 2] = 255; buffer[r1 + 3] = 255
        buffer[r1 + 4] = 0;   buffer[r1 + 5] = 0;   buffer[r1 + 6] = 0;   buffer[r1 + 7] = 255
        buffer[r1 + 8] = 0;   buffer[r1 + 9] = 255; buffer[r1 + 10] = 255; buffer[r1 + 11] = 255

        guard let image = createSyntheticImage(width: 3, height: 2, bytesPerRow: 32, bitmapInfo: bitmapInfo, pixelBuffer: buffer) else {
            Issue.record("Failed to create padded CGImage")
            return
        }

        // AppKit py = 1 -> memoryY = 0
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 1)) == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 1)) == PixelColor(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 2, y: 1)) == PixelColor(red: 0, green: 0, blue: 255, alpha: 255))

        // AppKit py = 0 -> memoryY = 1
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0)) == PixelColor(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 1, y: 0)) == PixelColor(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 2, y: 0)) == PixelColor(red: 255, green: 255, blue: 0, alpha: 255))
    }

    @Test("CH2-MEM-02: Boundary precision: exact corner pixels and sub-pixel rounding boundaries")
    func testBoundaryPrecisionAndSubPixelRounding() {
        let image = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 100, height: 100)

        // Exact corners in 100x100:
        // (0, 99) = Top-Left (Red)
        // (99, 99) = Top-Right (Green)
        // (0, 0) = Bottom-Left (Blue)
        // (99, 0) = Bottom-Right (Yellow)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 99)).hexString == "#FF0000")
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 99, y: 99)).hexString == "#00FF00")
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 0)).hexString == "#0000FF")
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 99, y: 0)).hexString == "#FFFF00")

        // 1 pixel out of bounds -> .clear
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: -1, y: 0)) == .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: -1)) == .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 100, y: 0)) == .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 0, y: 100)) == .clear)

        // Sub-pixel rounding tests:
        // 99.4 rounds to 99 (valid)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 99.4, y: 99.4)).hexString == "#00FF00")
        // 99.5 rounds to 100 (out of bounds -> .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 99.5, y: 99.4)) == .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: 99.4, y: 99.5)) == .clear)
        // -0.4 rounds to 0 (valid)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: -0.4, y: 0.0)).hexString == "#0000FF")
        // -0.5 rounds to -1 (out of bounds -> .clear)
        #expect(LoupePixelSampler.samplePixel(in: image, at: CGPoint(x: -0.5, y: 0.0)) == .clear)
    }

    // MARK: - 3. Performance SLA: Sampling Latency < 0.05 ms under Query Bursts

    @Test("CH2-SLA-01: 10,000 query burst achieves average latency strictly < 0.05 ms and p99 < 0.05 ms")
    func testHighFrequencyQueryBurstSamplingSLA() {
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 1920, height: 1080)
        let queryCount = 10_000
        var durationsNanos: [UInt64] = []
        durationsNanos.reserveCapacity(queryCount)

        // Warm up cache
        _ = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 100, y: 100))

        let burstStart = DispatchTime.now()
        for i in 0..<queryCount {
            let px = CGFloat((i * 17) % 1920)
            let py = CGFloat((i * 31) % 1080)
            let qStart = DispatchTime.now()
            let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: px, y: py))
            let qEnd = DispatchTime.now()
            durationsNanos.append(qEnd.uptimeNanoseconds - qStart.uptimeNanoseconds)
            #expect(color.alpha == 255)
        }
        let totalBurstMs = Double(DispatchTime.now().uptimeNanoseconds - burstStart.uptimeNanoseconds) / 1_000_000.0

        durationsNanos.sort()
        let avgMs = totalBurstMs / Double(queryCount)
        let minMs = Double(durationsNanos.first!) / 1_000_000.0
        let p50Ms = Double(durationsNanos[Int(Double(queryCount) * 0.50)]) / 1_000_000.0
        let p95Ms = Double(durationsNanos[Int(Double(queryCount) * 0.95)]) / 1_000_000.0
        let p99Ms = Double(durationsNanos[Int(Double(queryCount) * 0.99)]) / 1_000_000.0
        let maxMs = Double(durationsNanos.last!) / 1_000_000.0

        print("[Challenger SLA Verification: 10,000 Sample Burst] Total=\(String(format: "%.2f", totalBurstMs))ms, Min=\(String(format: "%.6f", minMs))ms, p50=\(String(format: "%.6f", p50Ms))ms, Avg=\(String(format: "%.6f", avgMs))ms, p95=\(String(format: "%.6f", p95Ms))ms, p99=\(String(format: "%.6f", p99Ms))ms, Max=\(String(format: "%.4f", maxMs))ms")

        #expect(avgMs < 0.05, "Average sampling latency must be strictly < 0.05 ms (was \(avgMs) ms)")
        #expect(p99Ms < 0.05, "99th percentile sampling latency must be strictly < 0.05 ms (was \(p99Ms) ms)")
    }

    @Test("CH2-SLA-02: 500 consecutive 21x21 grid sampling queries achieve average latency < 0.5 ms per full grid")
    func testGridSamplingThroughputSLA() {
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 1920, height: 1080)
        let gridQueries = 500
        var durationsNanos: [UInt64] = []
        durationsNanos.reserveCapacity(gridQueries)

        let overallStart = DispatchTime.now()
        for i in 0..<gridQueries {
            let center = CGPoint(x: CGFloat((i * 13) % 1900 + 10), y: CGFloat((i * 29) % 1060 + 10))
            let start = DispatchTime.now()
            let grid = LoupePixelSampler.sampleGrid(in: testImage, center: center, zoomFactor: .zoom4x)
            let end = DispatchTime.now()
            durationsNanos.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
            #expect(grid.count == 21)
            #expect(grid[10][10] == LoupePixelSampler.samplePixel(in: testImage, at: center))
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0

        durationsNanos.sort()
        let avgGridMs = totalElapsedMs / Double(gridQueries)
        let p99GridMs = Double(durationsNanos[Int(Double(gridQueries) * 0.99)]) / 1_000_000.0
        let perPixelAvgMs = avgGridMs / 441.0

        print("[Challenger Grid SLA Verification: 500 21x21 Grids] AvgGrid=\(String(format: "%.4f", avgGridMs))ms, p99Grid=\(String(format: "%.4f", p99GridMs))ms, PerPixelAvg=\(String(format: "%.6f", perPixelAvgMs))ms")

        #expect(avgGridMs < 0.5, "21x21 grid sampling average latency must be < 0.5 ms (was \(avgGridMs) ms)")
        #expect(perPixelAvgMs < 0.005, "Per-pixel sampling within grid must be < 0.005 ms (was \(perPixelAvgMs) ms)")
    }

    // MARK: - 4. Concurrency Stress Test under High Task Contention

    @Test("CH2-CONC-01: 100 concurrent async tasks hammering LoupePixelSampler without data race or crash")
    func testMultiThreadedConcurrentSamplingStress() async {
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 800, height: 800)
        let concurrentTasks = 100
        let queriesPerTask = 200

        await withTaskGroup(of: Int.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    var validCount = 0
                    for q in 0..<queriesPerTask {
                        let px = CGFloat((taskId * 37 + q * 19) % 800)
                        let py = CGFloat((taskId * 41 + q * 23) % 800)
                        let pt = CGPoint(x: px, y: py)

                        let sample = LoupePixelSampler.samplePixel(in: testImage, at: pt)
                        if sample != .clear {
                            validCount += 1
                        }

                        if q % 20 == 0 {
                            let grid = LoupePixelSampler.sampleGrid(in: testImage, center: pt, zoomFactor: .zoom8x)
                            if grid.count == 15 && grid[7][7] == sample {
                                validCount += 1
                            }
                        }
                    }
                    return validCount
                }
            }

            var totalValid = 0
            for await count in group {
                totalValid += count
            }
            #expect(totalValid > 0)
        }
    }

    @Test("CH2-CONC-02: 80 concurrent async tasks hammering coordinate operations and clamping invariants")
    func testMultiThreadedCoordinateOperationsStress() async {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let container = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let concurrentTasks = 80

        await withTaskGroup(of: Bool.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    var allPass = true
                    for step in 0..<500 {
                        let cursor = CGPoint(x: CGFloat(taskId * 10 + step - 1000), y: CGFloat(step * 2))
                        let physical = CoordinateTranslationService.cursorToPhysicalPixels(
                            cursor: cursor,
                            screenFrame: screen,
                            scale: 2.0
                        )

                        let expectedX = (cursor.x - screen.minX) * 2.0
                        let expectedY = (cursor.y - screen.minY) * 2.0
                        if physical.x != expectedX || physical.y != expectedY {
                            allPass = false
                        }

                        let rect = CGRect(x: physical.x, y: physical.y, width: 200, height: 150)
                        let clamped = CoordinateTranslationService.clamp(rect: rect, to: container)
                        if clamped.minX < container.minX || clamped.maxX > container.maxX + 0.0001 ||
                           clamped.minY < container.minY || clamped.maxY > container.maxY + 0.0001 {
                            allPass = false
                        }
                    }
                    return allPass
                }
            }

            var totalPass = 0
            for await pass in group {
                if pass { totalPass += 1 }
            }
            #expect(totalPass == concurrentTasks)
        }
    }
}
