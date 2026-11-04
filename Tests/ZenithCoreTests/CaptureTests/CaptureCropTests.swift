import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Capture Crop Geometry Suite")
struct CaptureCropTests {
    private let display = CGSize(width: 1440, height: 900)

    @Test("CAP-C1: A region in points becomes the matching pixels on a Retina display")
    func testRetinaScaling() {
        let crop = NativeScreenCaptureBackend.pixelCropRect(
            for: CGRect(x: 10, y: 20, width: 100, height: 50), imageWidth: 2880, imageHeight: 1800, displaySize: display
        )
        #expect(crop == CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    @Test("CAP-C2: A region hanging over the edge is cut at the edge")
    func testClippedAtTheEdge() {
        let crop = NativeScreenCaptureBackend.pixelCropRect(
            for: CGRect(x: 1400, y: 880, width: 100, height: 100), imageWidth: 2880, imageHeight: 1800, displaySize: display
        )
        #expect(crop == CGRect(x: 2800, y: 1760, width: 80, height: 40))
    }

    @Test("CAP-C3: A region that is not on the display at all has no crop, so the capture fails instead of returning the screen")
    func testOffDisplayHasNoCrop() {
        #expect(NativeScreenCaptureBackend.pixelCropRect(
            for: CGRect(x: 2000, y: 100, width: 50, height: 50), imageWidth: 2880, imageHeight: 1800, displaySize: display
        ) == nil)
        #expect(NativeScreenCaptureBackend.pixelCropRect(
            for: CGRect(x: -300, y: -300, width: 100, height: 100), imageWidth: 2880, imageHeight: 1800, displaySize: display
        ) == nil)
    }

    @Test("CAP-C4: Fractional points are rounded outwards, so a pixel of the selection is never lost")
    func testFractionalRoundsOutwards() {
        let crop = NativeScreenCaptureBackend.pixelCropRect(
            for: CGRect(x: 10.3, y: 10.3, width: 20.2, height: 20.2), imageWidth: 1440, imageHeight: 900, displaySize: display
        )
        #expect(crop == CGRect(x: 10, y: 10, width: 21, height: 21))
    }
}

@Suite("ScreenCaptureKit Capture Size Suite")
struct CapturePixelSizeTests {
    @Test("CAP-C5: A Retina display is captured at its pixel size, not its point size")
    func testRetinaPixelSize() {
        let size = NativeScreenCaptureBackend.capturePixelSize(pointWidth: 1512, pointHeight: 982, pointPixelScale: 2)
        #expect(size.width == 3024 && size.height == 1964)
    }

    @Test("CAP-C6: A 1x display and a missing scale keep the point size; fractions round")
    func testOtherScales() {
        let plain = NativeScreenCaptureBackend.capturePixelSize(pointWidth: 1920, pointHeight: 1080, pointPixelScale: 1)
        #expect(plain.width == 1920 && plain.height == 1080)
        let unknown = NativeScreenCaptureBackend.capturePixelSize(pointWidth: 1920, pointHeight: 1080, pointPixelScale: 0)
        #expect(unknown.width == 1920 && unknown.height == 1080)
        let fractional = NativeScreenCaptureBackend.capturePixelSize(pointWidth: 1000, pointHeight: 500, pointPixelScale: 1.5)
        #expect(fractional.width == 1500 && fractional.height == 750)
    }
}
