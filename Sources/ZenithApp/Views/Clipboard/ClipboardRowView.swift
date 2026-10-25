import SwiftUI
import AppKit
import ZenithCore

// MARK: - Type Badge View

public struct TypeBadgeView: View {
    public let type: ClipboardItemType

    public init(type: ClipboardItemType) {
        self.type = type
    }

    public var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
            Text(badgeLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundColor(.secondary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.05))
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
    @Published var hasLoaded: Bool = false

    func load(itemId: UUID, payload: ClipboardPayload) async {
        if let cached = ImageThumbnailService.shared.cachedThumbnail(for: itemId) {
            self.image = cached
            self.hasLoaded = true
            return
        }
        guard case .image(let data, _, _) = payload else {
            self.hasLoaded = true
            return
        }
        if let thumb = await ImageThumbnailService.shared.thumbnail(for: itemId, data: data) {
            self.image = thumb
        }
        self.hasLoaded = true
    }
}

// MARK: - Thumbnail Preview View

public struct ThumbnailPreviewView: View {
    public let itemId: UUID
    public let payload: ClipboardPayload
    public var size: CGFloat
    public var cornerRadius: CGFloat
    @StateObject private var loader = ThumbnailLoader()

    public init(itemId: UUID, payload: ClipboardPayload, size: CGFloat = 32, cornerRadius: CGFloat = 4) {
        self.itemId = itemId
        self.payload = payload
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public init(item: ClipboardItem, size: CGFloat = 32, cornerRadius: CGFloat = 4) {
        self.init(itemId: item.id, payload: item.payload, size: size, cornerRadius: cornerRadius)
    }

    public init(payload: ClipboardPayload, size: CGFloat = 32, cornerRadius: CGFloat = 4) {
        self.init(itemId: UUID(), payload: payload, size: size, cornerRadius: cornerRadius)
    }

    public var body: some View {
        ZStack {
            Color.primary.opacity(0.04)

            let currentImage = loader.image ?? ImageThumbnailService.shared.cachedThumbnail(for: itemId)
            if let cgImage = currentImage {
                Image(decorative: cgImage, scale: 2.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loader.hasLoaded {
                Image(systemName: "photo")
                    .font(.system(size: max(8, size * 0.38)))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                ThumbnailSkeletonView(size: size)
                    .task(id: itemId) {
                        await loader.load(itemId: itemId, payload: payload)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
        )
    }
}

final class SkeletonPulseState: ObservableObject {
    @Published var isPulsing: Bool = false
}

public struct ThumbnailSkeletonView: View {
    @StateObject private var pulseState = SkeletonPulseState()
    public var size: CGFloat

    public init(size: CGFloat = 32) {
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(pulseState.isPulsing ? 0.08 : 0.03))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: max(8, size * 0.38)))
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

// MARK: - QuickLook Preview Card

public struct QuickLookPreviewCard: View {
    public let item: ClipboardItem
    public var onCopy: () -> Void
    public var onClose: () -> Void

    public init(item: ClipboardItem, onCopy: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.item = item
        self.onCopy = onCopy
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("Image Preview")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Image Preview Container
            if case .image(let data, let w, let h) = item.payload,
               let nsImage = NSImage(data: data) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.03))

                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 180)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                )

                // Meta Info
                HStack {
                    Text("\(w) × \(h) px")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(SystemCleanerService.formatBytes(Int64(item.byteSize)))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Copy Action Button
            Button {
                onCopy()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text("Copy to Clipboard")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

final class RowHoverState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var showQuickLook: Bool = false
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
                    ThumbnailPreviewView(item: item, size: 32, cornerRadius: 5)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if item.itemType == .image {
                        Text("Image")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.primary)
                    } else {
                        Text(item.previewText)
                            .font(.system(size: 12, weight: .regular))
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }

                    HStack(spacing: 6) {
                        if item.itemType == .image, case .image(_, let w, let h) = item.payload {
                            Text("\(w) × \(h)")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundColor(.secondary)

                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.4))
                        }

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

            // 4. Action Buttons (Pin, Quick Preview & Delete on hover)
            HStack(spacing: 6) {
                if item.itemType == .image {
                    Button(action: { hoverState.showQuickLook = true }) {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(hoverState.isHovered ? 0.7 : 0.0))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Preview")
                    .popover(isPresented: $hoverState.showQuickLook, arrowEdge: .trailing) {
                        QuickLookPreviewCard(
                            item: item,
                            onCopy: onSelect,
                            onClose: { hoverState.showQuickLook = false }
                        )
                    }
                }

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
