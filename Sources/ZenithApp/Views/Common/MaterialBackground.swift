import SwiftUI

public struct MaterialBackground: ViewModifier {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 12) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

public extension View {
    func zenithMaterial(cornerRadius: CGFloat = 12) -> some View {
        modifier(MaterialBackground(cornerRadius: cornerRadius))
    }

    func goldenGateMaterial(cornerRadius: CGFloat = 12) -> some View {
        zenithMaterial(cornerRadius: cornerRadius)
    }
}
