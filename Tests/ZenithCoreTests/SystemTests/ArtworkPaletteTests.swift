import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ZenithCore

/// The colour taken from a cover for the Now Playing card: a pure function of the picture.
@Suite("Artwork palette")
struct ArtworkPaletteTests {
    /// An RGBA image whose pixel at (x, y) is `pixel(x, y)`, as straight (not premultiplied) 0...255 components.
    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let alpha = Double(a) / 255
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((Double(r) * alpha).rounded())
                bytes[offset + 1] = UInt8((Double(g) * alpha).rounded())
                bytes[offset + 2] = UInt8((Double(b) * alpha).rounded())
                bytes[offset + 3] = a
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    @Test("AP-01: A single-colour cover gives that colour")
    func testSolidColour() throws {
        let palette = try #require(ArtworkPalette.make(from: image(width: 64, height: 64) { _, _ in (220, 40, 60, 255) }))
        #expect(abs(palette.red - 220.0 / 255) < 0.03)
        #expect(abs(palette.green - 40.0 / 255) < 0.03)
        #expect(abs(palette.blue - 60.0 / 255) < 0.03)
    }

    @Test("AP-02: A vivid subject beats a large grey background")
    func testVividSubjectWins() throws {
        // Grey everywhere, a blue square covering a fifth of the picture.
        let cover = image(width: 100, height: 100) { x, y in
            (30..<75).contains(x) && (30..<75).contains(y) ? (20, 90, 240, 255) : (128, 128, 128, 255)
        }
        let palette = try #require(ArtworkPalette.make(from: cover))
        #expect(palette.blue > palette.red + 0.2)
        #expect(palette.blue > palette.green)
    }

    @Test("AP-03: A grey cover gives a grey, and an invisible one gives nothing")
    func testGreyAndTransparent() throws {
        let grey = try #require(ArtworkPalette.make(from: image(width: 32, height: 32) { _, _ in (100, 100, 100, 255) }))
        #expect(abs(grey.red - grey.green) < 0.02 && abs(grey.green - grey.blue) < 0.02)
        #expect(abs(grey.red - 100.0 / 255) < 0.03)

        #expect(ArtworkPalette.make(from: image(width: 32, height: 32) { _, _ in (255, 0, 0, 0) }) == nil)
    }

    @Test("AP-04: Transparent parts do not count, and the colour is not darkened by them")
    func testTransparencyIgnored() throws {
        // The left half is clear; the right half is green.
        let cover = image(width: 64, height: 64) { x, _ in x >= 32 ? (30, 200, 60, 255) : (0, 0, 0, 0) }
        let palette = try #require(ArtworkPalette.make(from: cover))
        #expect(palette.green > 0.7)
        #expect(palette.red < 0.2)
    }

    @Test("AP-05: The glow is the cover reduced to a tiny bitmap, whatever the cover's size")
    func testGlowSize() throws {
        for (width, height) in [(8, 8), (300, 300), (1000, 400)] {
            let palette = try #require(ArtworkPalette.make(from: image(width: width, height: height) { x, _ in (UInt8(x % 256), 90, 200, 255) }))
            #expect(palette.glow.width == ArtworkPalette.sampleSide)
            #expect(palette.glow.height == ArtworkPalette.sampleSide)
        }
    }

    @Test("AP-06: Encoded data (PNG) is decoded and reduced the same way; garbage gives nothing")
    func testEncodedData() throws {
        let cover = image(width: 40, height: 40) { _, _ in (240, 120, 20, 255) }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cover, nil)
        #expect(CGImageDestinationFinalize(destination))

        let palette = try #require(ArtworkPalette.make(fromEncoded: data as Data))
        #expect(palette.red > 0.85 && palette.blue < 0.2)
        #expect(ArtworkPalette.make(fromEncoded: Data([1, 2, 3, 4])) == nil)
    }
}
