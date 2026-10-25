import Foundation
import CoreGraphics

/// Public interface for optical character recognition and barcode detection in Zenith.
public protocol VisionEngineProtocol: Sendable {
    /// Recognizes text lines in the given CGImage using the provided configuration.
    func recognizeText(in image: CGImage, config: VisionTextConfig) async throws -> VisionTextRecognitionResult

    /// Detects 1D/2D barcodes in the given CGImage matching the specified symbology types.
    func detectBarcodes(in image: CGImage, types: [VisionBarcodeType]) async throws -> [VisionBarcodeResult]

    /// Performs single-pass joint text recognition and barcode detection.
    func analyze(image: CGImage, options: VisionAnalysisOptions) async throws -> VisionAnalysisResult
}

// MARK: - Convenience Overloads & Compatibility Extensions

public extension VisionEngineProtocol {
    /// Recognizes text in the given CGImage using default configuration (.accurate, system languages).
    func recognizeText(in image: CGImage) async throws -> VisionTextRecognitionResult {
        try await recognizeText(in: image, config: .default)
    }

    /// Compatibility overload accepting `configuration:` parameter name.
    func recognizeText(in image: CGImage, configuration: VisionTextConfig) async throws -> VisionTextRecognitionResult {
        try await recognizeText(in: image, config: configuration)
    }

    /// Detects QR codes in the given CGImage using default symbology (.qr).
    func detectBarcodes(in image: CGImage) async throws -> [VisionBarcodeResult] {
        try await detectBarcodes(in: image, types: [.qr])
    }

    /// Compatibility overload accepting `symbologies:` parameter name.
    func detectBarcodes(in image: CGImage, symbologies: [VisionBarcodeType]) async throws -> [VisionBarcodeResult] {
        try await detectBarcodes(in: image, types: symbologies)
    }

    /// Analyzes the given CGImage for both text and QR codes using default options.
    func analyze(image: CGImage) async throws -> VisionAnalysisResult {
        try await analyze(image: image, options: .default)
    }

    /// Performs joint analysis with explicit text config and barcode symbologies.
    func analyze(
        image: CGImage,
        textConfig: VisionTextConfig,
        barcodeSymbologies: [VisionBarcodeType]
    ) async throws -> VisionAnalysisResult {
        let options = VisionAnalysisOptions(
            recognizeText: true,
            detectBarcodes: !barcodeSymbologies.isEmpty,
            textConfig: textConfig,
            barcodeTypes: barcodeSymbologies
        )
        return try await analyze(image: image, options: options)
    }
}

/// Compatibility typealias for the Vision Engine service protocol.
public typealias VisionEngineServiceProtocol = VisionEngineProtocol

// MARK: - MockVisionEngineService

/// Thread-safe mock implementation of VisionEngineProtocol for tests, previews, and simulated workflows.
public final class MockVisionEngineService: VisionEngineProtocol, @unchecked Sendable {
    public var stubbedTextResult: VisionTextRecognitionResult?
    public var stubbedBarcodeResults: [VisionBarcodeResult] = []
    public var stubbedAnalysisResult: VisionAnalysisResult?
    public var shouldThrowError: VisionEngineError?

    private var _recognizeTextCallCount: Int = 0
    private var _detectBarcodesCallCount: Int = 0
    private var _analyzeCallCount: Int = 0
    private let lock = NSLock()

    private func incrementRecognizeTextCallCount() {
        lock.lock()
        _recognizeTextCallCount += 1
        lock.unlock()
    }

    private func incrementDetectBarcodesCallCount() {
        lock.lock()
        _detectBarcodesCallCount += 1
        lock.unlock()
    }

    private func incrementAnalyzeCallCount() {
        lock.lock()
        _analyzeCallCount += 1
        lock.unlock()
    }

    public var recognizeTextCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _recognizeTextCallCount
    }

    public var detectBarcodesCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _detectBarcodesCallCount
    }

    public var analyzeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _analyzeCallCount
    }

    public init() {}

    public func recognizeText(in image: CGImage, config: VisionTextConfig) async throws -> VisionTextRecognitionResult {
        incrementRecognizeTextCallCount()

        if let error = shouldThrowError {
            throw error
        }
        return stubbedTextResult ?? VisionTextRecognitionResult(
            fullText: "",
            lines: [],
            executionDuration: 0.001,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    public func detectBarcodes(in image: CGImage, types: [VisionBarcodeType]) async throws -> [VisionBarcodeResult] {
        incrementDetectBarcodesCallCount()

        if let error = shouldThrowError {
            throw error
        }
        return stubbedBarcodeResults
    }

    public func analyze(image: CGImage, options: VisionAnalysisOptions) async throws -> VisionAnalysisResult {
        incrementAnalyzeCallCount()

        if let error = shouldThrowError {
            throw error
        }
        return stubbedAnalysisResult ?? VisionAnalysisResult(
            textResult: stubbedTextResult ?? .empty,
            barcodes: stubbedBarcodeResults,
            executionDuration: 0.001
        )
    }
}
