import SwiftUI
import AppKit
import ZenithCore

/// The clipboard history panel: a wide Liquid Glass strip docked near the bottom of the screen. Search, the kind
/// filter and the item count on top, a row of cards (newest first) in the middle, the keyboard shortcuts and the
/// Paste button below.
public struct ClipboardHistoryView: View {
    @ObservedObject public var viewModel: ClipboardHistoryViewModel
    public var onDismiss: () -> Void
    /// False only for `--render-screenshots`: a window that is not on screen has nothing behind it for glass to
    /// refract, so the pictures get a flat stand-in in the glass's colour.
    private let drawsGlass: Bool

    /// The size the panel asks for; `PanelPositioner.dockedFrame` narrows it on a small screen.
    public static let panelSize = CGSize(width: 1200, height: 372)
    public static let cornerRadius: CGFloat = 34
    private static let cardSpacing: CGFloat = 14

    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: ClipboardHistoryViewModel, onDismiss: @escaping () -> Void = {}) {
        self.init(viewModel: viewModel, drawsGlass: true, onDismiss: onDismiss)
    }

    init(viewModel: ClipboardHistoryViewModel, drawsGlass: Bool, onDismiss: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        self.drawsGlass = drawsGlass
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    public var body: some View {
        VStack(spacing: 12) {
            topRow
            cardsRow
            bottomRow
        }
        .padding(.top, 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !drawsGlass { standInGlass }
        }
        .glassEffectIfNeeded(drawsGlass, in: shape)
    }

    /// What the glass looks like over a desktop, for the pictures: a tinted translucent plate with a lit edge.
    private var standInGlass: some View {
        shape
            .fill(colorScheme == .dark ? Color(white: 0.11, opacity: 0.62) : Color(white: 1, opacity: 0.55))
            .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.7), lineWidth: 1))
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 12) {
            searchField
                .frame(maxWidth: 360)
            filterBar
            Spacer(minLength: 8)
            countLabel
        }
        .frame(height: 36)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search clipboard history", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($isSearchFocused)
                .onChange(of: viewModel.searchText) { _, _ in
                    viewModel.selectedIndex = 0
                }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.selectedIndex = 0
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

    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(ClipboardKindFilter.allCases, id: \.self) { filter in
                let isOn = viewModel.kindFilter == filter
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { viewModel.kindFilter = filter }
                } label: {
                    Text(filter.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if isOn {
                                Capsule()
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.9 : 0.95))
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                .help(filter == .all ? Text("Show everything") : Text("Show \(filter.title.lowercased())"))
            }
        }
        .padding(3)
        .hubCapsule()
    }

    private var countLabel: some View {
        Group {
            if viewModel.filteredItems.count != viewModel.totalCount {
                Text("\(viewModel.filteredItems.count) of \(viewModel.totalCount)")
            } else if viewModel.totalCount == 1 {
                Text("1 item")
            } else {
                Text("\(viewModel.totalCount) items")
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Cards

    @ViewBuilder
    private var cardsRow: some View {
        if viewModel.filteredItems.isEmpty {
            emptyStateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Self.cardSpacing) {
                        ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardCardView(
                                item: item,
                                isSelected: index == viewModel.selectedIndex,
                                quickIndex: index < 9 ? index + 1 : nil,
                                onSelect: { viewModel.selectedIndex = index },
                                onActivate: { viewModel.selectItem(at: index) },
                                onTogglePin: { viewModel.togglePin(for: item) },
                                onDelete: {
                                    withAnimation(.zenithSpring) { viewModel.deleteItem(item: item) }
                                },
                                onPasteVariant: { variant in viewModel.selectItem(item, variant: variant) },
                                onOpenLink: { url in
                                    onDismiss()
                                    NSWorkspace.shared.open(url)
                                }
                            )
                            .id(item.id)
                        }
                    }
                    // Room for the selected card's ring and shadow, and for a hovered card's lift.
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .onChange(of: viewModel.selectedIndex) { _, newIndex in
                    guard viewModel.filteredItems.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(viewModel.filteredItems[newIndex].id, anchor: nil)
                    }
                }
                .onAppear {
                    // The panel is reused: start with the selected card in view.
                    if let selected = viewModel.selectedItem {
                        proxy.scrollTo(selected.id, anchor: .leading)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        let isSearching = !viewModel.searchText.isEmpty
        let isFiltered = viewModel.kindFilter != .all
        return VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : (isFiltered ? viewModel.kindFilter.symbolName : "doc.on.clipboard"))
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isSearching ? "No Results" : (isFiltered ? "Nothing Here" : "No Clipboard History"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: viewModel.kindFilter.emptyMessage(
                searchText: viewModel.searchText,
                matchesElsewhere: viewModel.searchMatchesOutsideFilter
            ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isSearching || isFiltered {
                // When the filter hides what the search found, showing all keeps the search and finds it.
                let showAll = !isSearching || viewModel.searchMatchesOutsideFilter
                Button(showAll ? "Show All" : "Clear Search") {
                    if showAll {
                        viewModel.kindFilter = .all
                    } else {
                        viewModel.searchText = ""
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(20)
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 14) {
            ZenithKeyHint("↩", "Paste")
            ZenithKeyHint("⇧↩", "Plain Text")
            ZenithKeyHint("⌘1–9", "Quick Paste")
            ZenithKeyHint("←→", "Browse")
            ZenithKeyHint("⌘P", "Pin")
            ZenithKeyHint("⌘⌫", "Delete")
            ZenithKeyHint("esc", "Close")

            Spacer(minLength: 12)

            if let selected = viewModel.selectedItem {
                pasteButton(for: selected)
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func pasteButton(for item: ClipboardItem) -> some View {
        let title = ClipboardCardContentCache.shared.content(for: item).shortTitle
        let button = Button {
            viewModel.selectItem(at: viewModel.selectedIndex)
        } label: {
            Text("Paste \u{201C}\(title)\u{201D}")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .padding(.horizontal, 6)
        }
        .tint(ZenithTheme.accent)
        .help("Paste into the app you were using (Return)")

        if drawsGlass {
            button.buttonStyle(.glassProminent)
        } else {
            // Off screen a prominent button is drawn grey (its window is not key): paint the glass one's look.
            button.buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .background(Capsule().fill(ZenithTheme.accent))
        }
    }
}

private extension View {
    /// Liquid Glass behind the panel, unless this is a picture (see `ClipboardHistoryView.drawsGlass`).
    @ViewBuilder
    func glassEffectIfNeeded(_ isOn: Bool, in shape: RoundedRectangle) -> some View {
        if isOn {
            glassEffect(.regular, in: shape)
        } else {
            clipShape(shape)
        }
    }
}
