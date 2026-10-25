import SwiftUI
import ZenithCore

/// Live floating pill badge displaying selection dimensions in points and physical backing pixels.
public struct DimensionBadgeView: View {
    public let pointsText: String
    public let pixelsText: String

    public init(pointsText: String, pixelsText: String) {
        self.pointsText = pointsText
        self.pixelsText = pixelsText
    }

    public init(rect: CGRect, scaleFactor: CGFloat) {
        let (pts, pxs, _) = MarqueeGeometry.formatDimensionText(rect: rect, scaleFactor: scaleFactor)
        self.pointsText = pts
        self.pixelsText = pxs
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(pointsText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text(pixelsText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.1, opacity: 0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
    }
}
