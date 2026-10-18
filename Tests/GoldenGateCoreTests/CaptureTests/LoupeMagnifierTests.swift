import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Loupe Magnifier & Zero-Unsafe-Pointer Color Sampling Suite")
struct LoupeMagnifierTests {
    let testImage: CGImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

    @Test("LM-01: Samples pure red color from top-left quadrant")
    func testSampleRedPixel() {
        let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 50, y: 150))
        #expect(color.red == 255)
        #expect(color.green == 0)
        #expect(color.blue == 0)
        #expect(color.hexString == "#FF0000")
    }

    @Test("LM-02: Samples pure green color from top-right quadrant")
    func testSampleGreenPixel() {
        let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 150, y: 150))
        #expect(color.red == 0)
        #expect(color.green == 255)
        #expect(color.blue == 0)
        #expect(color.hexString == "#00FF00")
    }

    @Test("LM-03: Samples pure blue color from bottom-left quadrant")
    func testSampleBluePixel() {
        let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 50, y: 50))
        #expect(color.red == 0)
        #expect(color.green == 0)
        #expect(color.blue == 255)
        #expect(color.hexString == "#0000FF")
    }

    @Test("LM-04: Samples known white and black values")
    func testWhiteAndBlackConstants() {
        #expect(PixelColor.white.hexString == "#FFFFFF")
        #expect(PixelColor.black.hexString == "#000000")
    }

    @Test("LM-05: Sampling negative coordinates returns safe clear fallback without crash")
    func testNegativeCoordinateSampling() {
        let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: -10, y: -20))
        #expect(color == .clear)
    }

    @Test("LM-06: Sampling out-of-bounds positive coordinates returns clear fallback")
    func testOutOfBoundsPositiveSampling() {
        let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 250, y: 300))
        #expect(color == .clear)
    }

    @Test("LM-07: Exact boundary pixel coordinates sample safely")
    func testExactBoundaryCoordinates() {
        let originColor = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 0, y: 0))
        #expect(originColor == PixelColor(red: 0, green: 0, blue: 255, alpha: 255)) // Blue

        let edgeColor = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 199, y: 199))
        #expect(edgeColor == PixelColor(red: 0, green: 255, blue: 0, alpha: 255)) // Green
    }

    @Test("LM-08: Hex string formatting produces uppercase 6-digit hex")
    func testHexStringFormatting() {
        let red = PixelColor(red: 255, green: 0, blue: 0)
        #expect(red.hexString == "#FF0000")
        let green = PixelColor(red: 0, green: 255, blue: 0)
        #expect(green.hexString == "#00FF00")
        let blue = PixelColor(red: 0, green: 0, blue: 255)
        #expect(blue.hexString == "#0000FF")
    }

    @Test("LM-09: Hex string formatting for custom RGB values")
    func testCustomHexFormatting() {
        let custom = PixelColor(red: 18, green: 52, blue: 86)
        #expect(custom.hexString == "#123456")
    }

    @Test("LM-10: Hex string formatting including alpha channel")
    func testHexWithAlphaFormatting() {
        let withAlpha = PixelColor(red: 18, green: 52, blue: 86, alpha: 128)
        #expect(withAlpha.hexWithAlphaString == "#80123456")
    }

    @Test("LM-11: 4x zoom grid generates odd 21x21 matrix with identifiable center pixel")
    func testZoom4xGridDimensions() {
        let matrix = LoupePixelSampler.sampleGrid(in: testImage, center: CGPoint(x: 50, y: 50), zoomFactor: .zoom4x)
        #expect(matrix.count == 21)
        #expect(matrix.first?.count == 21)
    }

    @Test("LM-12: 8x zoom grid generates odd 15x15 matrix")
    func testZoom8xGridDimensions() {
        let matrix = LoupePixelSampler.sampleGrid(in: testImage, center: CGPoint(x: 50, y: 50), zoomFactor: .zoom8x)
        #expect(matrix.count == 15)
        #expect(matrix.first?.count == 15)
    }

    @Test("LM-13: Center pixel index identification matches dimension / 2")
    func testCenterPixelIndices() {
        #expect(LoupeZoomFactor.zoom4x.sourceGridDimension / 2 == 10)
        #expect(LoupeZoomFactor.zoom8x.sourceGridDimension / 2 == 7)
    }

    @Test("LM-14: Center pixel color in sampled grid strictly matches direct sample")
    func testCenterPixelColorInvariance() {
        let centerPoint = CGPoint(x: 50, y: 50)
        let matrix = LoupePixelSampler.sampleGrid(in: testImage, center: centerPoint, zoomFactor: .zoom4x)
        let centerPixel = matrix[10][10]
        let directSample = LoupePixelSampler.samplePixel(in: testImage, at: centerPoint)
        #expect(centerPixel == directSample)
    }

    @Test("LM-15: Fractional coordinate sampling rounds to nearest integer")
    func testFractionalCoordinateSampling() {
        // Point (10.4, 20.6) rounds to (10, 21)
        let directSample = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 10.4, y: 20.6))
        let integerSample = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: 10, y: 21))
        #expect(directSample == integerSample)
    }

    @Test("LM-16: Torture test: 1000 random out-of-bounds queries execute safely without crashing")
    func testTortureOutOfBoundsQueries() {
        for i in 1...1000 {
            let randomX = CGFloat((i * 997) % 200_000 - 100_000)
            let randomY = CGFloat((i * 991) % 200_000 - 100_000)
            let color = LoupePixelSampler.samplePixel(in: testImage, at: CGPoint(x: randomX, y: randomY))
            #expect(color == .clear)
        }
    }
}
