import SwiftUI
import ZenithCore

/// The snippet menu: a search field and the matching snippets, in the look of the clipboard strip and the Command Hub
/// (a Liquid Glass plate, a capsule field, rows with a rounded accent highlight). ↑↓ choose, Return inserts, Escape
/// closes (`SnippetPanelController` handles the keys).
struct SnippetPickerView: View {
    @ObservedObject var model: SnippetPickerModel
    let onInsert: (Snippet) -> Void
    let onDismiss: () -> Void
    /// False only for `--render-screenshots`: a window that is not on screen has nothing behind it for glass to refract.
    private let drawsGlass: Bool

    static let cornerRadius: CGFloat = 28

    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(model: SnippetPickerModel, onInsert: @escaping (Snippet) -> Void, onDismiss: @escaping () -> Void) {
        self.init(model: model, drawsGlass: true, onInsert: onInsert, onDismiss: onDismiss)
    }

    init(model: SnippetPickerModel, drawsGlass: Bool, onInsert: @escaping (Snippet) -> Void, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onInsert = onInsert
        self.onDismiss = onDismiss
        self.drawsGlass = drawsGlass
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 10) {
            searchField

            let results = model.results
            if results.isEmpty {
                emptyState
            } else {
                list(results)
            }

            footer
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: SnippetPanelController.panelSize.width, height: SnippetPanelController.panelSize.height)
        .background {
            if !drawsGlass { standInGlass }
        }
        .modifier(SnippetGlass(isOn: drawsGlass, shape: shape))
    }

    /// What the glass looks like over a desktop, for the pictures (as `ClipboardHistoryView` does).
    private var standInGlass: some View {
        shape
            .fill(colorScheme == .dark ? Color(white: 0.11, opacity: 0.62) : Color(white: 1, opacity: 0.55))
            .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.7), lineWidth: 1))
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search Snippets", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($isSearchFocused)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .hubCapsule()
        .overlay(RoundedRectangle(cornerRadius: 1000, style: .circular).strokeBorder(ZenithTheme.accent.opacity(isSearchFocused ? 0.55 : 0), lineWidth: 1.5))
        .onAppear { isSearchFocused = true }
    }

    // MARK: Results

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            (model.query.isEmpty ? Text("No snippets yet. Add them in Settings → Snippets.") : Text("No matching snippets"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private func list(_ results: [Snippet]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(results) { snippet in
                        row(snippet, isSelected: snippet.id == model.selected?.id)
                            .id(snippet.id)
                    }
                }
            }
            .onChange(of: model.selected?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ snippet: Snippet, isSelected: Bool) -> some View {
        Button {
            onInsert(snippet)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: snippet.displayName)
                        .font(.system(size: 13, weight: .semibold))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? ZenithTheme.accent : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: snippet.displayName))
        .accessibilityHint("Inserts the snippet")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            ZenithKeyHint("↩", "Insert")
            ZenithKeyHint("↑↓", "Choose")
            ZenithKeyHint("esc", "Close")
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 6)
    }
}

/// Liquid Glass behind the panel, unless this is a picture (see `SnippetPickerView.drawsGlass`).
private struct SnippetGlass: ViewModifier {
    let isOn: Bool
    let shape: RoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular, in: shape)
        } else {
            content.clipShape(shape)
        }
    }
}
