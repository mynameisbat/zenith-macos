import Foundation
import CoreGraphics

/// Represents an 8-bit RGBA pixel color with hex formatting helpers.
public struct PixelColor: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Canonical uppercase RGB hex string (e.g. `#FF0000`).
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Canonical uppercase ARGB hex string (e.g. `#FFFF0000`).
    public var hexWithAlphaString: String {
        String(format: "#%02X%02X%02X%02X", alpha, red, green, blue)
    }

    public static let clear = PixelColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let white = PixelColor(red: 255, green: 255, blue: 255, alpha: 255)
    public static let black = PixelColor(red: 0, green: 0, blue: 0, alpha: 255)
}

/// Supported loupe magnification factors and corresponding sampling grid dimensions.
public enum LoupeZoomFactor: Sendable, Equatable {
    case zoom4x
    case zoom8x

    /// Number of source pixels sampled across each axis (always an odd integer).
    public var sourceGridDimension: Int {
        switch self {
        case .zoom4x: return 21
        case .zoom8x: return 15
        }
    }

    public var scaleMultiplier: CGFloat {
        switch self {
        case .zoom4x: return 4.0
        case .zoom8x: return 8.0
        }
    }
}

/// High-performance, zero-unsafe-pointer memory-safe pixel sampler for screen images.
public struct LoupePixelSampler: Sendable {

    /// Safely extracts a single pixel color at the specified coordinates.
    /// Handles fractional coordinates by rounding to nearest integer.
    /// Returns `PixelColor.clear` for out-of-bounds, NaN, or invalid coordinates.
    public static func samplePixel(in image: CGImage, at point: CGPoint) -> PixelColor {
        autoreleasepool {
            guard !point.x.isNaN, !point.y.isNaN,
                  !point.x.isInfinite, !point.y.isInfinite else {
                return .clear
            }

            let px = Int(point.x.rounded())
            let py = Int(point.y.rounded())

            guard px >= 0, px < image.width,
                  py >= 0, py < image.height else {
                return .clear
            }

            let memoryY = image.height - 1 - py

            // Fast path: direct memory buffer read for 32-bit (8 bits per component) buffers
            // Safe bounded access with strict buffer length validation
            if image.bitsPerPixel == 32, image.bitsPerComponent == 8,
               let cfData = image.dataProvider?.data,
               let bytes = CFDataGetBytePtr(cfData) {
                let totalBytes = CFDataGetLength(cfData)
                let bytesPerRow = image.bytesPerRow
                let offset = memoryY * bytesPerRow + px * 4

                if offset >= 0, offset + 4 <= totalBytes {
                    let b0 = bytes[offset]
                    let b1 = bytes[offset + 1]
                    let b2 = bytes[offset + 2]
                    let b3 = bytes[offset + 3]

                    let alphaInfo = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
                    let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue

                    var r: UInt8 = 0
                    var g: UInt8 = 0
                    var b: UInt8 = 0
                    var a: UInt8 = 255

                    let isLittle = (byteOrder == CGBitmapInfo.byteOrder32Little.rawValue)
                    let isFirst = (alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst)
                    let isLast = (alphaInfo == .premultipliedLast || alphaInfo == .last || alphaInfo == .noneSkipLast)

                    if isLittle && isFirst {
                        // Native macOS Little-Endian screen capture: [B, G, R, A] or [B, G, R, X]
                        b = b0
                        g = b1
                        r = b2
                        a = (alphaInfo == .noneSkipFirst) ? 255 : b3
                    } else if isFirst {
                        // Big-Endian or default First: [A, R, G, B] or [X, R, G, B]
                        a = (alphaInfo == .noneSkipFirst) ? 255 : b0
                        r = b1
                        g = b2
                        b = b3
                    } else {
                        // RGBA, RGBX, or fallback Last/None: [R, G, B, A]
                        r = b0
                        g = b1
                        b = b2
                        a = (isLast && alphaInfo != .noneSkipLast) ? b3 : 255
                    }

                    // Un-premultiply RGB if alpha is premultiplied and in (1...254)
                    if (alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast), a > 0, a < 255 {
                        r = UInt8(min(255, (UInt32(r) * 255 + UInt32(a) / 2) / UInt32(a)))
                        g = UInt8(min(255, (UInt32(g) * 255 + UInt32(a) / 2) / UInt32(a)))
                        b = UInt8(min(255, (UInt32(b) * 255 + UInt32(a) / 2) / UInt32(a)))
                    }

                    return PixelColor(red: r, green: g, blue: b, alpha: a)
                }
            }

            // Safe fallback: render 1x1 pixel into dedicated sRGB RGBA context
            var pixel = [UInt8](repeating: 0, count: 4)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return .clear
            }

            ctx.setBlendMode(.copy)
            guard let cropped = image.cropping(to: CGRect(x: px, y: memoryY, width: 1, height: 1)) else {
                return .clear
            }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

            var r = pixel[0]
            var g = pixel[1]
            var b = pixel[2]
            let a = pixel[3]

            if a > 0, a < 255 {
                r = UInt8(min(255, (UInt32(r) * 255 + UInt32(a) / 2) / UInt32(a)))
                g = UInt8(min(255, (UInt32(g) * 255 + UInt32(a) / 2) / UInt32(a)))
                b = UInt8(min(255, (UInt32(b) * 255 + UInt32(a) / 2) / UInt32(a)))
            }

            return PixelColor(red: r, green: g, blue: b, alpha: a)
        }
    }

    /// Samples a 2D matrix of pixel colors centered around the target coordinate.
    /// Returns a square matrix of size `zoomFactor.sourceGridDimension × zoomFactor.sourceGridDimension`.
    /// The center element `matrix[dim / 2][dim / 2]` strictly matches `samplePixel(in: image, at: center)`.
    public static func sampleGrid(
        in image: CGImage,
        center: CGPoint,
        zoomFactor: LoupeZoomFactor
    ) -> [[PixelColor]] {
        autoreleasepool {
            let dimension = zoomFactor.sourceGridDimension
            let half = dimension / 2
            var matrix: [[PixelColor]] = []
            matrix.reserveCapacity(dimension)

            let centerX = Int(center.x.rounded())
            let centerY = Int(center.y.rounded())

            // Fast path: direct memory buffer read with single dataProvider acquisition per grid
            if image.bitsPerPixel == 32, image.bitsPerComponent == 8,
               let cfData = image.dataProvider?.data,
               let bytes = CFDataGetBytePtr(cfData) {
                let totalBytes = CFDataGetLength(cfData)
                let bytesPerRow = image.bytesPerRow
                let imgWidth = image.width
                let imgHeight = image.height

                let alphaInfo = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
                let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
                let isLittle = (byteOrder == CGBitmapInfo.byteOrder32Little.rawValue)
                let isFirst = (alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst)
                let isLast = (alphaInfo == .premultipliedLast || alphaInfo == .last || alphaInfo == .noneSkipLast)
                let isPremultiplied = (alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)

                for row in 0..<dimension {
                    var rowColors: [PixelColor] = []
                    rowColors.reserveCapacity(dimension)
                    let offsetY = half - row
                    let py = centerY + offsetY

                    guard py >= 0, py < imgHeight else {
                        let clearRow = [PixelColor](repeating: .clear, count: dimension)
                        matrix.append(clearRow)
                        continue
                    }

                    let memoryY = imgHeight - 1 - py
                    let rowOffset = memoryY * bytesPerRow

                    for col in 0..<dimension {
                        let offsetX = col - half
                        let px = centerX + offsetX

                        guard px >= 0, px < imgWidth else {
                            rowColors.append(.clear)
                            continue
                        }

                        let offset = rowOffset + px * 4
                        if offset >= 0, offset + 4 <= totalBytes {
                            let b0 = bytes[offset]
                            let b1 = bytes[offset + 1]
                            let b2 = bytes[offset + 2]
                            let b3 = bytes[offset + 3]

                            var r: UInt8 = 0
                            var g: UInt8 = 0
                            var b: UInt8 = 0
                            var a: UInt8 = 255

                            if isLittle && isFirst {
                                b = b0
                                g = b1
                                r = b2
                                a = (alphaInfo == .noneSkipFirst) ? 255 : b3
                            } else if isFirst {
                                a = (alphaInfo == .noneSkipFirst) ? 255 : b0
                                r = b1
                                g = b2
                                b = b3
                            } else {
                                r = b0
                                g = b1
                                b = b2
                                a = (isLast && alphaInfo != .noneSkipLast) ? b3 : 255
                            }

                            if isPremultiplied, a > 0, a < 255 {
                                r = UInt8(min(255, (UInt32(r) * 255 + UInt32(a) / 2) / UInt32(a)))
                                g = UInt8(min(255, (UInt32(g) * 255 + UInt32(a) / 2) / UInt32(a)))
                                b = UInt8(min(255, (UInt32(b) * 255 + UInt32(a) / 2) / UInt32(a)))
                            }

                            rowColors.append(PixelColor(red: r, green: g, blue: b, alpha: a))
                        } else {
                            rowColors.append(.clear)
                        }
                    }
                    matrix.append(rowColors)
                }
                return matrix
            }

            // Fallback to per-pixel sampling for non-32-bit images
            let cX = center.x.rounded()
            let cY = center.y.rounded()
            for row in 0..<dimension {
                var rowColors: [PixelColor] = []
                rowColors.reserveCapacity(dimension)
                let offsetY = half - row
                let currentY = cY + CGFloat(offsetY)

                for col in 0..<dimension {
                    let offsetX = col - half
                    let currentX = cX + CGFloat(offsetX)

                    let color = samplePixel(in: image, at: CGPoint(x: currentX, y: currentY))
                    rowColors.append(color)
                }
                matrix.append(rowColors)
            }

            return matrix
        }
    }
}
