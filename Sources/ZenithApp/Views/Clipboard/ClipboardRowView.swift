import SwiftUI
import AppKit
import ZenithCore

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

// MARK: - Leading Icon

/// What sits at the start of a clipboard row: the image itself, a color swatch, or a symbol for the kind of text.
struct ClipboardItemGlyph: View {
    let item: ClipboardItem
    let isSelected: Bool
    var size: CGFloat = 26

    var body: some View {
        Group {
            switch item.contentKind {
            case .image:
                ThumbnailPreviewView(item: item, size: size, cornerRadius: 5)
            case .color:
                if let rgba = item.colorComponents {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                        .frame(width: size - 6, height: size - 6)
                }
            default:
                Image(systemName: item.contentKind.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Clipboard Row View

/// One line of the clipboard list: glyph, a single line of text, pin mark and its ⌘-number, like a menu item.
public struct ClipboardRowView: View {
    public let item: ClipboardItem
    public let isSelected: Bool
    public let quickIndex: Int? // 1...9
    public let onSelect: () -> Void
    public let onActivate: () -> Void
    public let onTogglePin: () -> Void
    public let onDelete: () -> Void
    /// Paste as plain text or as a cleaned link.
    public let onPasteVariant: (ClipboardPasteVariant) -> Void

    @StateObject private var hoverState = RowHoverState()
    @StateObject private var tapDebouncer = RowTapDebouncer()

    public init(
        item: ClipboardItem,
        isSelected: Bool,
        quickIndex: Int?,
        onSelect: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void = {},
        onPasteVariant: @escaping (ClipboardPasteVariant) -> Void = { _ in }
    ) {
        self.item = item
        self.isSelected = isSelected
        self.quickIndex = quickIndex
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onPasteVariant = onPasteVariant
    }

    private var title: String {
        if case .image(_, let width, let height) = item.payload {
            return String(localized: "Image \(String(width)) × \(String(height))")
        }
        // One line: newlines and tabs in a preview read as spaces.
        return item.previewText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    public var body: some View {
        HStack(spacing: 8) {
            ClipboardItemGlyph(item: item, isSelected: isSelected)

            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(ZenithTheme.accent))
                    .accessibilityLabel("Pinned")
            }

            if let index = quickIndex {
                ZenithShortcutText("⌘\(index)", isOnSelection: isSelected)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .zenithRowBackground(isSelected: isSelected, isHovered: hoverState.isHovered, cornerRadius: 6)
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onActivate()
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard tapDebouncer.shouldProcessTap() else { return }
            onSelect()
        })
        .contextMenu {
            Button("Paste") { onActivate() }
            if item.offersPasteVariant(.plainText) {
                Button("Paste as Plain Text") { onPasteVariant(.plainText) }
            }
            if item.offersPasteVariant(.cleanedLink) {
                Button("Paste Clean Link") { onPasteVariant(.cleanedLink) }
            }
            Button(item.isPinned ? "Unpin" : "Pin") { onTogglePin() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isPinned
            ? Text("\(item.contentKind.title): \(title), pinned")
            : Text("\(item.contentKind.title): \(title)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onActivate() }
    }
}
