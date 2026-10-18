import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Adversarial Capture Stress Challenger Suite")
struct AdversarialCaptureStressChallengerTests {

    // MARK: - 1. Concurrency Stress Test: ScreenCaptureManager & SimulatedBackend

    @Test("Adversarial Concurrency: 60 concurrent capture calls verify thread-safety & shutter fidelity")
    func testConcurrentCaptureHammer() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        let concurrentCalls = 60
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            for i in 0..<concurrentCalls {
                group.addTask {
                    if i % 2 == 0 {
                        return try await manager.captureMainDisplay()
                    } else {
                        let rect = CGRect(x: CGFloat(i * 10), y: CGFloat(i * 5), width: 100, height: 100)
                        return try await manager.captureDisplayRegion(rect, displayID: CGDirectDisplayID(i % 3))
                    }
                }
            }

            var capturedImages: [CGImage] = []
            for try await img in group {
                capturedImages.append(img)
            }
            #expect(capturedImages.count == concurrentCalls)
        }

        #expect(backend.captureDisplayCalls.count == 30)
        #expect(backend.captureRegionCalls.count == 30)
        #expect(soundService.shutterSoundCount == 60)
        #expect(soundService.playedSounds.count == 60)
    }

    @Test("Adversarial Concurrency: Interleaved capture successes, validation errors, and permission toggles")
    func testConcurrentInterleavedChaos() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let manager = ScreenCaptureManager(backend: backend, soundService: soundService)

        let taskCount = 80
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    if i % 4 == 0 {
                        // Invalid geometry (negative width)
                        let badRect = CGRect(x: 10, y: 10, width: -10, height: 50)
                        do {
                            _ = try await manager.captureDisplayRegion(badRect, displayID: 1)
                            return false
                        } catch {
                            return true
                        }
                    } else if i % 4 == 1 {
                        // Invalid geometry (NaN)
                        let badRect = CGRect(x: 10, y: 10, width: CGFloat.nan, height: 50)
                        do {
                            _ = try await manager.captureDisplayRegion(badRect, displayID: 1)
                            return false
                        } catch {
                            return true
                        }
                    } else if i % 4 == 2 {
                        // Valid region capture
                        do {
                            _ = try await manager.captureDisplayRegion(CGRect(x: 5, y: 5, width: 20, height: 20), displayID: 1)
                            return true
                        } catch {
                            return false
                        }
                    } else {
                        // Valid main capture
                        do {
                            _ = try await manager.captureMainDisplay()
                            return true
                        } catch {
                            return false
                        }
                    }
                }
            }

            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            #expect(successCount == 80)
        }

        // Shutter sound must ONLY play on valid captures (i % 4 == 2 or 3 -> 40 valid calls)
        #expect(soundService.shutterSoundCount == 40)
    }

    // MARK: - 2. Escape Cancellation State Machine Race Conditions & Rapid Keypresses

    @Test("Adversarial Escape: Rapid repeated Escape keypresses on MarqueeSelectionEngine")
    func testRapidEscapeKeypresses() {
        let engine = MarqueeSelectionEngine()

        // From idle: first escape returns true, subsequent return false
        #expect(engine.handleEscapeKey() == true)
        #expect(engine.state == .dismissed)
        #expect(engine.handleEscapeKey() == false)
        #expect(engine.handleEscapeKey() == false)
        #expect(engine.handleEscapeKey() == false)

        // Reset and begin drag
        engine.reset()
        #expect(engine.state == .idle)
        engine.beginDrag(at: CGPoint(x: 50, y: 50))
        #expect(engine.isDragging == true)
        #expect(engine.handleEscapeKey() == true)
        #expect(engine.state == .dismissed)
        #expect(engine.isDragging == false)
        #expect(engine.handleEscapeKey() == false)

        // Drag updates after escape are ignored
        engine.updateDrag(to: CGPoint(x: 150, y: 150))
        #expect(engine.state == .dismissed)
        #expect(engine.endDrag() == nil)
        #expect(engine.normalizedRect == .zero)
    }

    @Test("Adversarial Escape Race: 60 concurrent threads racing drag lifecycle vs Escape cancellation")
    func testEscapeCancellationConcurrentRace() async {
        let engine = MarqueeSelectionEngine()
        let concurrentThreads = 60

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrentThreads {
                group.addTask {
                    let point = CGPoint(x: CGFloat(i * 10), y: CGFloat(i * 10))
                    switch i % 5 {
                    case 0:
                        engine.beginDrag(at: point)
                    case 1:
                        engine.updateDrag(to: CGPoint(x: point.x + 20, y: point.y + 20))
                    case 2:
                        _ = engine.endDrag(minimumDimension: 4.0)
                    case 3:
                        _ = engine.handleEscapeKey()
                    default:
                        if i % 10 == 9 {
                            engine.reset()
                        } else {
                            _ = engine.normalizedRect
                        }
                    }
                }
            }
        }

        // Engine must remain valid without crashing or corrupting memory
        let finalState = engine.state
        switch finalState {
        case .idle, .dragging, .selected, .dismissed:
            #expect(true)
        }
    }

    // MARK: - 3. LoupePixelSampler Torture Test: 60,000+ Queries & Corrupted CGImages

    @Test("Adversarial Torture: 60,000+ queries on LoupePixelSampler across negative, extreme, NaN/Inf, and boundary points")
    func testLoupePixelSampler60kTorture() {
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 400, height: 400)

        var totalQueries = 0

        // 1. 15,000 Negative coordinate queries
        for i in 1...15_000 {
            let negX = CGFloat(-Double(i) * 1.5)
            let negY = CGFloat(-Double(i % 1000 + 1) * 2.0)
            let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: negX, y: negY))
            #expect(color == .clear)
            totalQueries += 1
        }

        // 2. 15,000 Extreme positive coordinates (beyond image bounds up to 10,000,000)
        for i in 1...15_000 {
            let posX = CGFloat(400 + i * 200)
            let posY = CGFloat(400 + (i % 500) * 1000)
            let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: posX, y: posY))
            #expect(color == .clear)
            totalQueries += 1
        }

        // 3. 10,000 NaN, +Inf, -Inf coordinates
        for i in 1...10_000 {
            let point: CGPoint
            switch i % 5 {
            case 0:
                point = CGPoint(x: CGFloat.nan, y: 100)
            case 1:
                point = CGPoint(x: 100, y: CGFloat.nan)
            case 2:
                point = CGPoint(x: CGFloat.infinity, y: 100)
            case 3:
                point = CGPoint(x: 100, y: -CGFloat.infinity)
            default:
                point = CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
            }
            let color = LoupePixelSampler.samplePixel(in: testImage, at: point)
            #expect(color == .clear)
            totalQueries += 1
        }

        // 4. 10,000 Fractional, boundary, and in-bounds coordinates
        for i in 1...10_000 {
            let x = CGFloat(i % 399) + 0.49
            let y = CGFloat((i * 7) % 399) + 0.49
            let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: x, y: y))
            #expect(color.alpha == 255)
            totalQueries += 1
        }

        // 5. 10,000 queries on pathological CGImages
        // 1x1 image
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixelData: [UInt8] = [128, 64, 32, 255]
        guard let ctx1 = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image1x1 = ctx1.makeImage() else {
            #expect(Bool(false), "Failed to create 1x1 image")
            return
        }

        for i in 0..<5_000 {
            let pt = (i % 2 == 0) ? CGPoint(x: 0, y: 0) : CGPoint(x: 2, y: 2)
            let color = LoupePixelSampler.samplePixel(in: image1x1, at: pt)
            if i % 2 == 0 {
                #expect(color == PixelColor(red: 128, green: 64, blue: 32, alpha: 255))
            } else {
                #expect(color == .clear)
            }
            totalQueries += 1
        }

        // Grayscale 8-bit image (forces fallback rendering path in LoupePixelSampler)
        var grayData: [UInt8] = [200, 100, 50, 0]
        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctxGray = CGContext(
            data: &grayData,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 2,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let grayImage = ctxGray.makeImage() else {
            #expect(Bool(false), "Failed to create grayscale image")
            return
        }

        for i in 0..<5_000 {
            let pt = CGPoint(x: i % 4, y: (i / 4) % 4)
            let color = LoupePixelSampler.samplePixel(in: grayImage, at: pt)
            if pt.x < 2 && pt.y < 2 {
                #expect(color.alpha == 255)
            } else {
                #expect(color == .clear)
            }
            totalQueries += 1
        }

        #expect(totalQueries == 60_000)
    }

    // MARK: - 4. Latency SLA Benchmark (< 1.0 ms)

    @Test("Adversarial SLA: LoupePixelSampler single sample latency is strictly < 1.0 ms (avg < 0.05 ms)")
    func testSamplingLatencySLA() {
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 800, height: 800)
        let iterations = 2_000
        var durationsNanos: [UInt64] = []
        durationsNanos.reserveCapacity(iterations)

        let overallStart = DispatchTime.now()
        for i in 0..<iterations {
            let pt = CGPoint(x: (i * 3) % 800, y: (i * 5) % 800)
            let start = DispatchTime.now()
            _ = LoupePixelSampler.samplePixel(in: testImage, at: pt)
            let end = DispatchTime.now()
            durationsNanos.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0

        let sorted = durationsNanos.sorted()
        let minMs = Double(sorted.first!) / 1_000_000.0
        let maxMs = Double(sorted.last!) / 1_000_000.0
        let avgMs = totalElapsedMs / Double(iterations)
        let p99Index = Int(Double(iterations) * 0.99)
        let p99Ms = Double(sorted[p99Index]) / 1_000_000.0

        print("[Challenger Latency SLA: Loupe Pixel Sample] Iterations=\(iterations): Min=\(String(format: "%.4f", minMs))ms, Avg=\(String(format: "%.4f", avgMs))ms, p99=\(String(format: "%.4f", p99Ms))ms, Max=\(String(format: "%.4f", maxMs))ms")

        #expect(avgMs < 0.05, "Average sampling latency must be well under 0.05ms (was \(avgMs)ms)")
        #expect(p99Ms < 1.0, "99th percentile sampling latency must be < 1.0ms (was \(p99Ms)ms)")
    }

    @Test("Adversarial SLA: CoordinateTranslationService operations latency strictly < 1.0 ms (avg < 0.01 ms)")
    func testCoordinateConversionLatencySLA() {
        let iterations = 5_000
        let screenHeight: CGFloat = 1080.0
        var durationsNanos: [UInt64] = []
        durationsNanos.reserveCapacity(iterations)

        let overallStart = DispatchTime.now()
        for i in 0..<iterations {
            let rect = CGRect(x: CGFloat(i % 500), y: CGFloat((i * 2) % 400), width: 200, height: 150)
            let start = DispatchTime.now()

            // Perform full transformation pipeline: AppKit -> CoreGraphics -> Retina Backing -> Local Display
            let cgRect = CoordinateTranslationService.flipAppKitToCoreGraphics(rect: rect, primaryScreenHeight: screenHeight)
            let retinaRect = CoordinateTranslationService.pointsToPhysicalPixels(rect: cgRect, scale: 2.0)
            let localRect = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
                rect: rect,
                displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                primaryScreenHeight: screenHeight
            )
            _ = CoordinateTranslationService.clamp(rect: localRect, to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            _ = CoordinateTranslationService.physicalPixelsToPoints(rect: retinaRect, scale: 2.0)

            let end = DispatchTime.now()
            durationsNanos.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
        }
        let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1_000_000.0

        let sorted = durationsNanos.sorted()
        let minMs = Double(sorted.first!) / 1_000_000.0
        let maxMs = Double(sorted.last!) / 1_000_000.0
        let avgMs = totalElapsedMs / Double(iterations)
        let p99Index = Int(Double(iterations) * 0.99)
        let p99Ms = Double(sorted[p99Index]) / 1_000_000.0

        print("[Challenger Latency SLA: Coordinate Translation Pipeline] Iterations=\(iterations): Min=\(String(format: "%.6f", minMs))ms, Avg=\(String(format: "%.6f", avgMs))ms, p99=\(String(format: "%.6f", p99Ms))ms, Max=\(String(format: "%.4f", maxMs))ms")

        #expect(avgMs < 0.01, "Average coordinate translation pipeline must be < 0.01ms (was \(avgMs)ms)")
        #expect(p99Ms < 1.0, "99th percentile coordinate translation must be < 1.0ms (was \(p99Ms)ms)")
    }
}
