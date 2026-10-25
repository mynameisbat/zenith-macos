import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("PanelPositioner Multi-Display Geometry & Clamping Suite")
struct PanelPositionerTests {

    let standardScreen = NSRect(x: 0, y: 25, width: 1920, height: 1055)
    let defaultPanelSize = CGSize(width: 420, height: 520)

    @Test("Calculates screenCenter positioning relative to visibleFrame")
    func testScreenCenterPositioning() {
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: CGPoint(x: 500, y: 500),
            panelSize: defaultPanelSize,
            mode: .screenCenter,
            visibleFrame: standardScreen
        )

        #expect(frame.width == 420)
        #expect(frame.height == 520)
        let expectedX = standardScreen.midX - 420 / 2
        let expectedY = standardScreen.midY - 520 / 2 + 30
        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.y == expectedY)
    }

    @Test("Calculates nearMouse positioning with standard offset")
    func testNearMouseDefaultPlacement() {
        let mouseLocation = CGPoint(x: 500, y: 800)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: standardScreen
        )

        let expectedX = mouseLocation.x - 24
        let expectedY = mouseLocation.y - defaultPanelSize.height - 12
        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.y == expectedY)
    }

    @Test("Clamps panel against right screen border")
    func testClampingAgainstRightScreenBorder() {
        let mouseLocation = CGPoint(x: 1910, y: 800)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: standardScreen
        )

        let maxAllowedX = standardScreen.maxX - PanelPositioner.margin
        #expect(frame.maxX <= maxAllowedX)
        #expect(frame.origin.x == maxAllowedX - defaultPanelSize.width)
    }

    @Test("Clamps panel against left screen border")
    func testClampingAgainstLeftScreenBorder() {
        let mouseLocation = CGPoint(x: 10, y: 800)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: standardScreen
        )

        let minAllowedX = standardScreen.minX + PanelPositioner.margin
        #expect(frame.minX >= minAllowedX)
    }

    @Test("Flips panel above cursor when mouse is near screen bottom")
    func testClampingNearBottomFlipsAboveCursor() {
        let mouseLocation = CGPoint(x: 500, y: 40)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: standardScreen
        )

        #expect(frame.minY >= standardScreen.minY + PanelPositioner.margin)
        #expect(frame.origin.y == mouseLocation.y + 16)
    }

    @Test("Clamps panel against top screen border")
    func testClampingAgainstTopScreenBorder() {
        let mouseLocation = CGPoint(x: 500, y: 1070)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: standardScreen
        )

        let maxAllowedY = standardScreen.maxY - PanelPositioner.margin
        #expect(frame.maxY <= maxAllowedY)
    }

    @Test("Handles secondary display with negative coordinate space")
    func testSecondaryDisplayNegativeCoordinates() {
        let secondaryScreen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let mouseLocation = CGPoint(x: -960, y: 600)
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: mouseLocation,
            panelSize: defaultPanelSize,
            mode: .nearMouse,
            visibleFrame: secondaryScreen
        )

        #expect(frame.minX >= secondaryScreen.minX + PanelPositioner.margin)
        #expect(frame.maxX <= secondaryScreen.maxX - PanelPositioner.margin)
        #expect(frame.minY >= secondaryScreen.minY + PanelPositioner.margin)
        #expect(frame.maxY <= secondaryScreen.maxY - PanelPositioner.margin)
    }
}
