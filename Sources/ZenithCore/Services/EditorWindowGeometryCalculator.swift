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
    public static func calculate(
        imageWidth: Int,
        imageHeight: Int,
        displayVisibleFrame: CGRect,
        backingScaleFactor: CGFloat = 2.0
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
        let maxH = max(300, vf.height - 96)
        let minW: CGFloat = 520
        let minH: CGFloat = 360

        var fitW = max(1.0, imagePtWidth)
        var fitH = max(1.0, imagePtHeight)

        if imagePtWidth > maxW || imagePtHeight > maxH {
            let ratio = min(maxW / max(1.0, imagePtWidth), maxH / max(1.0, imagePtHeight))
            fitW = max(1.0, round(imagePtWidth * ratio))
            fitH = max(1.0, round(imagePtHeight * ratio))
        }

        let winW = max(minW, fitW)
        let winH = max(minH, fitH)

        let x = vf.midX - winW / 2
        let y = vf.midY - winH / 2

        return EditorWindowGeometry(
            windowFrame: CGRect(x: x, y: y, width: winW, height: winH),
            canvasSize: CGSize(width: fitW, height: fitH),
            scaleFactor: CGFloat(safeImageW) / max(1.0, fitW)
        )
    }
}
