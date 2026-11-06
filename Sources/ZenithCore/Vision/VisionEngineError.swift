import Foundation

/// Errors thrown by the Vision Engine during optical character recognition or barcode detection.
public enum VisionEngineError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// The input image failed validation (e.g. non-positive dimensions, exceeds max dimensions, or nil data provider).
    case invalidImage(reason: String)
    /// The image data is corrupted or cannot be decoded into a valid bitmap buffer.
    case corruptData
    /// Recognition or detection failed during Vision processing.
    case recognitionFailed(reason: String)
    /// Processing failed during intermediate stages.
    case processingFailed(reason: String)
    /// The task was cancelled cooperatively before or during execution.
    case cancelled
    /// The concurrency limit was exceeded and the request was rejected or timed out.
    case concurrencyLimitExceeded
    /// One or more requested recognition languages are not supported by the platform.
    case unsupportedLanguage([String])

    public var errorDescription: String? {
        switch self {
        case .invalidImage(let reason):
            return String(localized: "Invalid image: \(reason)")
        case .corruptData:
            return String(localized: "Image data is corrupted or unreadable")
        case .recognitionFailed(let reason):
            return String(localized: "Vision recognition failed: \(reason)")
        case .processingFailed(let reason):
            return String(localized: "Vision processing failed: \(reason)")
        case .cancelled:
            return String(localized: "Vision operation was cancelled")
        case .concurrencyLimitExceeded:
            return String(localized: "Vision concurrency limit exceeded")
        case .unsupportedLanguage(let languages):
            return String(localized: "Unsupported recognition languages: \(languages.joined(separator: ", "))")
        }
    }

    public var failureReason: String? {
        errorDescription
    }

    public var description: String {
        errorDescription ?? "VisionEngineError"
    }
}
