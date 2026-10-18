import SwiftUI
import GoldenGateCore

public struct ClipboardHistoryView: View {
    @ObservedObject public var viewModel: ClipboardHistoryViewModel
    public var onDismiss: () -> Void

    public init(viewModel: ClipboardHistoryViewModel, onDismiss: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Search Bar Header
            SearchBarView(text: $viewModel.searchText) {
                viewModel.selectedIndex = 0
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.5)

            // 2. Main Content Area (List or Empty State)
            if viewModel.filteredItems.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                                ClipboardRowView(
                                    item: item,
                                    isSelected: index == viewModel.selectedIndex,
                                    quickIndex: index < 9 ? (index + 1) : nil,
                                    onSelect: {
                                        viewModel.selectItem(at: index)
                                    },
                                    onTogglePin: {
                                        viewModel.togglePin(for: item)
                                    },
                                    onDelete: {
                                        withAnimation(.goldenGateSpring) {
                                            viewModel.deleteItem(item: item)
                                        }
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < viewModel.filteredItems.count {
                            let selectedID = viewModel.filteredItems[newIndex].id
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                proxy.scrollTo(selectedID, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()
                .opacity(0.5)

            // 3. Footer Bar with Shortcut Hints & Item Count
            footerView
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 420, height: 520)
        .goldenGateMaterial(cornerRadius: 12)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundColor(.secondary.opacity(0.6))
            Text(viewModel.searchText.isEmpty ? "Clipboard History is Empty" : "No matches found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(viewModel.searchText.isEmpty ? "Copied items will appear here automatically." : "Try adjusting your search query.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Text("Clear Search")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private var footerView: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) of \(viewModel.totalCount) items")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 5) {
                KeycapBadgeView(text: "↑↓ Navigate")
                KeycapBadgeView(text: "↵ Paste")
                KeycapBadgeView(text: "⌘⌫ Delete")
                KeycapBadgeView(text: "⌘1-9 Quick")
                KeycapBadgeView(text: "⎋ Close")
            }
        }
    }
}
