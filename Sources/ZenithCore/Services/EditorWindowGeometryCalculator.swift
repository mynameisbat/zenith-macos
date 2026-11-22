import Foundation
import CoreGraphics

/// Resulting window geometry calculation preserving aspect ratio and visibility constraints.
public struct EditorWindowGeometry: Equatable, Sendable {
    public let windowFrame: CGRect
    public let canvasSize: CGSize
    public let scaleFactor: CGFloat

    public init(windowFrame: CGRect, canvasSize: CGSize, scaleFactor: CGFloat) {
        self.windowFrame = windowFrame
        self.canvasSize = canvasSize
        self.scaleFactor = scaleFactor
    }
}

/// Pure calculation engine for sizing and positioning the post-capture annotation editor window (F21).
public struct EditorWindowGeometryCalculator: Sendable {
    /// Height kept free under the image for the floating toolbar (the toolbar and its margin), so it never covers
    /// the part of the screenshot being annotated.
    public static let toolbarReserve: CGFloat = 84
    /// Width the toolbar needs; a window narrower than this would clip it.
    public static let toolbarWidth: CGFloat = 820
    /// A picture narrower than `toolbarWidth` gets the toolbar in two rows instead, so the window can follow the
    /// picture (a 300 pt wide capture used to open an 820 pt wide window with a lot of empty space around it).
    public static let compactToolbarReserve: CGFloat = 140
    public static let compactToolbarWidth: CGFloat = 480
    /// The smallest height of a window with the compact toolbar: the picture and its reserve, but not less than this.
    public static let compactMinimumHeight: CGFloat = 280

    /// Whether the toolbar is drawn in two rows for a canvas this wide.
    public static func usesCompactToolbar(canvasWidth: CGFloat) -> Bool {
        canvasWidth < toolbarWidth
    }

    /// The free strip under the canvas for the toolbar that goes with a canvas this wide.
    public static func toolbarReserve(forCanvasWidth width: CGFloat) -> CGFloat {
        usesCompactToolbar(canvasWidth: width) ? compactToolbarReserve : toolbarReserve
    }

    /// The window the editor opens for a capture: as small as the picture and its toolbar allow. A wide picture gets
    /// the one-row toolbar (and a window as wide as the toolbar); a narrow one the two-row toolbar and a window that
    /// is the picture's width, but never narrower than `compactToolbarWidth`.
    public static func calculateForEditor(
        imageWidth: Int,
        imageHeight: Int,
        displayVisibleFrame: CGRect,
        backingScaleFactor: CGFloat = 2.0
    ) -> EditorWindowGeometry {
        let wide = calculate(
            imageWidth: imageWidth, imageHeight: imageHeight, displayVisibleFrame: displayVisibleFrame,
            backingScaleFactor: backingScaleFactor, toolbarReserve: toolbarReserve, minimumWidth: toolbarWidth
        )
        guard usesCompactToolbar(canvasWidth: wide.canvasSize.width) else { return wide }

        let compact = calculate(
            imageWidth: imageWidth, imageHeight: imageHeight, displayVisibleFrame: displayVisibleFrame,
            backingScaleFactor: backingScaleFactor, toolbarReserve: compactToolbarReserve, minimumWidth: compactToolbarWidth
        )
        let vf = (displayVisibleFrame.width > 0 && displayVisibleFrame.height > 0)
            ? displayVisibleFrame
            : CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let height = max(compactMinimumHeight, compact.canvasSize.height + compactToolbarReserve)
        let frame = CGRect(
            x: vf.midX - compact.windowFrame.width / 2, y: vf.midY - height / 2,
            width: compact.windowFrame.width, height: height
        )
        return EditorWindowGeometry(windowFrame: frame, canvasSize: compact.canvasSize, scaleFactor: compact.scaleFactor)
    }

    /// - Parameters:
    ///   - toolbarReserve: Extra window height under the image that stays free of it.
    ///   - minimumWidth: The narrowest window to open, whatever the image size.
    public static func calculate(
        imageWidth: Int,
        imageHeight: Int,
        displayVisibleFrame: CGRect,
        backingScaleFactor: CGFloat = 2.0,
        toolbarReserve: CGFloat = 0,
        minimumWidth: CGFloat = 520
    ) -> EditorWindowGeometry {
        let safeImageW = max(1, imageWidth)
        let safeImageH = max(1, imageHeight)
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 2.0
        let imagePtWidth = CGFloat(safeImageW) / scale
        let imagePtHeight = CGFloat(safeImageH) / scale

        let vf = (displayVisibleFrame.width > 0 && displayVisibleFrame.height > 0)
            ? displayVisibleFrame
            : CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxW = max(300, vf.width - 96)
        let maxH = max(300, vf.height - 96 - toolbarReserve)
        let minW: CGFloat = minimumWidth
        let minH: CGFloat = 360

        var fitW = max(1.0, imagePtWidth)
        var fitH = max(1.0, imagePtHeight)

        if imagePtWidth > maxW || imagePtHeight > maxH {
            let ratio = min(maxW / max(1.0, imagePtWidth), maxH / max(1.0, imagePtHeight))
            fitW = max(1.0, round(imagePtWidth * ratio))
            fitH = max(1.0, round(imagePtHeight * ratio))
        }

        let winW = max(minW, fitW)
        let winH = max(minH, fitH + toolbarReserve)

        let x = vf.midX - winW / 2
        let y = vf.midY - winH / 2

        return EditorWindowGeometry(
            windowFrame: CGRect(x: x, y: y, width: winW, height: winH),
            canvasSize: CGSize(width: fitW, height: fitH),
            scaleFactor: CGFloat(safeImageW) / max(1.0, fitW)
        )
    }
}
