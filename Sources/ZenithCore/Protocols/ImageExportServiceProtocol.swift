import Foundation
import CoreGraphics

/// Reversible vector drawing command applied onto a CoreGraphics rendering context.
public protocol AnnotationCommand: Sendable {
    /// Renders the annotation onto the provided CGContext.
    /// - Parameters:
    ///   - context: The CoreGraphics bitmap context.
    ///   - scale: Display backing scale factor (e.g. 2.0 for Retina displays).
    func apply(to context: CGContext, scale: CGFloat)
}

/// Service protocol for flattening vector annotations and exporting raster formats.
public protocol ImageExportServiceProtocol: Sendable {
    /// Flattens a base screenshot and an array of annotation commands into a composite CGImage.
    /// - Parameters:
    ///   - baseImage: The background screenshot bitmap.
    ///   - commands: Vector drawing commands applied in order.
    ///   - cropRect: Optional crop bounds (in points). If nil, the entire image is exported.
    /// - Returns: A composited CGImage.
    func renderAnnotatedImage(baseImage: CGImage, commands: [AnnotationCommand], cropRect: CGRect?) -> CGImage

    /// Flattens a base screenshot and an array of annotation commands into a composite CGImage with backing scale factor.
    /// - Parameters:
    ///   - baseImage: The background screenshot bitmap.
    ///   - commands: Vector drawing commands applied in order.
    ///   - cropRect: Optional crop bounds (in points). If nil, the entire image is exported.
    ///   - scale: Display backing scale factor (e.g. 2.0 for Retina displays).
    /// - Returns: A composited CGImage.
    func renderAnnotatedImage(baseImage: CGImage, commands: [AnnotationCommand], cropRect: CGRect?, scale: CGFloat) -> CGImage

    /// Encodes a CGImage to lossless PNG data.
    /// - Parameter image: Source CGImage.
    /// - Returns: Encoded PNG Data, or nil if encoding fails.
    func exportToPNG(image: CGImage) -> Data?

    /// Encodes a CGImage to lossy JPEG data.
    /// - Parameters:
    ///   - image: Source CGImage.
    ///   - quality: Compression quality from 0.0 (maximum compression) to 1.0 (lossless).
    /// - Returns: Encoded JPEG Data, or nil if encoding fails.
    func exportToJPEG(image: CGImage, quality: CGFloat) -> Data?
}

public extension ImageExportServiceProtocol {
    func renderAnnotatedImage(baseImage: CGImage, commands: [AnnotationCommand], cropRect: CGRect?) -> CGImage {
        renderAnnotatedImage(baseImage: baseImage, commands: commands, cropRect: cropRect, scale: 1.0)
    }
}
