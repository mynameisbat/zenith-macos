import Foundation
import CoreGraphics
import Vision

/// Production-grade implementation of `VisionEngineProtocol` leveraging Apple's Vision framework.
///
/// Features:
/// - Single-pass joint OCR and Barcode recognition via unified `VNImageRequestHandler`.
/// - Concurrency throttling via `VisionConcurrencyLimiter` actor (prevents thermal throttling and memory spikes).
/// - Strict input validation against invalid dimensions, memory bounds, and nil data providers.
/// - Scoped `autoreleasepool` memory management for immediate deallocation of ML feature maps.
/// - Cooperative task cancellation via `withTaskCancellationHandler` and `VNRequest.cancel()`.
/// - Strict Swift 6 `Sendable` encapsulation: Objective-C Vision reference types never escape the worker scope.
/// - Zero idle overhead: zero background daemons, zero timers, zero retained CoreML weights.
public final class VisionEngineService: VisionEngineProtocol, Sendable {
    /// Shared singleton instance with default concurrency limiter (maximum 2 concurrent tasks).
    public static let shared = VisionEngineService()

    /// Concurrency limiter regulating active Vision tasks.
    private let limiter: VisionConcurrencyLimiter

    /// Initializes a new `VisionEngineService` instance.
    /// - Parameter limiter: The concurrency limiter actor to use (defaults to 2 concurrent tasks).
    public init(limiter: VisionConcurrencyLimiter = VisionConcurrencyLimiter(maxConcurrentTasks: 2)) {
        self.limiter = limiter
    }

    // MARK: - Public VisionEngineProtocol API

    /// Recognizes text lines in the given CGImage using the provided configuration.
    public func recognizeText(
        in image: CGImage,
        config: VisionTextConfig
    ) async throws -> VisionTextRecognitionResult {
        try validate(image: image)
        try Task.checkCancellation()

        // Handle degenerate micro-images (< 3x3) gracefully without Vision throwing dimension errors
        guard image.width >= 3, image.height >= 3 else {
            return VisionTextRecognitionResult(
                fullText: "",
                lines: [],
                executionDuration: 0.001,
                imageSize: CGSize(width: image.width, height: image.height)
            )
        }

        do {
            return try await limiter.withPermit {
                try Task.checkCancellation()
                let clock = ContinuousClock()
                let startTime = clock.now

                let textRequest = VNRecognizeTextRequest()
                self.configureTextRequest(textRequest, with: config)

                let cancellationBox = CancellationBox()
                cancellationBox.setRequests([textRequest])

                let handler = VNImageRequestHandler(cgImage: image, options: [:])

                do {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            try handler.perform([textRequest])
                        }
                        try Task.checkCancellation()
                    } onCancel: {
                        cancellationBox.cancel()
                    }
                } catch is CancellationError {
                    throw VisionEngineError.cancelled
                } catch let error as VisionEngineError {
                    throw error
                } catch {
                    if Task.isCancelled {
                        throw VisionEngineError.cancelled
                    }
                    throw VisionEngineError.recognitionFailed(reason: error.localizedDescription)
                }

                let elapsed = Self.durationInSeconds(from: startTime, to: clock.now)
                return self.extractTextResults(
                    from: textRequest,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    duration: elapsed
                )
            }
        } catch is CancellationError {
            throw VisionEngineError.cancelled
        }
    }

    /// Detects 1D and 2D barcodes in the given CGImage matching the specified symbologies.
    public func detectBarcodes(
        in image: CGImage,
        types: [VisionBarcodeType]
    ) async throws -> [VisionBarcodeResult] {
        try validate(image: image)
        try Task.checkCancellation()

        guard !types.isEmpty else {
            return []
        }

        guard image.width >= 3, image.height >= 3 else {
            return []
        }

        do {
            return try await limiter.withPermit {
                try Task.checkCancellation()

                let barcodeRequest = VNDetectBarcodesRequest()
                barcodeRequest.symbologies = types.map(self.mapTypeToSymbology)

                let cancellationBox = CancellationBox()
                cancellationBox.setRequests([barcodeRequest])

                let handler = VNImageRequestHandler(cgImage: image, options: [:])

                do {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            try handler.perform([barcodeRequest])
                        }
                        try Task.checkCancellation()
                    } onCancel: {
                        cancellationBox.cancel()
                    }
                } catch is CancellationError {
                    throw VisionEngineError.cancelled
                } catch let error as VisionEngineError {
                    throw error
                } catch {
                    if Task.isCancelled {
                        throw VisionEngineError.cancelled
                    }
                    throw VisionEngineError.recognitionFailed(reason: error.localizedDescription)
                }

                return self.extractBarcodeResults(
                    from: barcodeRequest,
                    imageWidth: image.width,
                    imageHeight: image.height
                )
            }
        } catch is CancellationError {
            throw VisionEngineError.cancelled
        }
    }

    /// Performs single-pass joint text recognition and barcode detection.
    public func analyze(
        image: CGImage,
        options: VisionAnalysisOptions
    ) async throws -> VisionAnalysisResult {
        try validate(image: image)
        try Task.checkCancellation()

        guard options.recognizeText || (options.detectBarcodes && !options.barcodeTypes.isEmpty) else {
            return VisionAnalysisResult.empty
        }

        guard image.width >= 3, image.height >= 3 else {
            return VisionAnalysisResult(
                textResult: VisionTextRecognitionResult(
                    fullText: "",
                    lines: [],
                    executionDuration: 0.001,
                    imageSize: CGSize(width: image.width, height: image.height)
                ),
                barcodes: [],
                executionDuration: 0.001
            )
        }

        do {
            return try await limiter.withPermit {
                try Task.checkCancellation()
                let clock = ContinuousClock()
                let startTime = clock.now

                var requests: [VNRequest] = []
                var textRequest: VNRecognizeTextRequest?
                var barcodeRequest: VNDetectBarcodesRequest?

                if options.recognizeText {
                    let textReq = VNRecognizeTextRequest()
                    self.configureTextRequest(textReq, with: options.textConfig)
                    textRequest = textReq
                    requests.append(textReq)
                }

                if options.detectBarcodes && !options.barcodeTypes.isEmpty {
                    let barcodeReq = VNDetectBarcodesRequest()
                    barcodeReq.symbologies = options.barcodeTypes.map(self.mapTypeToSymbology)
                    barcodeRequest = barcodeReq
                    requests.append(barcodeReq)
                }

                let cancellationBox = CancellationBox()
                cancellationBox.setRequests(requests)

                let handler = VNImageRequestHandler(cgImage: image, options: [:])

                do {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            try handler.perform(requests)
                        }
                        try Task.checkCancellation()
                    } onCancel: {
                        cancellationBox.cancel()
                    }
                } catch is CancellationError {
                    throw VisionEngineError.cancelled
                } catch let error as VisionEngineError {
                    throw error
                } catch {
                    if Task.isCancelled {
                        throw VisionEngineError.cancelled
                    }
                    throw VisionEngineError.recognitionFailed(reason: error.localizedDescription)
                }

                let elapsed = Self.durationInSeconds(from: startTime, to: clock.now)

                let textResult: VisionTextRecognitionResult
                if let textReq = textRequest {
                    textResult = self.extractTextResults(
                        from: textReq,
                        imageWidth: image.width,
                        imageHeight: image.height,
                        duration: elapsed
                    )
                } else {
                    textResult = .empty
                }

                let barcodeResults: [VisionBarcodeResult]
                if let barcodeReq = barcodeRequest {
                    barcodeResults = self.extractBarcodeResults(
                        from: barcodeReq,
                        imageWidth: image.width,
                        imageHeight: image.height
                    )
                } else {
                    barcodeResults = []
                }

                return VisionAnalysisResult(
                    textResult: textResult,
                    barcodes: barcodeResults,
                    executionDuration: elapsed
                )
            }
        } catch is CancellationError {
            throw VisionEngineError.cancelled
        }
    }

    // MARK: - Validation

    private func validate(image: CGImage) throws {
        guard image.width > 0, image.height > 0 else {
            throw VisionEngineError.invalidImage(
                reason: "Image dimensions must be positive (got \(image.width)x\(image.height))"
            )
        }
        guard image.width <= 32768, image.height <= 32768 else {
            throw VisionEngineError.invalidImage(
                reason: "Image dimensions exceed max supported boundary 32768 (got \(image.width)x\(image.height))"
            )
        }
        guard image.dataProvider != nil else {
            throw VisionEngineError.invalidImage(
                reason: "CGImage dataProvider is nil"
            )
        }
    }

    // MARK: - Private Configuration & Extraction Helpers

    private func configureTextRequest(
        _ request: VNRecognizeTextRequest,
        with config: VisionTextConfig
    ) {
        switch config.level {
        case .accurate:
            request.recognitionLevel = .accurate
        case .fast:
            request.recognitionLevel = .fast
        }

        if !config.languages.isEmpty {
            request.recognitionLanguages = config.languages
        }

        request.usesLanguageCorrection = config.usesLanguageCorrection

        if config.minimumTextHeight > 0 {
            request.minimumTextHeight = config.minimumTextHeight
        }
    }

    private func extractTextResults(
        from request: VNRecognizeTextRequest,
        imageWidth: Int,
        imageHeight: Int,
        duration: TimeInterval
    ) -> VisionTextRecognitionResult {
        guard let observations = request.results else {
            return VisionTextRecognitionResult(
                fullText: "",
                lines: [],
                executionDuration: duration,
                imageSize: CGSize(width: imageWidth, height: imageHeight)
            )
        }

        var lines: [VisionRecognizedTextLine] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string
            guard !text.isEmpty else { continue }
            let confidence = topCandidate.confidence
            let boundingBox = VisionBoundingBox(normalizedRect: observation.boundingBox)
            let line = VisionRecognizedTextLine(
                id: UUID(),
                text: text,
                confidence: confidence,
                boundingBox: boundingBox
            )
            lines.append(line)
        }

        let fullText = lines.map(\.text).joined(separator: "\n")
        return VisionTextRecognitionResult(
            fullText: fullText,
            lines: lines,
            executionDuration: duration,
            imageSize: CGSize(width: imageWidth, height: imageHeight)
        )
    }

    private func extractBarcodeResults(
        from request: VNDetectBarcodesRequest,
        imageWidth: Int,
        imageHeight: Int
    ) -> [VisionBarcodeResult] {
        guard let observations = request.results else {
            return []
        }

        var results: [VisionBarcodeResult] = []
        results.reserveCapacity(observations.count)

        for observation in observations {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }
            guard let barcodeType = mapSymbologyToType(observation.symbology) else { continue }
            let confidence = observation.confidence
            let boundingBox = VisionBoundingBox(normalizedRect: observation.boundingBox)
            let barcodeResult = VisionBarcodeResult(
                id: UUID(),
                payload: payload,
                type: barcodeType,
                confidence: confidence,
                boundingBox: boundingBox
            )
            results.append(barcodeResult)
        }

        return results
    }

    private func mapTypeToSymbology(_ type: VisionBarcodeType) -> VNBarcodeSymbology {
        switch type {
        case .qr: return .qr
        case .aztec: return .aztec
        case .code128: return .code128
        case .code39: return .code39
        case .code93: return .code93
        case .dataMatrix: return .dataMatrix
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .itf14: return .itf14
        case .pdf417: return .pdf417
        case .upce: return .upce
        }
    }

    private func mapSymbologyToType(_ symbology: VNBarcodeSymbology) -> VisionBarcodeType? {
        switch symbology {
        case .qr: return .qr
        case .aztec: return .aztec
        case .code128: return .code128
        case .code39: return .code39
        case .code93: return .code93
        case .dataMatrix: return .dataMatrix
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .itf14: return .itf14
        case .pdf417: return .pdf417
        case .upce: return .upce
        default: return nil
        }
    }

    private static func durationInSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = start.duration(to: end)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - CancellationBox

/// Thread-safe helper that safely cancels non-Sendable Vision requests across cancellation closures.
private final class CancellationBox: @unchecked Sendable {
    private var requests: [VNRequest] = []
    private let lock = NSLock()

    func setRequests(_ reqs: [VNRequest]) {
        lock.lock()
        requests = reqs
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let reqs = requests
        lock.unlock()
        for req in reqs {
            req.cancel()
        }
    }
}
