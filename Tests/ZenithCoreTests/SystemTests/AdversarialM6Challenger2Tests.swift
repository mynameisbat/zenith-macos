import Testing
import Foundation
import CoreGraphics
import Darwin
@testable import ZenithCore

@Suite("Adversarial M6 Challenger 2 System Concurrency & Performance Suite")
struct AdversarialM6Challenger2Tests {

    // MARK: - Helpers

    /// Creates a synthetic 32-bit Little-Endian BGRA image matching native macOS Retina captures.
    private func makeRetinaCaptureImage(width: Int = 2880, height: Int = 1800) -> CGImage {
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        var buffer = [UInt8](repeating: 0, count: totalBytes)

        // Populate with deterministic gradient patterns across quadrants
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let pixelOffset = rowOffset + x * 4
                // BGRA layout: b, g, r, a
                buffer[pixelOffset + 0] = UInt8((x * 255) / max(1, width))          // Blue
                buffer[pixelOffset + 1] = UInt8((y * 255) / max(1, height))         // Green
                buffer[pixelOffset + 2] = UInt8(((x + y) * 255) / max(1, width + height)) // Red
                buffer[pixelOffset + 3] = 255                                       // Alpha
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let image = ctx.makeImage() else {
            fatalError("Failed to create synthetic Retina test image")
        }
        return image
    }

    // MARK: - 1. SimulatedLaunchAtLoginService Concurrency Torture & State Consistency

    @Test("CH2-M6-LAL-01: SimulatedLaunchAtLoginService 150-task concurrent torture with state consistency verification")
    func testSimulatedLaunchAtLogin150TaskTorture() async {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)
        let taskCount = 150
        let iterationsPerTask = 20

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    for iter in 0..<iterationsPerTask {
                        let op = (taskId + iter) % 4
                        switch op {
                        case 0:
                            try? service.enable()
                        case 1:
                            try? service.disable()
                        case 2:
                            let st = service.status
                            #expect([LaunchAtLoginStatus.enabled, .notRegistered].contains(st))
                        default:
                            let isEn = service.isEnabled
                            _ = isEn
                        }
                    }
                }
            }
        }

        // Post-concurrency final invariant verification: when quiescent, isEnabled strictly mirrors status == .enabled
        let finalIsEnabled = service.isEnabled
        let finalStatus = service.status
        #expect(finalIsEnabled == (finalStatus == .enabled))
        #expect([LaunchAtLoginStatus.enabled, .notRegistered].contains(finalStatus))
        #expect(service.enableCallCount + service.disableCallCount > 0)
    }

    @Test("CH2-M6-LAL-02: SimulatedLaunchAtLoginService concurrent race condition & idempotency attack")
    func testSimulatedLaunchAtLoginConcurrentIdempotency() async {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)
        let concurrency = 100

        // Attack Phase 1: 100 concurrent tasks calling enable() simultaneously
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    try? service.enable()
                }
            }
        }

        #expect(service.isEnabled == true)
        #expect(service.status == .enabled)
        #expect(service.enableCallCount == concurrency)
        #expect(service.disableCallCount == 0)

        // Attack Phase 2: 100 concurrent tasks calling disable() simultaneously
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    try? service.disable()
                }
            }
        }

        #expect(service.isEnabled == false)
        #expect(service.status == .notRegistered)
        #expect(service.enableCallCount == concurrency)
        #expect(service.disableCallCount == concurrency)

        // Reset counts under concurrency
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    service.resetCallCounts()
                }
            }
        }

        #expect(service.enableCallCount == 0)
        #expect(service.disableCallCount == 0)
    }

    @Test("CH2-M6-LAL-03: SimulatedLaunchAtLoginService concurrent error injection resilience")
    func testSimulatedLaunchAtLoginErrorInjectionStress() async {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)
        let taskCount = 120
        let iterations = 25

        await withTaskGroup(of: Void.self) { group in
            // Worker tasks
            for taskId in 0..<taskCount {
                group.addTask {
                    for iter in 0..<iterations {
                        do {
                            if (taskId + iter) % 2 == 0 {
                                try service.enable()
                            } else {
                                try service.disable()
                            }
                        } catch let error as LaunchAtLoginError {
                            // Valid typed error caught
                            #expect(error.errorDescription != nil)
                        } catch {
                            Issue.record("Unexpected untyped error thrown: \(error)")
                        }
                        // Lock release check: query must not deadlock
                        _ = service.isEnabled
                        _ = service.status
                    }
                }
            }

            // Chaos injection tasks toggling error flags
            group.addTask {
                for _ in 0..<iterations {
                    service.shouldThrow = true
                    service.shouldThrowOnEnable = LaunchAtLoginError.requiresApproval
                    service.shouldThrowOnDisable = LaunchAtLoginError.notFound
                    service.shouldThrow = false
                    service.shouldThrowOnEnable = nil
                    service.shouldThrowOnDisable = nil
                }
            }
        }

        // Service must still be operational and responsive
        service.shouldThrow = false
        service.shouldThrowOnEnable = nil
        service.shouldThrowOnDisable = nil
        try? service.enable()
        #expect(service.isEnabled == true)
        #expect(service.status == .enabled)
    }

    @Test("CH2-M6-LAL-04: SimulatedLaunchAtLoginService combined with SettingsStore thread-safe synchronization")
    func testLaunchAtLoginWithSettingsStoreConcurrency() async {
        let suiteName = "CH2_LAL_Settings_\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite")
            return
        }
        let store = SettingsStore(userDefaults: defaults)
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)
        let taskCount = 80
        let iterations = 30

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    for iter in 0..<iterations {
                        let enableState = (taskId + iter) % 2 == 0
                        store.launchAtLoginEnabled = enableState
                        if enableState {
                            try? service.enable()
                        } else {
                            try? service.disable()
                        }
                        _ = store.launchAtLoginEnabled
                        _ = service.isEnabled
                    }
                }
            }
        }

        // Post-concurrency explicit synchronization verification
        store.launchAtLoginEnabled = true
        try? service.enable()
        #expect(store.launchAtLoginEnabled == true)
        #expect(store.launchAtLogin == true)
        #expect(service.isEnabled == true)
        #expect(service.status == .enabled)

        store.launchAtLoginEnabled = false
        try? service.disable()
        #expect(store.launchAtLoginEnabled == false)
        #expect(store.launchAtLogin == false)
        #expect(service.isEnabled == false)
        #expect(service.status == .notRegistered)

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 2. LoupePixelSampler.sampleGrid Hoisted Pointer Optimization & Latency SLA (< 0.5ms)

    @Test("CH2-M6-LOUPE-01: LoupePixelSampler.sampleGrid hoisted pointer parallel stress & latency SLA (< 0.5ms)")
    func testLoupePixelSamplerParallelLoadLatencySLA() async {
        let retinaImage = makeRetinaCaptureImage(width: 2880, height: 1800)
        let concurrentTasks = 50
        let queriesPerTask = 100
        let totalQueries = concurrentTasks * queriesPerTask

        // Coordinate pool covering diverse sample regions: center, edges, corners, subpixel, out of bounds
        let coordinatePool: [CGPoint] = [
            CGPoint(x: 1440, y: 900),       // Screen center
            CGPoint(x: 100, y: 100),         // Bottom-left quadrant
            CGPoint(x: 2700, y: 1700),       // Top-right quadrant
            CGPoint(x: 0, y: 0),             // Origin
            CGPoint(x: 2879, y: 1799),       // Max boundary pixel
            CGPoint(x: 1440.4, y: 900.6),   // Fractional / subpixel coordinate
            CGPoint(x: 5, y: 5),             // Near corner
            CGPoint(x: 2875, y: 5),          // Near bottom-right edge
            CGPoint(x: -10, y: -10),         // Out-of-bounds negative
            CGPoint(x: 3000, y: 2000),       // Out-of-bounds positive
            CGPoint(x: 1440, y: 0),          // Bottom edge
            CGPoint(x: 0, y: 900)            // Left edge
        ]

        // Thread-safe latency accumulator
        final class LatencyCollector: @unchecked Sendable {
            private let lock = NSLock()
            var durationsNanos: [UInt64] = []

            func record(nanos: [UInt64]) {
                lock.lock()
                defer { lock.unlock() }
                durationsNanos.append(contentsOf: nanos)
            }
        }

        let collector = LatencyCollector()

        await withTaskGroup(of: [UInt64].self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    var localLatencies: [UInt64] = []
                    localLatencies.reserveCapacity(queriesPerTask)

                    for queryId in 0..<queriesPerTask {
                        let center = coordinatePool[(taskId * 17 + queryId) % coordinatePool.count]
                        let zoomFactor: LoupeZoomFactor = (queryId % 2 == 0) ? .zoom4x : .zoom8x
                        let dim = zoomFactor.sourceGridDimension

                        let start = DispatchTime.now().uptimeNanoseconds
                        let grid = LoupePixelSampler.sampleGrid(in: retinaImage, center: center, zoomFactor: zoomFactor)
                        let end = DispatchTime.now().uptimeNanoseconds
                        localLatencies.append(end - start)

                        // Invariant 1: Grid dimensions strictly match zoom factor
                        #expect(grid.count == dim)
                        #expect(grid.first?.count == dim)

                        // Invariant 2: Center pixel in grid strictly matches direct samplePixel
                        let centerPixel = grid[dim / 2][dim / 2]
                        let directPixel = LoupePixelSampler.samplePixel(in: retinaImage, at: center)
                        #expect(centerPixel == directPixel)
                    }
                    return localLatencies
                }
            }

            for await taskLatencies in group {
                collector.record(nanos: taskLatencies)
            }
        }

        let allDurations = collector.durationsNanos.sorted()
        #expect(allDurations.count == totalQueries)

        let minMs = Double(allDurations.first ?? 0) / 1_000_000.0
        let maxMs = Double(allDurations.last ?? 0) / 1_000_000.0
        let totalMs = Double(allDurations.reduce(0, +)) / 1_000_000.0
        let avgMs = totalMs / Double(totalQueries)
        let p50Ms = Double(allDurations[Int(Double(totalQueries) * 0.50)]) / 1_000_000.0
        let p95Ms = Double(allDurations[Int(Double(totalQueries) * 0.95)]) / 1_000_000.0
        let p99Ms = Double(allDurations[Int(Double(totalQueries) * 0.99)]) / 1_000_000.0

        print(String(
            format: "[Challenger SLA Verification: Loupe sampleGrid Latency] Count=%d, Min=%.4fms, p50=%.4fms, Avg=%.4fms, p95=%.4fms, p99=%.4fms, Max=%.4fms (SLA threshold: < 0.500ms)",
            totalQueries, minMs, p50Ms, avgMs, p95Ms, p99Ms, maxMs
        ))

        // Strict SLA Verification: Mean latency must be well under 0.5ms (500 microseconds)
        #expect(avgMs < 0.5, "Average sampleGrid latency was \(avgMs) ms, exceeding SLA of 0.5 ms!")
        // p95 latency must also be under 1.5ms under concurrent load with parallel multi-suite contention
        #expect(p95Ms < 1.5, "p95 sampleGrid latency was \(p95Ms) ms, exceeding SLA of 1.5 ms under multi-suite contention!")
    }

    @Test("CH2-M6-LOUPE-02: LoupePixelSampler hoisted pointer vs per-pixel sampling fidelity")
    func testLoupePixelSamplerHoistedFidelity() {
        let testImage = makeRetinaCaptureImage(width: 800, height: 600)

        // Diverse test points
        let testPoints: [CGPoint] = [
            CGPoint(x: 400, y: 300),
            CGPoint(x: 10, y: 10),
            CGPoint(x: 790, y: 590),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 799, y: 599),
            CGPoint(x: 250.3, y: 350.7),
            CGPoint(x: -5, y: 300),
            CGPoint(x: 400, y: -5),
            CGPoint(x: 805, y: 300),
            CGPoint(x: 400, y: 605)
        ]

        for pt in testPoints {
            for zoom in [LoupeZoomFactor.zoom4x, LoupeZoomFactor.zoom8x] {
                let grid = LoupePixelSampler.sampleGrid(in: testImage, center: pt, zoomFactor: zoom)
                let dim = zoom.sourceGridDimension
                let half = dim / 2

                #expect(grid.count == dim)
                for r in 0..<dim {
                    #expect(grid[r].count == dim)
                    for c in 0..<dim {
                        let sampleY = pt.y.rounded() + CGFloat(half - r)
                        let sampleX = pt.x.rounded() + CGFloat(c - half)
                        let expected = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: sampleX, y: sampleY))
                        let actual = grid[r][c]
                        #expect(actual == expected, "Mismatch at (\(r),\(c)) for center \(pt): expected \(expected.hexString), got \(actual.hexString)")
                    }
                }
            }
        }
    }

    // MARK: - 3. SpringAnimationTokens Validation & Design Integrity

    @Test("CH2-M6-TOKENS-01: SpringAnimationTokens mathematical validity and immutability")
    func testSpringAnimationTokensIntegrity() {
        #expect(SpringAnimationTokens.response == 0.3)
        #expect(SpringAnimationTokens.dampingFraction == 0.75)
        #expect(SpringAnimationTokens.blendDuration == 0.0)

        #expect(SpringAnimationTokens.interactiveResponse == 0.25)
        #expect(SpringAnimationTokens.interactiveDamping == 0.8)

        let fluid = SpringAnimationTokens.fluidSpring
        #expect(fluid.response == 0.3)
        #expect(fluid.dampingFraction == 0.75)
        #expect(fluid.blendDuration == 0.0)

        // Verify dampingFraction > 0 ensures critically damped / stable decay (no endless ringing)
        #expect(fluid.dampingFraction > 0)
        #expect(SpringAnimationTokens.interactiveDamping > 0)

        // Verify response > 0 ensures non-infinite stiffness
        #expect(fluid.response > 0)
        #expect(SpringAnimationTokens.interactiveResponse > 0)

        // Token equality
        let custom = SpringAnimationTokens(response: 0.3, dampingFraction: 0.75, blendDuration: 0.0)
        #expect(fluid == custom)
    }
}
