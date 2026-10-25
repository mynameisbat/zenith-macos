import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Vision Engine Core Functional Test Suite")
struct VisionEngineTests {

    private let engine = VisionEngineService()

    // MARK: - Text Recognition Tests

    @Test("V-01: Recognizes clear high-contrast printed text accurately")
    func testAccurateTextRecognition() async throws {
        let expectedText = "ZENITH OCR ENGINE"
        let image = VisionTestImageGenerator.createTextImage(text: expectedText, fontSize: 36)

        let result = try await engine.recognizeText(in: image, config: .default)

        #expect(!result.lines.isEmpty)
        #expect(result.fullText.contains("ZENITH"))
        #expect(result.fullText.contains("OCR"))
        #expect(result.fullText.contains("ENGINE"))
        #expect(result.imageSize.width == CGFloat(image.width))
        #expect(result.imageSize.height == CGFloat(image.height))
        #expect(result.executionDuration > 0)

        for line in result.lines {
            #expect(!line.text.isEmpty)
            #expect(line.confidence > 0.0)
            #expect(line.boundingBox.width > 0.0)
            #expect(line.boundingBox.height > 0.0)
        }
    }

    @Test("V-02: Recognizes multiline text in proper reading order")
    func testMultilineTextRecognition() async throws {
        let lines = [
            "FIRST LINE ALPHA",
            "SECOND LINE BETA",
            "THIRD LINE GAMMA"
        ]
        let image = VisionTestImageGenerator.createMultiLineTextImage(lines: lines, fontSize: 26)

        let result = try await engine.recognizeText(in: image)

        #expect(result.lines.count >= 3)
        #expect(result.fullText.contains("ALPHA"))
        #expect(result.fullText.contains("BETA"))
        #expect(result.fullText.contains("GAMMA"))

        // Verify vertical order: earlier lines should have higher Y in top-left pixel space
        let pixelRects = result.lines.map { $0.pixelBoundingBox(imageWidth: image.width, imageHeight: image.height) }
        for i in 0..<(pixelRects.count - 1) {
            #expect(pixelRects[i].origin.y <= pixelRects[i + 1].origin.y)
        }
    }

    @Test("V-03: Recognizes text with fast recognition tier configuration")
    func testFastTextRecognitionLevel() async throws {
        let image = VisionTestImageGenerator.createTextImage(text: "FAST RECOGNITION TIER", fontSize: 32)
        let config = VisionTextConfig(level: .fast, usesLanguageCorrection: false)

        let result = try await engine.recognizeText(in: image, config: config)

        #expect(!result.lines.isEmpty)
        #expect(result.fullText.contains("FAST"))
    }

    @Test("V-04: Bounding box coordinate transformations (Pixel and Retina Display Rects)")
    func testBoundingBoxCoordinateTransformations() {
        // Normalized Vision bounding box: bottom-left (0.1, 0.2), width 0.4, height 0.3
        let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        let imageWidth = 1000
        let imageHeight = 500

        // In CoreGraphics top-left pixel space:
        // x = 0.1 * 1000 = 100
        // y = (1.0 - 0.2 - 0.3) * 500 = 0.5 * 500 = 250
        // width = 0.4 * 1000 = 400
        // height = 0.3 * 500 = 150
        let pixelRect = box.toPixelRect(imageWidth: imageWidth, imageHeight: imageHeight)
        #expect(pixelRect.origin.x == 100.0)
        #expect(pixelRect.origin.y == 250.0)
        #expect(pixelRect.width == 400.0)
        #expect(pixelRect.height == 150.0)

        // At 2x Retina scale:
        // x = 50, y = 125, width = 200, height = 75
        let displayRect = box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 2.0)
        #expect(displayRect.origin.x == 50.0)
        #expect(displayRect.origin.y == 125.0)
        #expect(displayRect.width == 200.0)
        #expect(displayRect.height == 75.0)

        // Zero dimension and zero scale guard
        #expect(box.toPixelRect(imageWidth: 0, imageHeight: 500) == .zero)
        #expect(box.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: 0) == pixelRect)

        // VisionRecognizedTextLine convenience methods
        let line = VisionRecognizedTextLine(
            text: "TEST LINE",
            confidence: 0.95,
            boundingBox: box
        )
        #expect(line.normalizedBoundingBox == box.cgRect)
        #expect(line.pixelBoundingBox(imageWidth: imageWidth, imageHeight: imageHeight) == pixelRect)
        #expect(line.displayBoundingBox(imageWidth: imageWidth, imageHeight: imageHeight, scale: 2.0) == displayRect)
    }

    // MARK: - Barcode & QR Detection Tests

    @Test("V-05: Detects QR code and extracts payload and symbology metadata")
    func testQRCodeDetection() async throws {
        let payload = "https://zenith.app/releases/v1.0"
        let qrImage = VisionTestImageGenerator.createQRCodeImage(payload: payload, scale: 8.0)

        let barcodes = try await engine.detectBarcodes(in: qrImage, types: [.qr])

        #expect(!barcodes.isEmpty)
        let match = barcodes.first(where: { $0.payload == payload })
        #expect(match != nil)
        #expect(match?.type == .qr)
        #expect(match?.symbology == .qr)
        #expect((match?.confidence ?? 0) > 0.5)
        #expect((match?.boundingBox.width ?? 0) > 0.0)
        #expect((match?.boundingBox.height ?? 0) > 0.0)

        // Convenience overload defaulting to .qr
        let defaultBarcodes = try await engine.detectBarcodes(in: qrImage)
        #expect(!defaultBarcodes.isEmpty)
        #expect(defaultBarcodes.contains(where: { $0.payload == payload }))
    }

    @Test("V-06: Returns empty array when no barcodes present or empty types specified")
    func testEmptyBarcodeQueries() async throws {
        let textOnlyImage = VisionTestImageGenerator.createTextImage(text: "NO BARCODES HERE", fontSize: 32)

        let noResults = try await engine.detectBarcodes(in: textOnlyImage, types: [.qr])
        #expect(noResults.isEmpty)

        // Empty barcode types returns immediately without performing request
        let qrImage = VisionTestImageGenerator.createQRCodeImage(payload: "https://zenith.app")
        let emptyTypes = try await engine.detectBarcodes(in: qrImage, types: [])
        #expect(emptyTypes.isEmpty)
    }

    // MARK: - Single-Pass Joint Analysis Tests

    @Test("V-07: Single-pass analyze detects both text and QR code simultaneously")
    func testSinglePassCompositeAnalysis() async throws {
        let expectedText = "ZENITH COMBINED SUITE"
        let expectedPayload = "https://zenith.app/workstation"
        let compositeImage = VisionTestImageGenerator.createCompositeTextAndQRImage(
            text: expectedText,
            qrPayload: expectedPayload,
            size: CGSize(width: 900, height: 400)
        )

        let result = try await engine.analyze(image: compositeImage, options: .default)

        #expect(!result.textResult.lines.isEmpty)
        #expect(result.textResult.fullText.contains("ZENITH"))
        #expect(result.textResult.fullText.contains("COMBINED"))

        #expect(!result.barcodes.isEmpty)
        let qr = result.barcodes.first(where: { $0.payload == expectedPayload })
        #expect(qr != nil)
        #expect(qr?.type == .qr)
        #expect(result.executionDuration > 0)
    }

    @Test("V-08: Selective analysis options toggle text and barcode detection")
    func testSelectiveAnalysisOptions() async throws {
        let compositeImage = VisionTestImageGenerator.createCompositeTextAndQRImage(
            text: "ISOLATED TEXT TEST",
            qrPayload: "https://zenith.app/isolated"
        )

        // Only text recognition enabled
        let textOnlyOptions = VisionAnalysisOptions(recognizeText: true, detectBarcodes: false)
        let textResult = try await engine.analyze(image: compositeImage, options: textOnlyOptions)
        #expect(!textResult.textResult.lines.isEmpty)
        #expect(textResult.barcodes.isEmpty)

        // Only barcode detection enabled
        let barcodeOnlyOptions = VisionAnalysisOptions(recognizeText: false, detectBarcodes: true, barcodeTypes: [.qr])
        let barcodeResult = try await engine.analyze(image: compositeImage, options: barcodeOnlyOptions)
        #expect(barcodeResult.textResult.lines.isEmpty)
        #expect(!barcodeResult.barcodes.isEmpty)

        // Neither enabled -> returns empty immediately
        let noneOptions = VisionAnalysisOptions(recognizeText: false, detectBarcodes: false)
        let noneResult = try await engine.analyze(image: compositeImage, options: noneOptions)
        #expect(noneResult == .empty)
    }

    // MARK: - MockVisionEngineService Verification Tests

    @Test("V-09: MockVisionEngineService stubs results and tracks call counters safely")
    func testMockVisionEngineServiceBehavior() async throws {
        let mock = MockVisionEngineService()
        let dummyImage = VisionTestImageGenerator.createDegenerate1x1Image()

        #expect(mock.recognizeTextCallCount == 0)
        #expect(mock.detectBarcodesCallCount == 0)
        #expect(mock.analyzeCallCount == 0)

        // Stub text result
        let stubbedLine = VisionRecognizedTextLine(
            text: "STUBBED LINE",
            confidence: 0.99,
            boundingBox: VisionBoundingBox(x: 0, y: 0, width: 1, height: 1)
        )
        mock.stubbedTextResult = VisionTextRecognitionResult(
            fullText: "STUBBED LINE",
            lines: [stubbedLine],
            executionDuration: 0.042,
            imageSize: CGSize(width: 100, height: 100)
        )

        let textRes = try await mock.recognizeText(in: dummyImage)
        #expect(textRes.fullText == "STUBBED LINE")
        #expect(mock.recognizeTextCallCount == 1)

        // Stub barcode result
        let stubbedBarcode = VisionBarcodeResult(
            payload: "MOCK_PAYLOAD",
            type: .qr,
            confidence: 1.0,
            boundingBox: VisionBoundingBox(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        )
        mock.stubbedBarcodeResults = [stubbedBarcode]

        let barcodeRes = try await mock.detectBarcodes(in: dummyImage)
        #expect(barcodeRes.count == 1)
        #expect(barcodeRes.first?.payload == "MOCK_PAYLOAD")
        #expect(mock.detectBarcodesCallCount == 1)

        // Stub analyze result
        let analyzeRes = try await mock.analyze(image: dummyImage)
        #expect(analyzeRes.textResult.fullText == "STUBBED LINE")
        #expect(analyzeRes.barcodes.count == 1)
        #expect(mock.analyzeCallCount == 1)

        // Mock error throwing
        mock.shouldThrowError = .cancelled
        await #expect(throws: VisionEngineError.cancelled) {
            try await mock.recognizeText(in: dummyImage)
        }
        #expect(mock.recognizeTextCallCount == 2)
    }

    // MARK: - Codable & Value Semantics Tests

    @Test("V-10: Domain models encode and decode via JSON without data loss")
    func testCodableRoundTrip() throws {
        let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let line = VisionRecognizedTextLine(
            id: UUID(),
            text: "SERIALIZATION TEST",
            confidence: 0.88,
            boundingBox: box
        )
        let textResult = VisionTextRecognitionResult(
            fullText: "SERIALIZATION TEST",
            lines: [line],
            executionDuration: 0.015,
            imageSize: CGSize(width: 800, height: 600)
        )
        let barcodeResult = VisionBarcodeResult(
            id: UUID(),
            payload: "https://zenith.app/sync",
            type: .qr,
            confidence: 0.97,
            boundingBox: box
        )
        let analysisResult = VisionAnalysisResult(
            textResult: textResult,
            barcodes: [barcodeResult],
            executionDuration: 0.030
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(analysisResult)
        let decoded = try decoder.decode(VisionAnalysisResult.self, from: data)

        #expect(decoded == analysisResult)
        #expect(decoded.textResult.fullText == "SERIALIZATION TEST")
        #expect(decoded.barcodes.first?.payload == "https://zenith.app/sync")
    }
}
