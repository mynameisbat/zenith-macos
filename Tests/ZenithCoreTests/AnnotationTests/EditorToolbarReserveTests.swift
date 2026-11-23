import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Annotation Editor Toolbar Reserve Suite")
struct EditorToolbarReserveTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)

    @Test("ANN-T1: Without a reserve the window is the canvas, as before")
    func testNoReserveIsUnchanged() {
        let g = EditorWindowGeometryCalculator.calculate(imageWidth: 1600, imageHeight: 1000, displayVisibleFrame: screen, backingScaleFactor: 2)
        #expect(g.canvasSize == CGSize(width: 800, height: 500))
        #expect(g.windowFrame.size == CGSize(width: 800, height: 500))
    }

    @Test("ANN-T2: A reserve adds free height under the canvas, so the toolbar never covers the image")
    func testReserveAddsHeight() {
        let reserve = EditorWindowGeometryCalculator.toolbarReserve
        let g = EditorWindowGeometryCalculator.calculate(
            imageWidth: 1800, imageHeight: 1000, displayVisibleFrame: screen, backingScaleFactor: 2,
            toolbarReserve: reserve, minimumWidth: EditorWindowGeometryCalculator.toolbarWidth
        )
        #expect(g.canvasSize == CGSize(width: 900, height: 500))
        #expect(g.windowFrame.height == 500 + reserve)
        #expect(g.windowFrame.width == 900)
    }

    @Test("ANN-T3: A big capture is shrunk so that canvas plus reserve still fit on the screen")
    func testBigCaptureStillFits() {
        let reserve = EditorWindowGeometryCalculator.toolbarReserve
        let g = EditorWindowGeometryCalculator.calculate(
            imageWidth: 6000, imageHeight: 4000, displayVisibleFrame: screen, backingScaleFactor: 2,
            toolbarReserve: reserve, minimumWidth: EditorWindowGeometryCalculator.toolbarWidth
        )
        #expect(g.windowFrame.height <= screen.height - 96 + 0.5)
        #expect(g.windowFrame.width <= screen.width - 96 + 0.5)
        #expect(g.canvasSize.height + reserve == g.windowFrame.height)
    }

    @Test("ANN-T4: A small capture still opens a window wide enough for the whole toolbar")
    func testSmallCaptureKeepsToolbarWidth() {
        let g = EditorWindowGeometryCalculator.calculate(
            imageWidth: 400, imageHeight: 300, displayVisibleFrame: screen, backingScaleFactor: 2,
            toolbarReserve: EditorWindowGeometryCalculator.toolbarReserve, minimumWidth: EditorWindowGeometryCalculator.toolbarWidth
        )
        #expect(g.windowFrame.width == EditorWindowGeometryCalculator.toolbarWidth)
        #expect(g.canvasSize == CGSize(width: 200, height: 150))
    }

    @Test("ANN-T5: A narrow capture gets a window that follows it (two-row toolbar), a wide one the one-row toolbar")
    func testEditorWindowFollowsThePicture() {
        // 400 x 300 px at 2x is a 200 x 150 pt picture: no 820 pt wide window around it.
        let small = EditorWindowGeometryCalculator.calculateForEditor(imageWidth: 400, imageHeight: 300, displayVisibleFrame: screen, backingScaleFactor: 2)
        #expect(small.canvasSize == CGSize(width: 200, height: 150))
        #expect(small.windowFrame.width == EditorWindowGeometryCalculator.compactToolbarWidth)
        #expect(small.windowFrame.height == max(EditorWindowGeometryCalculator.compactMinimumHeight, 150 + EditorWindowGeometryCalculator.compactToolbarReserve))
        #expect(small.windowFrame.width < EditorWindowGeometryCalculator.toolbarWidth)
        #expect(EditorWindowGeometryCalculator.usesCompactToolbar(canvasWidth: small.canvasSize.width))
        #expect(EditorWindowGeometryCalculator.toolbarReserve(forCanvasWidth: 200) == EditorWindowGeometryCalculator.compactToolbarReserve)

        // A mid-size picture: the window is the picture's width and the toolbar has two rows.
        let medium = EditorWindowGeometryCalculator.calculateForEditor(imageWidth: 1300, imageHeight: 800, displayVisibleFrame: screen, backingScaleFactor: 2)
        #expect(medium.windowFrame.width == 650)
        #expect(medium.windowFrame.height == 400 + EditorWindowGeometryCalculator.compactToolbarReserve)

        // A wide one is as before.
        let wide = EditorWindowGeometryCalculator.calculateForEditor(imageWidth: 1800, imageHeight: 1000, displayVisibleFrame: screen, backingScaleFactor: 2)
        #expect(wide.canvasSize == CGSize(width: 900, height: 500))
        #expect(wide.windowFrame.height == 500 + EditorWindowGeometryCalculator.toolbarReserve)
        #expect(!EditorWindowGeometryCalculator.usesCompactToolbar(canvasWidth: wide.canvasSize.width))

        // It always fits on the screen.
        let huge = EditorWindowGeometryCalculator.calculateForEditor(imageWidth: 6000, imageHeight: 200, displayVisibleFrame: screen, backingScaleFactor: 2)
        #expect(huge.windowFrame.width <= screen.width)
    }
}
