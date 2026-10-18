import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// High-resolution image export engine.
/// Flattens vector annotations onto native display bitmaps without downsampling,
/// applies localized CoreImage pixelation for privacy blur, and encodes PNG/JPEG formats.
public final class ImageExportService: ImageExportServiceProtocol, @unchecked Sendable {
    public static let shared = ImageExportService()

    private let ciContext: CIContext

    public init(ciContext: CIContext? = nil) {
        if let ciContext = ciContext {
            self.ciContext = ciContext
        } else {
            // Software renderer fallback available for headless environments
            self.ciContext = CIContext(options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: NSNull()
            ])
        }
    }

    // MARK: - Annotation Rendering & Flattening

    /// Flattens vector annotations onto base image matching exact pixel dimensions and backing scale.
    public func renderAnnotatedImage(
        baseImage: CGImage,
        commands: [AnnotationCommand],
        cropRect: CGRect?,
        scale: CGFloat
    ) -> CGImage {
        autoreleasepool {
            guard baseImage.width > 0, baseImage.height > 0 else { return baseImage }

            let width = baseImage.width
            let height = baseImage.height
            let colorSpace = baseImage.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return baseImage
            }

            // Draw base screenshot bitmap at full physical resolution
            let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
            context.draw(baseImage, in: fullRect)

            // Unify coordinate space to top-left origin (matching SwiftUI Canvas)
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1.0, y: -1.0)

            // Render annotations in sequential order
            for command in commands {
                if let blurCommand = command as? BlurAnnotationCommand {
                    let stdRect = blurCommand.rect.standardized
                    let scaledRect = CGRect(
                        x: stdRect.origin.x * scale,
                        y: stdRect.origin.y * scale,
                        width: stdRect.width * scale,
                        height: stdRect.height * scale
                    )
                    let clampedRect = scaledRect.intersection(fullRect)
                    if !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 {
                        if let pixelated = applyPixellateFilter(
                            to: baseImage,
                            region: clampedRect,
                            pixelSize: blurCommand.pixelSize * scale
                        ) {
                            context.saveGState()
                            context.translateBy(x: clampedRect.origin.x, y: clampedRect.origin.y + clampedRect.height)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.draw(pixelated, in: CGRect(x: 0, y: 0, width: clampedRect.width, height: clampedRect.height))
                            context.restoreGState()
                            continue
                        }
                    }
                }
                command.apply(to: context, scale: scale)
            }

            context.restoreGState()

            guard let compositeImage = context.makeImage() else {
                return baseImage
            }

            // Apply optional cropping
            if let crop = cropRect {
                let pixelCrop = CGRect(
                    x: crop.origin.x * scale,
                    y: crop.origin.y * scale,
                    width: crop.width * scale,
                    height: crop.height * scale
                )
                let clamped = CoordinateTranslationService.clamp(rect: pixelCrop, to: fullRect)
                if clamped.width > 0, clamped.height > 0,
                   let cropped = compositeImage.cropping(to: clamped) {
                    return cropped
                }
            }

            return compositeImage
        }
    }

    /// Backward-compatible implementation conforming to ImageExportServiceProtocol (defaults to scale 1.0)
    public func renderAnnotatedImage(
        baseImage: CGImage,
        commands: [AnnotationCommand],
        cropRect: CGRect?
    ) -> CGImage {
        renderAnnotatedImage(baseImage: baseImage, commands: commands, cropRect: cropRect, scale: 1.0)
    }

    // MARK: - CoreImage Privacy Pixelation

    private func applyPixellateFilter(
        to baseImage: CGImage,
        region: CGRect,
        pixelSize: CGFloat
    ) -> CGImage? {
        autoreleasepool {
            let fullRect = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
            let clamped = region.intersection(fullRect)
            guard !clamped.isNull, clamped.width > 0, clamped.height > 0,
                  let cropped = baseImage.cropping(to: clamped) else { return nil }
            let ciImage = CIImage(cgImage: cropped)
            guard let filter = CIFilter(name: "CIPixellate") else { return nil }
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(pixelSize, forKey: kCIInputScaleKey)
            let center = CIVector(x: clamped.width / 2.0, y: clamped.height / 2.0)
            filter.setValue(center, forKey: kCIInputCenterKey)
            guard let output = filter.outputImage else { return nil }
            return ciContext.createCGImage(output, from: CGRect(origin: .zero, size: clamped.size))
        }
    }

    // MARK: - Raster Format Encoders (ImageIO)

    public func exportToPNG(image: CGImage) -> Data? {
        autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }

            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }

    public func exportToJPEG(image: CGImage, quality: CGFloat = 0.85) -> Data? {
        autoreleasepool {
            let clampedQuality = max(0.0, min(1.0, quality))
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }

            let options: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: clampedQuality
            ]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}
