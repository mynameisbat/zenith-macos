import SwiftUI
import AppKit
import GoldenGateCore

// MARK: - Type Badge View

public struct TypeBadgeView: View {
    public let type: ClipboardItemType

    public init(type: ClipboardItemType) {
        self.type = type
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 8.5, weight: .semibold))
            Text(badgeLabel)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .foregroundColor(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }

    private var iconName: String {
        switch type {
        case .plainText: return "doc.text"
        case .richText: return "text.quote"
        case .image: return "photo"
        }
    }

    private var badgeLabel: String {
        switch type {
        case .plainText: return "TXT"
        case .richText: return "RTF"
        case .image: return "IMG"
        }
    }
}

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published var image: CGImage?

    func load(itemId: UUID, payload: ClipboardPayload) async {
        if let cached = ImageThumbnailService.shared.cachedThumbnail(for: itemId) {
            self.image = cached
            return
        }
        guard case .image(let data, _, _) = payload else { return }
        if let thumb = await ImageThumbnailService.shared.thumbnail(for: itemId, data: data) {
            self.image = thumb
        }
    }
}

// MARK: - Thumbnail Preview View

public struct ThumbnailPreviewView: View {
    public let itemId: UUID
    public let payload: ClipboardPayload
    @StateObject private var loader = ThumbnailLoader()

    public init(itemId: UUID, payload: ClipboardPayload) {
        self.itemId = itemId
        self.payload = payload
    }

    public init(item: ClipboardItem) {
        self.init(itemId: item.id, payload: item.payload)
    }

    public init(payload: ClipboardPayload) {
        self.init(itemId: UUID(), payload: payload)
    }

    public var body: some View {
        Group {
            let currentImage = loader.image ?? ImageThumbnailService.shared.cachedThumbnail(for: itemId)
            if let cgImage = currentImage {
                Image(decorative: cgImage, scale: 2.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            } else {
                ThumbnailSkeletonView()
                    .task(id: itemId) {
                        await loader.load(itemId: itemId, payload: payload)
                    }
            }
        }
    }
}

final class SkeletonPulseState: ObservableObject {
    @Published var isPulsing: Bool = false
}

public struct ThumbnailSkeletonView: View {
    @StateObject private var pulseState = SkeletonPulseState()

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(pulseState.isPulsing ? 0.08 : 0.03))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(pulseState.isPulsing ? 0.5 : 0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseState.isPulsing = true
                }
            }
    }
}

final class RowHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

final class RowTapDebouncer: ObservableObject {
    private var lastTap: Date = .distantPast

    func shouldProcessTap() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTap) > 0.3 else { return false }
        lastTap = now
        return true
    }
}

// MARK: - Clipboard Row View

public struct ClipboardRowView: View {
    public let item: ClipboardItem
    public let isSelected: Bool
    public let quickIndex: Int? // 1...9
    public let onSelect: () -> Void
    public let onTogglePin: () -> Void
    public let onDelete: () -> Void

    @StateObject private var hoverState = RowHoverState()
    @StateObject private var tapDebouncer = RowTapDebouncer()

    public init(
        item: ClipboardItem,
        isSelected: Bool,
        quickIndex: Int?,
        onSelect: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void = {}
    ) {
        self.item = item
        self.isSelected = isSelected
        self.quickIndex = quickIndex
        self.onSelect = onSelect
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(spacing: 10) {
            // 1. Quick Shortcut Badge (⌘1...⌘9)
            if let index = quickIndex {
                KeycapBadgeView(text: "⌘\(index)")
            } else {
                Spacer().frame(width: 26) // Align with numbered rows
            }

            // 2. Type Badge Pill
            TypeBadgeView(type: item.itemType)

            // 3. Content Preview (Text or Image Thumbnail)
            HStack(spacing: 8) {
                if item.itemType == .image {
                    ThumbnailPreviewView(item: item)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.previewText)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(2)
                        .foregroundColor(.primary)

                    HStack(spacing: 6) {
                        Text(relativeTimeString(from: item.timestamp))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(.secondary)

                        Text("•")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))

                        Text(SystemCleanerService.formatBytes(Int64(item.byteSize)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            // 4. Action Buttons (Pin & Delete on hover)
            HStack(spacing: 6) {
                Button(action: onTogglePin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(item.isPinned ? Color.accentColor : .secondary.opacity(hoverState.isHovered ? 0.6 : 0.0))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin item" : "Pin item to prevent deletion")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(hoverState.isHovered ? 0.7 : 0.0))
                }
                .buttonStyle(.plain)
                .help("Delete item (⌘⌫)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                hoverState.isHovered = hovering
            }
        }
        .onTapGesture {
            guard tapDebouncer.shouldProcessTap() else { return }
            onSelect()
        }
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if hoverState.isHovered {
            return Color.primary.opacity(0.06)
        } else {
            return Color.clear
        }
    }

    private func relativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
