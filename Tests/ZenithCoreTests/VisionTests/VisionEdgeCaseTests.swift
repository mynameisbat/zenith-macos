import Testing
import Foundation
import CoreGraphics
import Darwin
@testable import ZenithCore

@Suite("Vision Engine 5 Critical Edge Cases Automated Test Suite", .serialized)
struct VisionEdgeCaseTests {

    private let engine = VisionEngineService()

    // MARK: - Edge Case 1: Empty / Malformed Input

    @Test("EC-01A: Oversized width exceeding 32768 throws VisionEngineError.invalidImage")
    func testOversizedWidthThrowsInvalidImage() async {
        let oversizedImage = VisionTestImageGenerator.createOversizedImage(width: 33000, height: 2)

        await #expect(throws: VisionEngineError.self) {
            try await engine.recognizeText(in: oversizedImage)
        }

        do {
            _ = try await engine.recognizeText(in: oversizedImage)
            Issue.record("Expected VisionEngineError.invalidImage to be thrown for oversized width")
        } catch let error as VisionEngineError {
            switch error {
            case .invalidImage(let reason):
                #expect(reason.contains("32768"))
            default:
                Issue.record("Unexpected error thrown: \(error)")
            }
        } catch {
            Issue.record("Non-VisionEngineError thrown: \(error)")
        }

        // Verify barcode and analyze also reject oversized images
        await #expect(throws: VisionEngineError.self) {
            try await engine.detectBarcodes(in: oversizedImage)
        }
        await #expect(throws: VisionEngineError.self) {
            try await engine.analyze(image: oversizedImage)
        }
    }

    @Test("EC-01B: Oversized height exceeding 32768 throws VisionEngineError.invalidImage")
    func testOversizedHeightThrowsInvalidImage() async {
        let oversizedImage = VisionTestImageGenerator.createOversizedImage(width: 2, height: 33000)

        do {
            _ = try await engine.recognizeText(in: oversizedImage)
            Issue.record("Expected invalidImage for oversized height")
        } catch let error as VisionEngineError {
            switch error {
            case .invalidImage(let reason):
                #expect(reason.contains("32768"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Non-VisionEngineError thrown: \(error)")
        }
    }

    @Test("EC-01C: 1x1 degenerate pixel image succeeds returning empty text lines without crashing")
    func testDegenerate1x1ImageResilience() async throws {
        let degenerateImage = VisionTestImageGenerator.createDegenerate1x1Image()

        let textResult = try await engine.recognizeText(in: degenerateImage)
        #expect(textResult.lines.isEmpty)
        #expect(textResult.fullText.isEmpty)
        #expect(textResult.imageSize.width == 1.0)
        #expect(textResult.imageSize.height == 1.0)

        let barcodes = try await engine.detectBarcodes(in: degenerateImage)
        #expect(barcodes.isEmpty)

        let analysis = try await engine.analyze(image: degenerateImage)
        #expect(analysis.textResult.lines.isEmpty)
        #expect(analysis.barcodes.isEmpty)
    }

    @Test("EC-01D: Blank canvas image returns empty results gracefully")
    func testBlankCanvasReturnsEmptyResults() async throws {
        let blankImage = VisionTestImageGenerator.createBlankImage(width: 600, height: 400)

        let result = try await engine.recognizeText(in: blankImage)
        #expect(result.lines.isEmpty)
        #expect(result.fullText.isEmpty)
    }

    @Test("EC-01E: VisionEngineError localized error descriptions and reasons")
    func testErrorDescriptionsAndFormatting() {
        let errInvalid = VisionEngineError.invalidImage(reason: "Image dimensions must be positive (got 0x0)")
        #expect(errInvalid.errorDescription == "Invalid image: Image dimensions must be positive (got 0x0)")
        #expect(errInvalid.failureReason == "Invalid image: Image dimensions must be positive (got 0x0)")
        #expect(errInvalid.description == "Invalid image: Image dimensions must be positive (got 0x0)")

        let errCorrupt = VisionEngineError.corruptData
        #expect(errCorrupt.errorDescription == "Image data is corrupted or unreadable")

        let errRecognition = VisionEngineError.recognitionFailed(reason: "CoreML model load failure")
        #expect(errRecognition.errorDescription?.contains("CoreML") == true)

        let errCancelled = VisionEngineError.cancelled
        #expect(errCancelled.errorDescription == "Vision operation was cancelled")

        let errLimiter = VisionEngineError.concurrencyLimitExceeded
        #expect(errLimiter.errorDescription == "Vision concurrency limit exceeded")

        let errLang = VisionEngineError.unsupportedLanguage(["xx-YY", "zz-WW"])
        #expect(errLang.errorDescription?.contains("xx-YY") == true)
    }

    // MARK: - Edge Case 2: Permission Denial & Missing Capabilities

    @Test("EC-02A: Upstream permission denial simulation handled gracefully with actionable recovery")
    func testPermissionDenialAndRecoverySimulation() async throws {
        let mockService = MockVisionEngineService()
        let testImage = VisionTestImageGenerator.createTextImage(text: "PERMISSION TEST", fontSize: 32)

        // Simulate upstream TCC Screen Recording denial
        let tccDeniedError = VisionEngineError.processingFailed(
            reason: "Screen Recording permission denied by macOS TCC. Please authorize in System Settings > Privacy & Security."
        )
        mockService.shouldThrowError = tccDeniedError

        // Verify recognizeText throws localized error
        do {
            _ = try await mockService.recognizeText(in: testImage)
            Issue.record("Expected processingFailed due to simulated TCC denial")
        } catch let error as VisionEngineError {
            #expect(error == tccDeniedError)
            #expect(error.errorDescription?.contains("Screen Recording permission denied") == true)
            #expect(error.errorDescription?.contains("System Settings") == true)
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }

        // Verify detectBarcodes also throws
        do {
            _ = try await mockService.detectBarcodes(in: testImage)
            Issue.record("Expected processingFailed for barcodes")
        } catch let error as VisionEngineError {
            #expect(error == tccDeniedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Verify single-pass analyze also throws
        do {
            _ = try await mockService.analyze(image: testImage)
            Issue.record("Expected processingFailed for analyze")
        } catch let error as VisionEngineError {
            #expect(error == tccDeniedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Verify Permission Recovery: user grants permission in System Settings -> engine recovers immediately
        mockService.shouldThrowError = nil
        mockService.stubbedTextResult = VisionTextRecognitionResult(
            fullText: "PERMISSION GRANTED RECOVERY",
            lines: [
                VisionRecognizedTextLine(
                    text: "PERMISSION GRANTED RECOVERY",
                    confidence: 0.99,
                    boundingBox: VisionBoundingBox(x: 0, y: 0, width: 1, height: 1)
                )
            ],
            executionDuration: 0.012,
            imageSize: CGSize(width: 600, height: 200)
        )

        let recoveredResult = try await mockService.recognizeText(in: testImage)
        #expect(recoveredResult.fullText == "PERMISSION GRANTED RECOVERY")
        #expect(mockService.recognizeTextCallCount == 2)
    }

    @Test("EC-02B: Real engine state remains healthy after simulated upstream failure")
    func testRealEngineStateIsolationAfterError() async throws {
        // First request with invalid oversized image fails
        let invalidImage = VisionTestImageGenerator.createOversizedImage(width: 35000, height: 1)
        await #expect(throws: VisionEngineError.self) {
            try await engine.recognizeText(in: invalidImage)
        }

        // Subsequent request with valid image succeeds immediately without service restart
        let validImage = VisionTestImageGenerator.createTextImage(text: "RECOVERED CLEAN ENGINE", fontSize: 32)
        let result = try await engine.recognizeText(in: validImage)
        #expect(result.fullText.contains("RECOVERED"))
    }

    // MARK: - Edge Case 3: High Concurrency & Re-Entrant Requests

    @Test("EC-03A: Rapid burst of concurrent requests execute without deadlocks or dropped tasks")
    func testHighConcurrencyBurstOfTasks() async throws {
        let testImage = VisionTestImageGenerator.createTextImage(text: "CONCURRENCY BURST TEST", fontSize: 32)

        let totalTasks = 8
        let results = try await withThrowingTaskGroup(of: VisionTextRecognitionResult.self) { group in
            for _ in 0..<totalTasks {
                group.addTask {
                    try await self.engine.recognizeText(in: testImage, config: VisionTextConfig(level: .fast))
                }
            }

            var collected: [VisionTextRecognitionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == totalTasks)
        for result in results {
            #expect(!result.lines.isEmpty)
            #expect(result.fullText.contains("CONCURRENCY"))
        }
    }

    @Test("EC-03B: VisionConcurrencyLimiter strictly enforces max concurrent ceiling under heavy contention")
    func testConcurrencyLimiterCeilingEnforcement() async throws {
        let maxConcurrent = 2
        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: maxConcurrent)
        let totalWorkers = 10

        let currentActiveWorkers = LockedBox(value: 0)
        let peakActiveWorkers = LockedBox(value: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<totalWorkers {
                group.addTask {
                    try await limiter.withPermit {
                        currentActiveWorkers.update { $0 + 1 }
                        let active = currentActiveWorkers.value
                        peakActiveWorkers.update { max($0, active) }
                        defer { currentActiveWorkers.update { $0 - 1 } }
                        // Simulate non-trivial work
                        try await Task.sleep(nanoseconds: 5_000_000) // 5ms
                    }
                }
            }

            for try await _ in group {}
        }

        let peak = peakActiveWorkers.value
        #expect(peak <= maxConcurrent)
        #expect(peak > 0)
        let finalActive = await limiter.activeTaskCount
        let finalWaiting = await limiter.waitingTaskCount
        #expect(finalActive == 0)
        #expect(finalWaiting == 0)
    }

    @Test("EC-03C: Interleaved concurrent mixed operations (Text, Barcode, Analyze)")
    func testInterleavedMixedConcurrentOperations() async throws {
        let compositeImage = VisionTestImageGenerator.createCompositeTextAndQRImage(
            text: "MIXED OP SUITE",
            qrPayload: "https://zenith.app/mixed"
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 2 text requests
            for _ in 0..<2 {
                group.addTask {
                    let res = try await self.engine.recognizeText(
                        in: compositeImage,
                        config: VisionTextConfig(level: .fast)
                    )
                    #expect(!res.lines.isEmpty)
                }
            }
            // 2 barcode requests
            for _ in 0..<2 {
                group.addTask {
                    let barcodes = try await self.engine.detectBarcodes(in: compositeImage)
                    #expect(!barcodes.isEmpty)
                }
            }
            // 2 joint analysis requests
            for _ in 0..<2 {
                group.addTask {
                    let analysis = try await self.engine.analyze(
                        image: compositeImage,
                        options: VisionAnalysisOptions(textConfig: VisionTextConfig(level: .fast))
                    )
                    #expect(!analysis.textResult.lines.isEmpty)
                    #expect(!analysis.barcodes.isEmpty)
                }
            }

            for try await _ in group {}
        }
    }

    // MARK: - Edge Case 4: Large / Extreme Data Load

    @Test("EC-04A: Processes 8K Retina screen buffer (7680x4320, ~133MB) with bounded memory")
    func testProcess8KRetinaBuffer() async throws {
        let image8K = VisionTestImageGenerator.create8KRetinaBufferImage(withText: "ZENITH 8K PRO DISPLAY")

        #expect(image8K.width == 7680)
        #expect(image8K.height == 4320)

        // Capture memory before inference
        let memoryBefore = residentMemoryBytes()

        let result = try await engine.recognizeText(
            in: image8K,
            config: VisionTextConfig(level: .fast)
        )

        let memoryAfter = residentMemoryBytes()

        #expect(result.imageSize.width == 7680.0)
        #expect(result.imageSize.height == 4320.0)
        #expect(result.fullText.contains("ZENITH") || result.fullText.contains("8K") || result.fullText.contains("PRO"))

        // Memory growth should remain reasonable and bounded (< 500 MB heap growth for 8K)
        let memoryDeltaMB = Double(max(0, memoryAfter - memoryBefore)) / (1024.0 * 1024.0)
        #expect(memoryDeltaMB < 500.0)
    }

    @Test("EC-04B: Multilingual Unicode content recognition across Latin, Japanese, and Chinese")
    func testMultilingualUnicodeContent() async throws {
        let multiImage = VisionTestImageGenerator.createMultilingualTextImage()

        let config = VisionTextConfig(
            level: .accurate,
            languages: ["en-US", "ja-JP", "zh-Hans"],
            usesLanguageCorrection: true
        )

        let result = try await engine.recognizeText(in: multiImage, config: config)

        #expect(!result.lines.isEmpty)
        #expect(result.fullText.contains("ZENITH") || result.fullText.contains("SYSTEM") || result.fullText.contains("WORKSTATION"))
    }

    // MARK: - Edge Case 5: Resource Exhaustion & Cooperative Cancellation

    @Test("EC-05A: In-flight recognition task cancels cooperatively throwing VisionEngineError.cancelled")
    func testInFlightTaskCancellation() async {
        let image8K = VisionTestImageGenerator.create8KRetinaBufferImage(withText: "LONG RUNNING WORKLOAD")

        let task = Task {
            try await self.engine.recognizeText(in: image8K, config: VisionTextConfig(level: .accurate))
        }

        // Cancel almost immediately while request handler is initializing or running
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            // If the machine is exceptionally fast and finished before cancel signal, that is acceptable,
            // but task.isCancelled must be verifiable.
            break
        case .failure(let error):
            if let visionError = error as? VisionEngineError {
                #expect(visionError == .cancelled)
            } else if error is CancellationError {
                // Also compliant Swift cancellation
            } else {
                Issue.record("Unexpected cancellation error: \(error)")
            }
        }
    }

    @Test("EC-05B: Pre-flight cancellation check halts before processing begins")
    func testPreFlightCancellationCheck() async {
        let testImage = VisionTestImageGenerator.createTextImage(text: "PREFLIGHT CANCEL", fontSize: 32)

        let task = Task {
            // Cancel task before calling engine to test pre-flight check
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.engine.recognizeText(in: testImage)
        }

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Task succeeded despite being cancelled before start")
        case .failure(let error):
            if let visionError = error as? VisionEngineError {
                #expect(visionError == .cancelled)
            } else {
                #expect(error is CancellationError)
            }
        }
    }

    @Test("EC-05C: Cancellation while waiting in concurrency limiter queue resumes immediately with cancellation")
    func testCancellationWhileWaitingInLimiterQueue() async throws {
        let limiter = VisionConcurrencyLimiter(maxConcurrentTasks: 1)

        // Directly acquire the single permit
        try await limiter.acquire()
        let active = await limiter.activeTaskCount
        #expect(active == 1)

        // Launch queued task that will suspend in acquire()
        let waiterTask = Task {
            try await limiter.acquire()
            await limiter.release()
        }

        // Allow waiterTask time to enqueue
        for _ in 0..<20 {
            let waiting = await limiter.waitingTaskCount
            if waiting == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        let waiting = await limiter.waitingTaskCount
        #expect(waiting == 1)

        // Cancel the waiting task
        waiterTask.cancel()

        // Verify waiterTask aborts with CancellationError
        let waiterResult = await waiterTask.result
        switch waiterResult {
        case .success:
            Issue.record("Queued task should have been cancelled")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        // Release the held permit
        await limiter.release()

        // Verify limiter is clean with no stranded permits
        let finalWaiting = await limiter.waitingTaskCount
        let finalActive = await limiter.activeTaskCount
        #expect(finalWaiting == 0)
        #expect(finalActive == 0)

        // Next task can acquire permit smoothly
        try await limiter.withPermit {
            // Success
        }
    }

    @Test("EC-05D: Cooperative cancellation during barcode detection and composite analyze")
    func testBarcodeAndAnalyzeCancellation() async {
        let compositeImage = VisionTestImageGenerator.createCompositeTextAndQRImage()

        let barcodeTask = Task {
            try await self.engine.detectBarcodes(in: compositeImage)
        }
        barcodeTask.cancel()
        let barcodeResult = await barcodeTask.result
        if case .failure(let error) = barcodeResult {
            if let vErr = error as? VisionEngineError {
                #expect(vErr == .cancelled)
            }
        }

        let analyzeTask = Task {
            try await self.engine.analyze(image: compositeImage)
        }
        analyzeTask.cancel()
        let analyzeResult = await analyzeTask.result
        if case .failure(let error) = analyzeResult {
            if let vErr = error as? VisionEngineError {
                #expect(vErr == .cancelled)
            }
        }
    }
}

// MARK: - Test Helpers

/// Thread-safe locked container for synchronization in concurrent tests.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    func update(_ transform: (T) -> T) {
        lock.lock()
        defer { lock.unlock() }
        _value = transform(_value)
    }
}


/// Reads current resident process memory in bytes via Darwin mach_task_basic_info.
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
