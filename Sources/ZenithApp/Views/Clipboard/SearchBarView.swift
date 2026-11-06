import SwiftUI

public struct SearchBarView: View {
    @Binding public var text: String
    public var placeholder: LocalizedStringKey
    public var onClear: () -> Void
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: LocalizedStringKey = "Search", onClear: @escaping () -> Void = {}) {
        self._text = text
        self.placeholder = placeholder
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            if !text.isEmpty {
                Button(action: {
                    text = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? ZenithTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: text.isEmpty)
        .onAppear {
            isFocused = true
        }
    }
}
