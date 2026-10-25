import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Challenger 1: Vision Concurrency, Cancellation & Stress Resilience Probing", .serialized)
struct VisionStressChallengerTests {

    private let engine = VisionEngineService()

    // MARK: - Challenge 1: Concurrency Limiter Ceiling Enforcement Under Heavy Burst Contention

    @Test("STRESS-01: 100-task burst contention strictly enforces concurrency ceiling with zero invariant violations")
    func testMassiveBurstContentionCeiling() async throws {
        let ceiling = 3
        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: ceiling)
        let totalTasks = 100

        let activeCounter = SynchronizedCounter()
        let peakCounter = SynchronizedCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<totalTasks {
                group.addTask {
                    try await limiter.withPermit {
                        let active = activeCounter.increment()
                        peakCounter.updateMax(active)

                        // Invariant check: active workers must never exceed ceiling
                        #expect(active <= ceiling, "Ceiling violated: \(active) > \(ceiling) at task \(i)")

                        // Simulate variable asynchronous inference workload (1-5ms)
                        let sleepNs = UInt64.random(in: 1_000_000...5_000_000)
                        try await Task.sleep(nanoseconds: sleepNs)

                        activeCounter.decrement()
                    }
                }
            }

            for try await _ in group {}
        }

        let peak = peakCounter.value
        #expect(peak <= ceiling, "Peak active tasks (\(peak)) exceeded ceiling (\(ceiling))")
        #expect(peak > 0)
        #expect(activeCounter.value == 0, "Dangling active count: \(activeCounter.value)")

        let finalActive = await limiter.activeTaskCount
        let finalWaiting = await limiter.waitingTaskCount
        #expect(finalActive == 0, "Limiter activeTaskCount leaked: \(finalActive)")
        #expect(finalWaiting == 0, "Limiter waitingTaskCount leaked: \(finalWaiting)")
    }

    @Test("STRESS-02: Single-permit ceiling (maxConcurrent = 1) enforces mutual exclusion under 50-task burst")
    func testSinglePermitMutualExclusionBurst() async throws {
        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: 1)
        let totalTasks = 50

        let activeCounter = SynchronizedCounter()
        let peakCounter = SynchronizedCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<totalTasks {
                group.addTask {
                    try await limiter.withPermit {
                        let active = activeCounter.increment()
                        peakCounter.updateMax(active)
                        #expect(active == 1, "Mutual exclusion violated: active = \(active)")

                        try await Task.sleep(nanoseconds: 500_000) // 0.5ms
                        activeCounter.decrement()
                    }
                }
            }

            for try await _ in group {}
        }

        #expect(peakCounter.value == 1)
        #expect(activeCounter.value == 0)
        let finalActive = await limiter.activeTaskCount
        let finalWaiting = await limiter.waitingTaskCount
        #expect(finalActive == 0)
        #expect(finalWaiting == 0)
    }

    // MARK: - Challenge 2: Chaos Cancellation & Permutation Resilience

    @Test("STRESS-03: Chaotic cancellation of queued and in-flight tasks leaves zero orphaned tasks or leaked permits")
    func testChaoticCancellationUnderContention() async throws {
        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: 2)
        let totalTasks = 60
        let completedCounter = SynchronizedCounter()
        let cancelledCounter = SynchronizedCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalTasks {
                group.addTask {
                    let shouldCancel = (i % 2 == 0) // Cancel 50% of tasks
                    let cancelDelayUs = UInt64.random(in: 0...2000) // 0 to 2ms delay

                    let task = Task { () -> Bool in
                        do {
                            return try await limiter.withPermit {
                                try Task.checkCancellation()
                                try await Task.sleep(nanoseconds: 3_000_000) // 3ms work
                                try Task.checkCancellation()
                                return true
                            }
                        } catch is CancellationError {
                            return false
                        } catch {
                            return false
                        }
                    }

                    if shouldCancel {
                        if cancelDelayUs > 0 {
                            try? await Task.sleep(nanoseconds: cancelDelayUs * 1000)
                        }
                        task.cancel()
                    }

                    let succeeded = await task.value
                    if succeeded {
                        completedCounter.increment()
                    } else {
                        cancelledCounter.increment()
                    }
                }
            }

            for await _ in group {}
        }

        #expect(completedCounter.value + cancelledCounter.value == totalTasks)
        #expect(cancelledCounter.value > 0, "Expected at least some cancelled tasks")
        #expect(completedCounter.value > 0, "Expected at least some completed tasks")

        // Limiter must be completely clean with zero leaked permits
        let finalActive = await limiter.activeTaskCount
        let finalWaiting = await limiter.waitingTaskCount
        #expect(finalActive == 0, "Limiter active count leaked permits: \(finalActive)")
        #expect(finalWaiting == 0, "Limiter waiting count leaked waiters: \(finalWaiting)")

        // Verify subsequent tasks acquire and release permits immediately without getting stuck
        let postVerificationSuccess = try await limiter.withPermit {
            true
        }
        #expect(postVerificationSuccess, "Limiter locked up after cancellation storm")
    }

    @Test("STRESS-04: Error throwing inside withPermit never leaks concurrency permits")
    func testErrorThrowingDoesNotLeakPermits() async throws {
        struct ProbeError: Error, Equatable {}

        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: 2)
        let iterations = 40

        for i in 0..<iterations {
            do {
                try await limiter.withPermit {
                    if i % 2 == 0 {
                        throw ProbeError()
                    }
                }
            } catch is ProbeError {
                // Expected failure
            }

            let active = await limiter.activeTaskCount
            let waiting = await limiter.waitingTaskCount
            #expect(active == 0, "Iteration \(i) leaked active permit: \(active)")
            #expect(waiting == 0, "Iteration \(i) leaked waiting task: \(waiting)")
        }
    }

    // MARK: - Challenge 3: Real VisionEngineService Under Contention & Cancellation

    @Test("STRESS-05: Real VisionEngineService under burst contention with interleaved cancellation")
    func testRealEngineBurstAndCancellation() async throws {
        let testImage = VisionTestImageGenerator.createTextImage(text: "STRESS TEST BURST", fontSize: 28)
        let compositeImage = VisionTestImageGenerator.createCompositeTextAndQRImage(
            text: "BURST QR TEST",
            qrPayload: "https://zenith.app/stress"
        )

        let totalOps = 16
        let cancelledCount = SynchronizedCounter()
        let successCount = SynchronizedCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalOps {
                group.addTask {
                    let task = Task { () throws -> Void in
                        if i % 3 == 0 {
                            let res = try await self.engine.recognizeText(
                                in: testImage,
                                config: VisionTextConfig(level: .fast)
                            )
                            #expect(!res.lines.isEmpty)
                        } else if i % 3 == 1 {
                            let barcodes = try await self.engine.detectBarcodes(in: compositeImage)
                            #expect(!barcodes.isEmpty)
                        } else {
                            let analysis = try await self.engine.analyze(
                                image: compositeImage,
                                options: VisionAnalysisOptions(textConfig: VisionTextConfig(level: .fast))
                            )
                            #expect(!analysis.textResult.lines.isEmpty)
                        }
                    }

                    // Cancel every second task after a micro-sleep
                    if i % 2 == 1 {
                        try? await Task.sleep(nanoseconds: 500_000) // 0.5ms
                        task.cancel()
                    }

                    do {
                        try await task.value
                        successCount.increment()
                    } catch let error as VisionEngineError {
                        if error == .cancelled {
                            cancelledCount.increment()
                        } else {
                            Issue.record("Unexpected VisionEngineError: \(error)")
                        }
                    } catch is CancellationError {
                        cancelledCount.increment()
                    } catch {
                        Issue.record("Unexpected error thrown: \(error)")
                    }
                }
            }

            for await _ in group {}
        }

        #expect(successCount.value + cancelledCount.value == totalOps)
        #expect(successCount.value > 0)

        // Engine must be fully operational immediately after storm
        let recoveryResult = try await self.engine.recognizeText(
            in: testImage,
            config: VisionTextConfig(level: .fast)
        )
        #expect(recoveryResult.fullText.contains("STRESS"))
    }

    @Test("STRESS-06: Rapid successive pre-flight cancelled requests abort without entering execution queue")
    func testPreFlightCancellationStorm() async throws {
        let testImage = VisionTestImageGenerator.createTextImage(text: "PREFLIGHT STORM", fontSize: 28)
        let iterations = 30

        for _ in 0..<iterations {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await self.engine.recognizeText(in: testImage)
            }

            let res = await task.result
            switch res {
            case .success:
                Issue.record("Task succeeded despite being pre-cancelled")
            case .failure(let err):
                if let vErr = err as? VisionEngineError {
                    #expect(vErr == .cancelled)
                } else {
                    #expect(err is CancellationError)
                }
            }
        }
    }
}

// MARK: - Synchronized Counter Helper

private final class SynchronizedCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }

    @discardableResult
    func decrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value -= 1
        return _value
    }

    func updateMax(_ candidate: Int) {
        lock.lock()
        defer { lock.unlock() }
        _value = max(_value, candidate)
    }
}
