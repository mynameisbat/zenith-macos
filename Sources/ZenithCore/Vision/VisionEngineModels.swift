import Foundation
import CoreGraphics

// MARK: - VisionBoundingBox

/// A normalized bounding box in Apple Vision coordinate space: [0, 1] with origin at the bottom-left corner.
public struct VisionBoundingBox: Sendable, Equatable, Hashable, Codable {
    /// Normalized x-coordinate of the bottom-left origin in range [0, 1].
    public let x: CGFloat
    /// Normalized y-coordinate of the bottom-left origin in range [0, 1].
    public let y: CGFloat
    /// Normalized width in range [0, 1].
    public let width: CGFloat
    /// Normalized height in range [0, 1].
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(normalizedRect: CGRect) {
        self.x = normalizedRect.origin.x
        self.y = normalizedRect.origin.y
        self.width = normalizedRect.size.width
        self.height = normalizedRect.size.height
    }

    /// Representation as a standard CGRect in Vision's normalized coordinate space.
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Converts normalized Vision bounding box to absolute pixel coordinates with top-left origin.
    public func toPixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let w = width * CGFloat(imageWidth)
        let h = height * CGFloat(imageHeight)
        let pixelX = x * CGFloat(imageWidth)
        // Flip vertical axis from bottom-left origin to top-left origin
        let pixelY = (1.0 - y - height) * CGFloat(imageHeight)
        return CGRect(x: pixelX, y: pixelY, width: w, height: h)
    }

    /// Converts normalized Vision bounding box to AppKit / screen display points given a backing scale factor.
    public func toDisplayRect(imageWidth: Int, imageHeight: Int, scale: CGFloat) -> CGRect {
        let pixelRect = toPixelRect(imageWidth: imageWidth, imageHeight: imageHeight)
        guard scale > 0 else { return pixelRect }
        return CGRect(
            x: pixelRect.origin.x / scale,
            y: pixelRect.origin.y / scale,
            width: pixelRect.width / scale,
            height: pixelRect.height / scale
        )
    }

    public static let zero = VisionBoundingBox(x: 0, y: 0, width: 0, height: 0)
}

// MARK: - VisionTextRecognitionLevel

/// Accuracy and performance tier for text recognition requests.
public enum VisionTextRecognitionLevel: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Accurate recognition utilizing neural network models (recommended for printed text, code, and UI).
    case accurate
    /// Fast recognition utilizing character classification with lower CPU/latency overhead.
    case fast
}

// MARK: - VisionTextConfig

/// Configuration settings for optical character recognition requests.
public struct VisionTextConfig: Sendable, Equatable, Hashable, Codable {
    /// Recognition tier: .accurate (default) or .fast.
    public var level: VisionTextRecognitionLevel
    /// Language priority hints (e.g., ["en-US", "de-DE"]). An empty array uses system defaults.
    public var languages: [String]
    /// Whether language correction and dictionary matching are applied.
    public var usesLanguageCorrection: Bool
    /// Minimum text height relative to image height in range [0, 1]. Defaults to 0.0 (no filtering).
    public var minimumTextHeight: Float

    public init(
        level: VisionTextRecognitionLevel = .accurate,
        languages: [String] = [],
        usesLanguageCorrection: Bool = true,
        minimumTextHeight: Float = 0.0
    ) {
        self.level = level
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumTextHeight = minimumTextHeight
    }

    public static let `default` = VisionTextConfig()
}

/// Compatibility typealias for VisionTextConfig.
public typealias VisionTextRecognitionConfig = VisionTextConfig

// MARK: - VisionRecognizedTextLine

/// A single recognized text line with confidence score and bounding geometry.
public struct VisionRecognizedTextLine: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let text: String
    /// Confidence score in range 0.0 ... 1.0.
    public let confidence: Float
    /// Spatial bounding box in normalized Vision coordinates (bottom-left origin).
    public let boundingBox: VisionBoundingBox

    /// Compatibility property returning CGRect in normalized Vision coordinates.
    public var normalizedBoundingBox: CGRect {
        boundingBox.cgRect
    }

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        boundingBox: VisionBoundingBox
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        normalizedBoundingBox: CGRect
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = VisionBoundingBox(normalizedRect: normalizedBoundingBox)
    }

    /// Converts normalized bounding box to pixel coordinates with top-left origin.
    public func pixelBoundingBox(imageWidth: Int, imageHeight: Int) -> CGRect {
        boundingBox.toPixelRect(imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Converts normalized bounding box to AppKit / display points with top-left origin.
    public func displayBoundingBox(imageWidth: Int, imageHeight: Int, scale: CGFloat) -> CGRect {
        boundingBox.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: scale)
    }
}

// MARK: - VisionTextRecognitionResult

/// Aggregated result of a text recognition operation.
public struct VisionTextRecognitionResult: Sendable, Equatable, Codable {
    /// Full concatenated string of recognized text lines separated by newlines.
    public let fullText: String
    /// Individual recognized text lines in reading order.
    public let lines: [VisionRecognizedTextLine]
    /// Total execution duration in seconds.
    public let executionDuration: TimeInterval
    /// Dimensions of the processed source image.
    public let imageSize: CGSize

    public init(
        fullText: String,
        lines: [VisionRecognizedTextLine],
        executionDuration: TimeInterval,
        imageSize: CGSize
    ) {
        self.fullText = fullText
        self.lines = lines
        self.executionDuration = executionDuration
        self.imageSize = imageSize
    }

    public static let empty = VisionTextRecognitionResult(
        fullText: "",
        lines: [],
        executionDuration: 0,
        imageSize: .zero
    )
}

// MARK: - VisionBarcodeType

/// Supported 1D and 2D barcode symbologies.
public enum VisionBarcodeType: String, Sendable, CaseIterable, Equatable, Hashable, Codable {
    case qr
    case aztec
    case code128
    case code39
    case code93
    case dataMatrix
    case ean13
    case ean8
    case itf14
    case pdf417
    case upce
}

/// Compatibility typealias for barcode symbologies.
public typealias VisionBarcodeSymbology = VisionBarcodeType

// MARK: - VisionBarcodeResult

/// Decoded barcode or QR code payload with symbology metadata and bounding geometry.
public struct VisionBarcodeResult: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: UUID
    /// Decoded string payload (e.g. URL, text, token).
    public let payload: String
    /// Detected barcode symbology.
    public let type: VisionBarcodeType
    /// Confidence score in range 0.0 ... 1.0.
    public let confidence: Float
    /// Spatial bounding box in normalized Vision coordinates (bottom-left origin).
    public let boundingBox: VisionBoundingBox

    /// Compatibility property for symbology.
    public var symbology: VisionBarcodeType {
        type
    }

    /// Compatibility property for normalizedBoundingBox as CGRect.
    public var normalizedBoundingBox: CGRect {
        boundingBox.cgRect
    }

    public init(
        id: UUID = UUID(),
        payload: String,
        type: VisionBarcodeType,
        confidence: Float,
        boundingBox: VisionBoundingBox
    ) {
        self.id = id
        self.payload = payload
        self.type = type
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    public init(
        id: UUID = UUID(),
        payload: String,
        symbology: VisionBarcodeType,
        confidence: Float,
        normalizedBoundingBox: CGRect
    ) {
        self.id = id
        self.payload = payload
        self.type = symbology
        self.confidence = confidence
        self.boundingBox = VisionBoundingBox(normalizedRect: normalizedBoundingBox)
    }

    /// Converts normalized bounding box to pixel coordinates with top-left origin.
    public func pixelBoundingBox(imageWidth: Int, imageHeight: Int) -> CGRect {
        boundingBox.toPixelRect(imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Converts normalized bounding box to AppKit / display points with top-left origin.
    public func displayBoundingBox(imageWidth: Int, imageHeight: Int, scale: CGFloat) -> CGRect {
        boundingBox.toDisplayRect(imageWidth: imageWidth, imageHeight: imageHeight, scale: scale)
    }
}

// MARK: - VisionAnalysisOptions

/// Options for single-pass joint text recognition and barcode detection.
public struct VisionAnalysisOptions: Sendable, Equatable, Hashable, Codable {
    /// Whether optical character recognition should be performed.
    public var recognizeText: Bool
    /// Whether barcode and QR code detection should be performed.
    public var detectBarcodes: Bool
    /// Configuration for text recognition.
    public var textConfig: VisionTextConfig
    /// Barcode symbologies to detect.
    public var barcodeTypes: [VisionBarcodeType]

    public init(
        recognizeText: Bool = true,
        detectBarcodes: Bool = true,
        textConfig: VisionTextConfig = .default,
        barcodeTypes: [VisionBarcodeType] = [.qr]
    ) {
        self.recognizeText = recognizeText
        self.detectBarcodes = detectBarcodes
        self.textConfig = textConfig
        self.barcodeTypes = barcodeTypes
    }

    public static let `default` = VisionAnalysisOptions()
}

// MARK: - VisionAnalysisResult

/// Combined result of single-pass joint text recognition and barcode detection.
public struct VisionAnalysisResult: Sendable, Equatable, Codable {
    /// Text recognition result (empty if text recognition was disabled or no text found).
    public let textResult: VisionTextRecognitionResult
    /// Detected barcodes and QR codes.
    public let barcodes: [VisionBarcodeResult]
    /// Total elapsed execution duration in seconds.
    public let executionDuration: TimeInterval

    public init(
        textResult: VisionTextRecognitionResult,
        barcodes: [VisionBarcodeResult],
        executionDuration: TimeInterval
    ) {
        self.textResult = textResult
        self.barcodes = barcodes
        self.executionDuration = executionDuration
    }

    public static let empty = VisionAnalysisResult(
        textResult: .empty,
        barcodes: [],
        executionDuration: 0
    )
}
