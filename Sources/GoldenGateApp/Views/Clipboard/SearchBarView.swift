import SwiftUI

public struct SearchBarView: View {
    @Binding public var text: String
    public var placeholder: String
    public var onClear: () -> Void
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: String = "Search history...", onClear: @escaping () -> Void = {}) {
        self._text = text
        self.placeholder = placeholder
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            TextField(placeholder, text: $text)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary)

            if !text.isEmpty {
                Button(action: {
                    text = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: text.isEmpty)
        .onAppear {
            isFocused = true
        }
    }
}
