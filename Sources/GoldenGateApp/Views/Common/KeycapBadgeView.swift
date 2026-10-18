import SwiftUI

/// Flat, clean native macOS shortcut badge conforming to Apple System UI standards.
/// Zero 3D emboss, zero heavy drop shadows — pure typography and subtle system contrast.
public struct KeycapBadgeView: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .default))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
