import SwiftUI
import ZenithCore

/// The clipboard history panel: search and kind filters on top, the list on the left (grouped by day), the selected
/// item's preview on the right, and the keyboard shortcuts at the bottom.
public struct ClipboardHistoryView: View {
    @ObservedObject public var viewModel: ClipboardHistoryViewModel
    public var onDismiss: () -> Void

    public static let panelSize = CGSize(width: 700, height: 460)
    private static let listWidth: CGFloat = 330

    public init(viewModel: ClipboardHistoryViewModel, onDismiss: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SearchBarView(text: $viewModel.searchText, placeholder: "Search clipboard history") {
                    viewModel.selectedIndex = 0
                }
                filterChips
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            HStack(spacing: 0) {
                listPane
                    .frame(width: Self.listWidth)

                Divider()

                ClipboardPreviewPane(
                    item: viewModel.selectedItem,
                    onPaste: { item in viewModel.selectItem(item) },
                    onPasteVariant: { item, variant in viewModel.selectItem(item, variant: variant) },
                    onTogglePin: { item in viewModel.togglePin(item: item) },
                    onDelete: { item in
                        withAnimation(.zenithSpring) {
                            viewModel.deleteItem(item: item)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
            }

            Divider()

            footerView
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .zenithMaterial(cornerRadius: 12)
    }

    // MARK: Filters

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardKindFilter.allCases, id: \.self) { filter in
                let isOn = viewModel.kindFilter == filter
                Button {
                    viewModel.kindFilter = filter
                } label: {
                    Label(filter.title, systemImage: filter.symbolName)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isOn ? ZenithTheme.accent : Color.primary.opacity(0.06))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                .help(filter == .all ? Text("Show everything") : Text("Show \(filter.title.lowercased())"))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: List

    /// One list line: either a day heading or an item with its index in `filteredItems`.
    private enum ListEntry: Identifiable {
        case header(ClipboardDateBucket)
        case item(Int, ClipboardItem)

        var id: String {
            switch self {
            case .header(let bucket): return "header-\(bucket.rawValue)"
            case .item(_, let item): return item.id.uuidString
            }
        }
    }

    /// Day headings only while not searching: search results are ordered by relevance, not by time.
    private var entries: [ListEntry] {
        let items = viewModel.filteredItems
        let isSearching = !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var result: [ListEntry] = []
        result.reserveCapacity(items.count + 3)
        var lastBucket: ClipboardDateBucket?
        let now = Date()
        for (index, item) in items.enumerated() {
            if !isSearching {
                let bucket = ClipboardDateBucket.bucket(for: item.timestamp, now: now)
                if bucket != lastBucket {
                    result.append(.header(bucket))
                    lastBucket = bucket
                }
            }
            result.append(.item(index, item))
        }
        return result
    }

    @ViewBuilder
    private var listPane: some View {
        if viewModel.filteredItems.isEmpty {
            emptyStateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .header(let bucket):
                                ZenithSectionHeader(verbatim: bucket.title)
                                    .padding(.top, bucket == .today ? 2 : 10)
                                    .padding(.bottom, 3)
                            case .item(let index, let item):
                                ClipboardRowView(
                                    item: item,
                                    isSelected: index == viewModel.selectedIndex,
                                    quickIndex: index < 9 ? (index + 1) : nil,
                                    onSelect: {
                                        viewModel.selectedIndex = index
                                    },
                                    onActivate: {
                                        viewModel.selectItem(at: index)
                                    },
                                    onTogglePin: {
                                        viewModel.togglePin(for: item)
                                    },
                                    onDelete: {
                                        withAnimation(.zenithSpring) {
                                            viewModel.deleteItem(item: item)
                                        }
                                    },
                                    onPasteVariant: { variant in
                                        viewModel.selectItem(item, variant: variant)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onValueChange(of: viewModel.selectedIndex) { newIndex in
                    if newIndex >= 0 && newIndex < viewModel.filteredItems.count {
                        let selectedID = viewModel.filteredItems[newIndex].id
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedID, anchor: nil)
                        }
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
            Text(isSearching
                    ? "Nothing matches \u{201C}\(viewModel.searchText)\u{201D}."
                    : (isFiltered ? "No \(viewModel.kindFilter.title.lowercased()) in the history yet." : "Things you copy will appear here."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isSearching || isFiltered {
                Button(isSearching ? "Clear Search" : "Show All") {
                    if isSearching {
                        viewModel.searchText = ""
                    } else {
                        viewModel.kindFilter = .all
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(20)
    }

    // MARK: Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            Group {
                if viewModel.filteredItems.count != viewModel.totalCount {
                    Text("\(viewModel.filteredItems.count) of \(viewModel.totalCount)")
                } else if viewModel.totalCount == 1 {
                    Text("1 item")
                } else {
                    Text("\(viewModel.totalCount) items")
                }
            }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 8)

            ZenithKeyHint("↩", "Paste")
            ZenithKeyHint("⇧↩", "Plain Text")
            ZenithKeyHint("⌘1–9", "Quick Paste")
            ZenithKeyHint("⌘P", "Pin")
            ZenithKeyHint("⌘⌫", "Delete")
            ZenithKeyHint("esc", "Close")
        }
    }
}
