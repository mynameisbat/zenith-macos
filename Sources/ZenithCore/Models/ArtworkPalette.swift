import CoreGraphics
import ImageIO
import SwiftUI

/// The colour an album cover is mostly about, and a tiny soft version of the cover for a glow behind it.
///
/// Computed once per cover (the island caches it next to the decoded picture, `IslandArtwork`): the cover is drawn
/// into a 16 × 16 bitmap, so the work is a few hundred pixels whatever the size of the artwork, and nothing here runs
/// per tick or per redraw.
public struct ArtworkPalette: @unchecked Sendable {
    /// Side of the tiny bitmap the cover is reduced to. Drawn at the size of the artwork it is a soft blur: that is
    /// the glow, with no blur filter to run.
    public static let sampleSide = 16

    /// The dominant colour, sRGB components in 0...1.
    public let red: Double
    public let green: Double
    public let blue: Double
    /// The cover reduced to `sampleSide` × `sampleSide`; scaled up with smooth interpolation it reads as a blurred copy.
    public let glow: CGImage

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// The reduction of `image`, or `nil` for an image with nothing visible in it (no size, or fully transparent).
    ///
    /// Pixels count by how colourful and bright they are, so a cover with a vivid subject on a grey background gives
    /// the subject's colour, not the grey that a plain average would. A cover with no colour at all gives its average grey.
    public static func make(from image: CGImage) -> ArtworkPalette? {
        let side = sampleSide
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data, let glow = context.makeImage() else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var sum = (r: 0.0, g: 0.0, b: 0.0), weights = 0.0
        var visible = 0.0
        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }
            // Premultiplied: divide the alpha back out.
            let r = min(1, Double(pixels[index * 4]) / 255 / alpha)
            let g = min(1, Double(pixels[index * 4 + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index * 4 + 2]) / 255 / alpha)
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            // A little weight for everything (a grey cover still has a colour), most for vivid, bright pixels.
            let weight = (0.05 + saturation * saturation) * (0.15 + high) * alpha
            sum.r += r * weight; sum.g += g * weight; sum.b += b * weight; weights += weight
            visible += alpha
        }
        guard visible > 0, weights > 0 else { return nil }
        return ArtworkPalette(
            red: sum.r / weights, green: sum.g / weights, blue: sum.b / weights, glow: glow
        )
    }

    /// For a caller that has only the encoded picture (PNG, JPEG ...): decodes it and reduces it.
    public static func make(fromEncoded data: Data) -> ArtworkPalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return make(from: image)
    }
}
