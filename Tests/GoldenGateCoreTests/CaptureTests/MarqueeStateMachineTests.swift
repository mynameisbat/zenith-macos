import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("Marquee Selection State Machine & Dimension Badge Suite")
struct MarqueeStateMachineTests {

    @Test("MS-01: Initial state of marquee engine is idle with zero rect")
    func testInitialStateIsIdle() {
        let engine = MarqueeSelectionEngine()
        #expect(engine.state == .idle)
        #expect(engine.isDragging == false)
        #expect(engine.normalizedRect == .zero)
    }

    @Test("MS-02: Beginning drag transitions to dragging state")
    func testBeginDragTransitions() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 100, y: 100))
        #expect(engine.isDragging == true)
        #expect(engine.normalizedRect == .zero)
    }

    @Test("MS-03: Quadrant 1 Normalization (Down-Right drag)")
    func testQuadrant1Normalization() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 100, y: 100))
        engine.updateDrag(to: CGPoint(x: 300, y: 250))
        #expect(engine.normalizedRect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("MS-04: Quadrant 2 Normalization (Up-Right drag)")
    func testQuadrant2Normalization() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 100, y: 250))
        engine.updateDrag(to: CGPoint(x: 300, y: 100))
        #expect(engine.normalizedRect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("MS-05: Quadrant 3 Normalization (Up-Left drag)")
    func testQuadrant3Normalization() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 300, y: 250))
        engine.updateDrag(to: CGPoint(x: 100, y: 100))
        #expect(engine.normalizedRect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("MS-06: Quadrant 4 Normalization (Down-Left drag)")
    func testQuadrant4Normalization() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 300, y: 100))
        engine.updateDrag(to: CGPoint(x: 100, y: 250))
        #expect(engine.normalizedRect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test("MS-07: Quadrant Invariance: All 4 diagonal drags produce identical positive rect")
    func testQuadrantNormalizationInvariance() {
        let engine1 = MarqueeSelectionEngine()
        let engine2 = MarqueeSelectionEngine()
        let engine3 = MarqueeSelectionEngine()
        let engine4 = MarqueeSelectionEngine()

        // Q1: Down-Right
        engine1.beginDrag(at: CGPoint(x: 100, y: 100))
        engine1.updateDrag(to: CGPoint(x: 300, y: 250))

        // Q2: Up-Right
        engine2.beginDrag(at: CGPoint(x: 100, y: 250))
        engine2.updateDrag(to: CGPoint(x: 300, y: 100))

        // Q3: Up-Left
        engine3.beginDrag(at: CGPoint(x: 300, y: 250))
        engine3.updateDrag(to: CGPoint(x: 100, y: 100))

        // Q4: Down-Left
        engine4.beginDrag(at: CGPoint(x: 300, y: 100))
        engine4.updateDrag(to: CGPoint(x: 100, y: 250))

        let expected = CGRect(x: 100, y: 100, width: 200, height: 150)
        #expect(engine1.normalizedRect == expected)
        #expect(engine2.normalizedRect == expected)
        #expect(engine3.normalizedRect == expected)
        #expect(engine4.normalizedRect == expected)
    }

    @Test("MS-08: Containment Invariant: Start and current points are contained within/on bounds")
    func testContainmentInvariant() {
        let start = CGPoint(x: 120, y: 80)
        let current = CGPoint(x: 450, y: 320)
        let rect = MarqueeGeometry.normalizeRect(from: start, to: current)
        #expect(start.x >= rect.minX && start.x <= rect.maxX)
        #expect(start.y >= rect.minY && start.y <= rect.maxY)
        #expect(current.x >= rect.minX && current.x <= rect.maxX)
        #expect(current.y >= rect.minY && current.y <= rect.maxY)
    }

    @Test("MS-09: End drag above threshold transitions to selected state")
    func testEndDragAboveThreshold() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 100, y: 100))
        engine.updateDrag(to: CGPoint(x: 300, y: 250))
        let result = engine.endDrag(minimumDimension: 4.0)

        let expected = CGRect(x: 100, y: 100, width: 200, height: 150)
        #expect(result == expected)
        #expect(engine.state == .selected(rect: expected))
    }

    @Test("MS-10: Sub-threshold micro-click is rejected and resets to idle")
    func testMicroClickRejection() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 100, y: 100))
        engine.updateDrag(to: CGPoint(x: 102, y: 101)) // only 2x1 points
        let result = engine.endDrag(minimumDimension: 4.0)

        #expect(result == nil)
        #expect(engine.state == .idle)
    }

    @Test("MS-11: Escape dismiss from idle transitions to dismissed")
    func testEscapeFromIdle() {
        let engine = MarqueeSelectionEngine()
        let consumed = engine.handleEscapeKey()
        #expect(consumed == true)
        #expect(engine.state == .dismissed)
    }

    @Test("MS-12: Escape key during active drag cancels selection and dismisses overlay")
    func testEscapeCancelsActiveDrag() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 50, y: 50))
        engine.updateDrag(to: CGPoint(x: 200, y: 200))
        #expect(engine.isDragging == true)

        let consumed = engine.handleEscapeKey()
        #expect(consumed == true)
        #expect(engine.state == .dismissed)
        #expect(engine.normalizedRect == .zero)
    }

    @Test("MS-13: Escape dismiss from selected state clears selection")
    func testEscapeFromSelected() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 10, y: 10))
        engine.updateDrag(to: CGPoint(x: 100, y: 100))
        _ = engine.endDrag()

        let consumed = engine.handleEscapeKey()
        #expect(consumed == true)
        #expect(engine.state == .dismissed)
    }

    @Test("MS-14: Dimension badge text formatting on 1x standard display")
    func testDimensionBadgeText1x() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let (pts, pxs, full) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: 1.0)
        #expect(pts == "400 × 300 pt")
        #expect(pxs == "(400 × 300 px)")
        #expect(full == "400 × 300 pt (400 × 300 px)")
    }

    @Test("MS-15: Dimension badge text formatting on 2x Retina display")
    func testDimensionBadgeText2x() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let (pts, pxs, full) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: 2.0)
        #expect(pts == "400 × 300 pt")
        #expect(pxs == "(800 × 600 px)")
        #expect(full == "400 × 300 pt (800 × 600 px)")
    }

    @Test("MS-16: Dimension badge flips above marquee when near bottom edge")
    func testDimensionBadgeFlipsNearBottom() {
        let selectionRect = CGRect(x: 100, y: 5, width: 200, height: 200)
        let badgeSize = CGSize(width: 100, height: 30)
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let pos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: selectionRect,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: 8
        )

        // y should be flipped above: selectionRect.maxY + 8 = 205 + 8 = 213
        #expect(pos.y == 213)
    }
}
