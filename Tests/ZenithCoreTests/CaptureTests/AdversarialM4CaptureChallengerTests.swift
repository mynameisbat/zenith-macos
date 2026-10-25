import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Adversarial M4 Screen Capture, Geometry & Multi-Display Challenger Suite")
struct AdversarialM4CaptureChallengerTests {

    // MARK: - 1. Extreme Multi-Display Topologies (Negative X, Negative Y, Positive Y, Diagonals)

    @Test("ADV-M4-01: Secondary display to the LEFT with negative X coordinates")
    func testLeftDisplayNegativeXTopology() {
        let primaryHeight: CGFloat = 1080
        let leftDisplay = CGRect(x: -2560, y: 0, width: 2560, height: 1440)

        // Point inside left display
        let pointAppKit = CGPoint(x: -1280, y: 720)
        let pointCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(pointCG.x == -1280)
        #expect(pointCG.y == primaryHeight - 720) // 360

        // Involutive round-trip
        let restoredPoint = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            point: pointCG,
            primaryScreenHeight: primaryHeight
        )
        #expect(restoredPoint == pointAppKit)

        // Rect inside left display
        let rectAppKit = CGRect(x: -2000, y: 300, width: 800, height: 600)
        let rectCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            rect: rectAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(rectCG.origin.x == -2000)
        #expect(rectCG.origin.y == primaryHeight - (300 + 600)) // 1080 - 900 = 180
        #expect(rectCG.width == 800)
        #expect(rectCG.height == 600)

        let restoredRect = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            rect: rectCG,
            primaryScreenHeight: primaryHeight
        )
        #expect(restoredRect == rectAppKit)

        // Display-local coordinate translation
        let localRect = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: rectAppKit,
            displayFrame: leftDisplay,
            primaryScreenHeight: primaryHeight
        )
        #expect(localRect.origin.x == 560.0)
        #expect(localRect.width == 800.0)
        #expect(localRect.height == 600.0)
    }

    @Test("ADV-M4-02: Secondary display BELOW primary with negative Y coordinates")
    func testBelowDisplayNegativeYTopology() {
        let primaryHeight: CGFloat = 1080
        let belowDisplay = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

        // Point inside below display
        let pointAppKit = CGPoint(x: 500, y: -500)
        let pointCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(pointCG.x == 500)
        #expect(pointCG.y == primaryHeight - (-500)) // 1580

        let restoredPoint = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            point: pointCG,
            primaryScreenHeight: primaryHeight
        )
        #expect(restoredPoint == pointAppKit)

        // Rect inside below display
        let rectAppKit = CGRect(x: 200, y: -800, width: 600, height: 400)
        let rectCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            rect: rectAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(rectCG.origin.x == 200)
        #expect(rectCG.origin.y == primaryHeight - (-800 + 400)) // 1080 - (-400) = 1480
        #expect(rectCG.width == 600)
        #expect(rectCG.height == 400)

        let localRect = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: rectAppKit,
            displayFrame: belowDisplay,
            primaryScreenHeight: primaryHeight
        )
        #expect(localRect.origin.x == 200)
        // In belowDisplay (top is y=0 in AppKit): rect top is -400. Distance from display top (0) is 400.
        #expect(localRect.origin.y == 400)
        #expect(localRect.width == 600)
        #expect(localRect.height == 400)
    }

    @Test("ADV-M4-03: Secondary display ABOVE primary (Y > primaryScreenHeight)")
    func testAboveDisplayPositiveYTopology() {
        let primaryHeight: CGFloat = 1080
        let aboveDisplay = CGRect(x: 0, y: 1080, width: 2560, height: 1440)

        let pointAppKit = CGPoint(x: 400, y: 2000)
        let pointCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: pointAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(pointCG.x == 400.0)
        #expect(pointCG.y == -920.0)

        let restoredPoint = CoordinateTranslationService.flipCoreGraphicsToAppKit(
            point: pointCG,
            primaryScreenHeight: primaryHeight
        )
        #expect(restoredPoint == pointAppKit)

        let rectAppKit = CGRect(x: 100, y: 1200, width: 500, height: 800)
        let rectCG = CoordinateTranslationService.flipAppKitToCoreGraphics(
            rect: rectAppKit,
            primaryScreenHeight: primaryHeight
        )
        #expect(rectCG.origin.x == 100.0)
        #expect(rectCG.origin.y == -920.0)
        #expect(rectCG.width == 500.0)
        #expect(rectCG.height == 800.0)

        let localRect = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
            rect: rectAppKit,
            displayFrame: aboveDisplay,
            primaryScreenHeight: primaryHeight
        )
        #expect(localRect.origin.x == 100)
        // aboveDisplay max Y in AppKit is 1080 + 1440 = 2520.
        // rectAppKit max Y is 1200 + 800 = 2000.
        // Local CG origin Y from top of display: 2520 - 2000 = 520.
        #expect(localRect.origin.y == 520)
        #expect(localRect.width == 500)
        #expect(localRect.height == 800)
    }

    @Test("ADV-M4-04: 3x3 Multi-Monitor Grid spanning all 9 quadrants")
    func test3x3MultiMonitorMatrixTopology() {
        let primaryH: CGFloat = 1080
        let screenW: CGFloat = 1920
        let screenH: CGFloat = 1080

        // 3x3 layout of monitors: row -1 (bottom), 0 (center/primary), 1 (top); col -1 (left), 0 (center), 1 (right)
        for row in -1...1 {
            for col in -1...1 {
                let displayFrame = CGRect(
                    x: CGFloat(col) * screenW,
                    y: CGFloat(row) * screenH,
                    width: screenW,
                    height: screenH
                )

                // Pick test rect centered in each display
                let testRect = CGRect(
                    x: displayFrame.minX + 200,
                    y: displayFrame.minY + 150,
                    width: 400,
                    height: 300
                )

                let cgRect = CoordinateTranslationService.flipAppKitToCoreGraphics(
                    rect: testRect,
                    primaryScreenHeight: primaryH
                )
                let roundTrip = CoordinateTranslationService.flipCoreGraphicsToAppKit(
                    rect: cgRect,
                    primaryScreenHeight: primaryH
                )

                #expect(roundTrip == testRect)

                let local = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
                    rect: testRect,
                    displayFrame: displayFrame,
                    primaryScreenHeight: primaryH
                )

                #expect(local.width == 400)
                #expect(local.height == 300)
                #expect(local.origin.x == 200)
                // In display local, top of test rect is (displayFrame.minY + 150 + 300) = minY + 450.
                // Distance from top of display (displayFrame.maxY = minY + 1080) is 1080 - 450 = 630.
                #expect(local.origin.y == 630)
            }
        }
    }

    @Test("ADV-M4-05: Mixed Retina scale factors (1.0x, 1.25x, 1.5x, 2.0x, 3.0x)")
    func testMixedRetinaScaleFactors() {
        let scales: [CGFloat] = [1.0, 1.25, 1.5, 2.0, 3.0]
        let baseRect = CGRect(x: 100, y: 200, width: 300, height: 150)

        for scale in scales {
            let pxRect = CoordinateTranslationService.pointsToPhysicalPixels(rect: baseRect, scale: scale)
            #expect(pxRect.origin.x == baseRect.origin.x * scale)
            #expect(pxRect.origin.y == baseRect.origin.y * scale)
            #expect(pxRect.width == baseRect.width * scale)
            #expect(pxRect.height == baseRect.height * scale)

            let restoredRect = CoordinateTranslationService.physicalPixelsToPoints(rect: pxRect, scale: scale)
            #expect(abs(restoredRect.origin.x - baseRect.origin.x) < 0.0001)
            #expect(abs(restoredRect.origin.y - baseRect.origin.y) < 0.0001)
            #expect(abs(restoredRect.width - baseRect.width) < 0.0001)
            #expect(abs(restoredRect.height - baseRect.height) < 0.0001)
        }
    }

    @Test("ADV-M4-06: Zero and negative scale factors are safely handled without crash or division by zero")
    func testDegenerateScaleFactors() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let point = CGPoint(x: 5, y: 15)

        // Scale <= 0 should safely return unchanged rect/point without fatalError
        let zeroScaledRect = CoordinateTranslationService.physicalPixelsToPoints(rect: rect, scale: 0)
        #expect(zeroScaledRect == rect)

        let negScaledRect = CoordinateTranslationService.physicalPixelsToPoints(rect: rect, scale: -2.0)
        #expect(negScaledRect == rect)

        let zeroScaledPoint = CoordinateTranslationService.physicalPixelsToPoints(point: point, scale: 0)
        #expect(zeroScaledPoint == point)

        let negScaledPoint = CoordinateTranslationService.physicalPixelsToPoints(point: point, scale: -1.0)
        #expect(negScaledPoint == point)
    }

    @Test("ADV-M4-07: Extreme screen heights: 480p, 1440p, 4K (2160p), 8K (4320p), 16K (8640p)")
    func testExtremeScreenHeights() {
        let extremeHeights: [CGFloat] = [480, 720, 1080, 1440, 2160, 4320, 8640, 14400]

        for h in extremeHeights {
            let point = CGPoint(x: 123.45, y: 67.89)
            let flipped = CoordinateTranslationService.flipAppKitToCoreGraphics(point: point, primaryScreenHeight: h)
            #expect(flipped.y == h - 67.89)

            let restored = CoordinateTranslationService.flipCoreGraphicsToAppKit(point: flipped, primaryScreenHeight: h)
            #expect(abs(restored.x - point.x) < 0.0001)
            #expect(abs(restored.y - point.y) < 0.0001)
        }
    }

    // MARK: - 2. Degenerate Marquee Drag Gestures

    @Test("ADV-M4-08: Zero-area stationary clicks are immediately rejected")
    func testZeroAreaStationaryClick() {
        let engine = MarqueeSelectionEngine()
        let clickPoint = CGPoint(x: 500, y: 500)

        engine.beginDrag(at: clickPoint)
        #expect(engine.isDragging == true)
        #expect(engine.normalizedRect == .zero)

        // End drag without moving
        let result = engine.endDrag(minimumDimension: 4.0)
        #expect(result == nil)
        #expect(engine.state == .idle)
        #expect(engine.isDragging == false)
        #expect(engine.normalizedRect == .zero)
    }

    @Test("ADV-M4-09: Sub-pixel and micro-movements below minimumDimension are rejected")
    func testSubPixelMovementsRejected() {
        let microDeltas: [(CGFloat, CGFloat)] = [
            (0.1, 0.1),
            (0.5, 0.5),
            (1.0, 1.0),
            (2.5, 3.8),
            (3.99, 3.99),
            (0.0, 3.99),
            (3.99, 0.0),
            (50.0, 3.99), // Asymmetric: wide but too thin vertically
            (3.99, 50.0)  // Asymmetric: tall but too thin horizontally
        ]

        for (dx, dy) in microDeltas {
            let engine = MarqueeSelectionEngine()
            engine.beginDrag(at: CGPoint(x: 100, y: 100))
            engine.updateDrag(to: CGPoint(x: 100 + dx, y: 100 + dy))

            let result = engine.endDrag(minimumDimension: 4.0)
            #expect(result == nil)
            #expect(engine.state == .idle)
        }
    }

    @Test("ADV-M4-10: Exact threshold boundary: 3.999 pt is rejected, 4.000 pt is accepted")
    func testExactThresholdBoundary() {
        let engineReject = MarqueeSelectionEngine()
        engineReject.beginDrag(at: CGPoint(x: 100, y: 100))
        engineReject.updateDrag(to: CGPoint(x: 103.999, y: 104.0))
        #expect(engineReject.endDrag(minimumDimension: 4.0) == nil)

        let engineAccept = MarqueeSelectionEngine()
        engineAccept.beginDrag(at: CGPoint(x: 100, y: 100))
        engineAccept.updateDrag(to: CGPoint(x: 104.0, y: 104.0))
        let accepted = engineAccept.endDrag(minimumDimension: 4.0)
        #expect(accepted != nil)
        #expect(accepted?.width == 4.0)
        #expect(accepted?.height == 4.0)
        #expect(engineAccept.state == .selected(rect: CGRect(x: 100, y: 100, width: 4, height: 4)))
    }

    @Test("ADV-M4-11: Reverse drag gestures across all 4 quadrants generate identical normalized rects")
    func testReverseDragAllQuadrants() {
        let pA = CGPoint(x: -500, y: -200)
        let pB = CGPoint(x: 300, y: 400)

        // Forward: A -> B
        let engine1 = MarqueeSelectionEngine()
        engine1.beginDrag(at: pA)
        engine1.updateDrag(to: pB)
        let rect1 = engine1.normalizedRect

        // Reverse: B -> A
        let engine2 = MarqueeSelectionEngine()
        engine2.beginDrag(at: pB)
        engine2.updateDrag(to: pA)
        let rect2 = engine2.normalizedRect

        #expect(rect1 == rect2)
        #expect(rect1.origin.x == -500)
        #expect(rect1.origin.y == -200)
        #expect(rect1.width == 800)
        #expect(rect1.height == 600)
    }

    @Test("ADV-M4-12: Dynamic direction reversals during continuous drag update properly")
    func testDynamicDirectionReversalsMidDrag() {
        let engine = MarqueeSelectionEngine()
        engine.beginDrag(at: CGPoint(x: 200, y: 200))

        // Drag down-right
        engine.updateDrag(to: CGPoint(x: 400, y: 350))
        #expect(engine.normalizedRect == CGRect(x: 200, y: 200, width: 200, height: 150))

        // Reverse to up-left
        engine.updateDrag(to: CGPoint(x: 50, y: 80))
        #expect(engine.normalizedRect == CGRect(x: 50, y: 80, width: 150, height: 120))

        // Return back to start
        engine.updateDrag(to: CGPoint(x: 200, y: 200))
        #expect(engine.normalizedRect == .zero)

        // Drag into negative coordinate space
        engine.updateDrag(to: CGPoint(x: -100, y: -50))
        #expect(engine.normalizedRect == CGRect(x: -100, y: -50, width: 300, height: 250))
    }

    @Test("ADV-M4-13: Marquee drag spanning multiple screen boundaries partitions cleanly")
    func testMarqueeSpanningScreenBoundaries() {
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let primaryScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rightScreen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

        // Huge selection spanning from left screen through primary to right screen
        let spanningSelection = CGRect(x: -500, y: 200, width: 2600, height: 400) // from -500 to 2100

        let leftIntersection = MarqueeGeometry.intersectScreen(rect: spanningSelection, screenFrame: leftScreen)
        let primaryIntersection = MarqueeGeometry.intersectScreen(rect: spanningSelection, screenFrame: primaryScreen)
        let rightIntersection = MarqueeGeometry.intersectScreen(rect: spanningSelection, screenFrame: rightScreen)

        #expect(leftIntersection != nil)
        #expect(primaryIntersection != nil)
        #expect(rightIntersection != nil)

        // Left portion: x: -500 to 0, width = 500
        #expect(leftIntersection == CGRect(x: -500, y: 200, width: 500, height: 400))
        // Primary portion: x: 0 to 1920, width = 1920
        #expect(primaryIntersection == CGRect(x: 0, y: 200, width: 1920, height: 400))
        // Right portion: x: 1920 to 2100, width = 180
        #expect(rightIntersection == CGRect(x: 1920, y: 200, width: 180, height: 400))

        // Area conservation: 500*400 + 1920*400 + 180*400 = 2600 * 400
        let totalArea = (leftIntersection!.width + primaryIntersection!.width + rightIntersection!.width) * 400
        #expect(totalArea == spanningSelection.width * spanningSelection.height)

        // Screen completely outside drag rect returns nil
        let topScreen = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let topIntersection = MarqueeGeometry.intersectScreen(rect: spanningSelection, screenFrame: topScreen)
        #expect(topIntersection == nil)
    }

    // MARK: - 3. Dimension Badge Calculations & Clamping Under Extreme Geometries

    @Test("ADV-M4-14: Dimension badge positioning on secondary display with negative screen bounds")
    func testBadgePositioningNegativeScreenBounds() {
        let screenBounds = CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
        let badgeSize = CGSize(width: 220, height: 28)
        let margin: CGFloat = 8

        // Selection in center of negative screen
        let selection = CGRect(x: -1500, y: -800, width: 400, height: 300)
        let pos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: selection,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: margin
        )

        // X centered: -1500 + 200 - 110 = -1410
        #expect(pos.x == -1410)
        // Y below: -800 - 28 - 8 = -836
        #expect(pos.y == -836)
        #expect(pos.y >= screenBounds.minY + margin)
    }

    @Test("ADV-M4-15: Dimension badge flips above selection when bottom edge space is insufficient")
    func testBadgeFlipsAboveNearBottomEdge() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let badgeSize = CGSize(width: 220, height: 28)
        let margin: CGFloat = 8

        // Selection touching bottom edge (minY = 5)
        let selection = CGRect(x: 500, y: 5, width: 300, height: 200)
        let pos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: selection,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: margin
        )

        // Below space: 5 - 28 - 8 = -31 < 8 -> flips above: maxY + margin = 205 + 8 = 213
        #expect(pos.y == 213.0)
        #expect(pos.x == 540.0)
    }

    @Test("ADV-M4-16: Dimension badge falls back to inside selection when both bottom and top margins exceed screen")
    func testBadgeFallbackInsideFullScreenSelection() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let badgeSize = CGSize(width: 220, height: 28)
        let margin: CGFloat = 8

        // Selection covers entire screen
        let fullSelection = screenBounds
        let pos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: fullSelection,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: margin
        )

        // Y: below is -36 (< 8), flipped above is 1088 (> 1072 - 28).
        // Fallback: selection.minY + margin = 0 + 8 = 8.
        #expect(pos.y == 8.0)
        #expect(pos.x == 850.0)
    }

    @Test("ADV-M4-17: Dimension badge horizontal clamping at extreme left and right borders")
    func testBadgeHorizontalClampingEdges() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let badgeSize = CGSize(width: 220, height: 28)
        let margin: CGFloat = 8

        // Extreme left selection
        let leftSel = CGRect(x: 0, y: 400, width: 50, height: 100)
        let leftPos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: leftSel,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: margin
        )
        #expect(leftPos.x == margin) // Clamped to 8

        // Extreme right selection
        let rightSel = CGRect(x: 1880, y: 400, width: 40, height: 100)
        let rightPos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: rightSel,
            badgeSize: badgeSize,
            screenBounds: screenBounds,
            margin: margin
        )
        #expect(rightPos.x == 1920 - 220 - margin) // Clamped to 1692
    }

    @Test("ADV-M4-18: Dimension badge text formatting across extreme 1x, 2x, 3x scales and sub-pixel rounding")
    func testDimensionBadgeFormattingExtremeScales() {
        // High-resolution selection
        let rect = CGRect(x: 0, y: 0, width: 1920.4, height: 1079.6)

        // 1x
        let (pt1, px1, full1) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: 1.0)
        #expect(pt1 == "1920 × 1080 pt")
        #expect(px1 == "(1920 × 1080 px)")
        #expect(full1 == "1920 × 1080 pt (1920 × 1080 px)")

        // 2x Retina
        let (pt2, px2, full2) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: 2.0)
        #expect(pt2 == "1920 × 1080 pt")
        #expect(px2 == "(3841 × 2159 px)") // 1920.4*2 = 3840.8 -> 3841; 1079.6*2 = 2159.2 -> 2159
        #expect(full2 == "1920 × 1080 pt (3841 × 2159 px)")

        // 3x High-DPI
        let (pt3, px3, full3) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: 3.0)
        #expect(pt3 == "1920 × 1080 pt")
        #expect(px3 == "(5761 × 3239 px)")
        #expect(full3 == "1920 × 1080 pt (5761 × 3239 px)")
    }

    // MARK: - 4. Torture Fuzzing, Clamping & High-Contention Concurrency

    @Test("ADV-M4-19: Fuzzing Torture: 10,000 random rectangle clamps strictly preserve boundary invariants")
    func testCoordinateClampingFuzzingTorture() {
        let containerBounds = CGRect(x: -1920, y: -1080, width: 3840, height: 2160)

        for i in 1...10_000 {
            // Generate pseudo-random coordinates
            let rx = CGFloat((i * 104729) % 200_000 - 100_000) / 10.0
            let ry = CGFloat((i * 1299709) % 200_000 - 100_000) / 10.0
            let rw = CGFloat(abs((i * 7919) % 10_000)) / 2.0
            let rh = CGFloat(abs((i * 6841) % 10_000)) / 2.0

            let candidateRect = CGRect(x: rx, y: ry, width: rw, height: rh)
            let clamped = CoordinateTranslationService.clamp(rect: candidateRect, to: containerBounds)

            // Invariants:
            #expect(clamped.width >= 0)
            #expect(clamped.height >= 0)
            #expect(clamped.minX >= containerBounds.minX)
            #expect(clamped.maxX <= containerBounds.maxX + 0.0001)
            #expect(clamped.minY >= containerBounds.minY)
            #expect(clamped.maxY <= containerBounds.maxY + 0.0001)
        }
    }

    @Test("ADV-M4-20: Concurrency Torture: 80 concurrent async tasks hammering MarqueeSelectionEngine state machine")
    func testConcurrentMarqueeEngineStress() async {
        let engine = MarqueeSelectionEngine()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask {
                    let start = CGPoint(x: CGFloat(i * 10), y: CGFloat(i * 10))
                    let end = CGPoint(x: CGFloat(i * 10 + 100), y: CGFloat(i * 10 + 100))

                    for _ in 0..<50 {
                        engine.beginDrag(at: start)
                        engine.updateDrag(to: end)
                        _ = engine.isDragging
                        _ = engine.normalizedRect
                        if i % 3 == 0 {
                            _ = engine.endDrag(minimumDimension: 4.0)
                        } else if i % 3 == 1 {
                            _ = engine.handleEscapeKey()
                        } else {
                            engine.reset()
                        }
                    }
                }
            }
        }

        // Must finish cleanly without deadlocking or crashing
        engine.reset()
        #expect(engine.state == .idle)
    }

    @Test("ADV-M4-21: 1,000 rapid sequential lifecycle transitions (idle -> begin -> update -> end -> reset)")
    func testRapidLifecycleSequencing() {
        let engine = MarqueeSelectionEngine()

        for i in 1...1000 {
            engine.beginDrag(at: CGPoint(x: 10, y: 10))
            #expect(engine.isDragging == true)

            engine.updateDrag(to: CGPoint(x: 100 + i % 50, y: 100 + i % 50))
            #expect(engine.normalizedRect.width > 0)

            if i % 2 == 0 {
                let rect = engine.endDrag(minimumDimension: 4.0)
                #expect(rect != nil)
                #expect(engine.state == .selected(rect: rect!))
            } else {
                let consumed = engine.handleEscapeKey()
                #expect(consumed == true)
                #expect(engine.state == .dismissed)
            }

            engine.reset()
            #expect(engine.state == .idle)
        }
    }

    // MARK: - 5. Screen Capture Manager Boundary Validation

    @Test("ADV-M4-22: ScreenCaptureManager rejects negative, NaN, infinite, and zero dimensions")
    func testScreenCaptureManagerBoundaryValidation() async {
        let mockBackend = SimulatedScreenCaptureBackend()
        let manager = ScreenCaptureManager(backend: mockBackend)

        let invalidRects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: 0, y: 0, width: -50, height: 50),
            CGRect(x: 0, y: 0, width: 50, height: -50),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
            CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: 0, y: 0, width: 32769, height: 100), // > 32768
            CGRect.null,
            CGRect.infinite
        ]

        for invalid in invalidRects {
            do {
                _ = try await manager.captureDisplayRegion(invalid, displayID: 1)
                Issue.record("Expected ScreenCaptureError.invalidRegion for rect \(invalid), but call succeeded.")
            } catch let error as ScreenCaptureError {
                if case .invalidRegion = error {
                    // Expected error
                } else {
                    Issue.record("Expected ScreenCaptureError.invalidRegion, got \(error)")
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 6. Loupe Pixel Sampler Coordinate Contracts

    @Test("ADV-M4-23: Loupe coordinate translation contract: Cartesian AppKit coordinates vs CoreGraphics inversion")
    func testLoupeCoordinateTranslationContract() {
        // Image has 4 quadrants: Top-Left (Red), Top-Right (Green), Bottom-Left (Blue), Bottom-Right (Yellow)
        let testImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 200, height: 200)

        // 1. AppKit Cartesian cursor at Bottom-Left (x: 50, y: 50)
        let cartesianBottomLeft = CGPoint(x: 50, y: 50)
        let sampledDirect = LoupePixelSampler.samplePixel(in: testImage, at: cartesianBottomLeft)
        #expect(sampledDirect == PixelColor(red: 0, green: 0, blue: 255, alpha: 255)) // Blue

        // 2. An erroneous flip via flipAppKitToCoreGraphics inverts the Y axis prematurely
        let flippedPoint = CoordinateTranslationService.flipAppKitToCoreGraphics(
            point: cartesianBottomLeft,
            primaryScreenHeight: 200
        )
        #expect(flippedPoint == CGPoint(x: 50, y: 150))
        let sampledFlipped = LoupePixelSampler.samplePixel(in: testImage, at: flippedPoint)
        // Inverting Y samples the Top-Left quadrant (Red) instead of Bottom-Left (Blue)
        #expect(sampledFlipped == PixelColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(sampledFlipped != sampledDirect)
    }

    @Test("ADV-M4-24: Loupe Retina scale factor mapping: Points to physical backing pixels contract")
    func testLoupeRetinaScaleFactorMappingContract() {
        // 2x Retina screen: 200x200 pt screen backed by 400x400 px image
        let retinaImage = SimulatedScreenCaptureBackend.makeQuadrantPattern(width: 400, height: 400)
        let scale: CGFloat = 2.0

        // Cursor at Top-Right quadrant in logical points: x = 150 pt (> 100 pt mid), y = 150 pt (> 100 pt mid)
        let cursorPoints = CGPoint(x: 150, y: 150)

        // Physical backing pixels: 150 * 2 = 300 px (> 200 px mid), 150 * 2 = 300 px (> 200 px mid)
        let cursorPixels = CoordinateTranslationService.pointsToPhysicalPixels(point: cursorPoints, scale: scale)
        #expect(cursorPixels == CGPoint(x: 300, y: 300))

        let sampledRetina = LoupePixelSampler.samplePixel(in: retinaImage, at: cursorPixels)
        // Top-Right quadrant is Green
        #expect(sampledRetina == PixelColor(red: 0, green: 255, blue: 0, alpha: 255))

        // If unscaled points are passed directly to a 400x400 image, x = 150 is (< 200 mid), falling into Left half
        let unscaledSample = LoupePixelSampler.samplePixel(in: retinaImage, at: cursorPoints)
        #expect(unscaledSample != sampledRetina)
    }
}
