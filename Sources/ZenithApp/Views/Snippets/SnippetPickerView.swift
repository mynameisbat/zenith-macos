import SwiftUI
import ZenithCore

/// The snippet menu: a search field and the matching snippets. ↑↓ choose, Return inserts, Escape closes
/// (`SnippetPanelController` handles the keys).
struct SnippetPickerView: View {
    @ObservedObject var model: SnippetPickerModel
    let onInsert: (Snippet) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView(text: $model.query, placeholder: "Search Snippets")
                .padding(10)

            Divider()

            let results = model.results
            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    (model.query.isEmpty ? Text("No snippets yet. Add them in Settings → Snippets.") : Text("No matching snippets"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { snippet in
                                row(snippet, isSelected: snippet.id == model.selected?.id)
                                    .id(snippet.id)
                            }
                        }
                        .padding(6)
                    }
                    .onValueChange(of: model.selected?.id) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                ZenithKeyHint("↩", "Insert")
                ZenithKeyHint("↑↓", "Choose")
                ZenithKeyHint("esc", "Close")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: SnippetPanelController.panelSize.width, height: SnippetPanelController.panelSize.height)
        .zenithMaterial(cornerRadius: 12)
    }

    private func row(_ snippet: Snippet, isSelected: Bool) -> some View {
        Button {
            onInsert(snippet)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: snippet.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Text(verbatim: snippet.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !snippet.trigger.isEmpty {
                    Text(verbatim: snippet.trigger)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? ZenithTheme.selection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: snippet.displayName))
        .accessibilityHint("Inserts the snippet")
    }
}
