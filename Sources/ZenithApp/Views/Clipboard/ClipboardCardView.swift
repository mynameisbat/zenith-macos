import SwiftUI
import AppKit
import ZenithCore

// MARK: - Caches

/// The icon of the app a copy came from, by bundle identifier. Looked up once (a Launch Services query and an icon
/// read are not something to repeat per redraw); an app that is not installed any more has no icon and the card
/// shows its kind's symbol instead.
@MainActor
enum ClipboardSourceAppIcon {
    private static let cache = NSCache<NSString, NSImage>()
    private static var unknown = Set<String>()

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty, !unknown.contains(bundleID) else { return nil }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            unknown.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

/// Thumbnails for the cards, decoded once (ImageIO downsampling, off the main thread) and kept by item id. Not the
/// shared 128 px service: a card shows an image at about 190 × 140 pt, which wants more pixels than that.
enum ClipboardCardThumbnails {
    static let service = ImageThumbnailService(maxCacheCount: 48, defaultMaxPixelDimension: 440, maxCacheBytes: 64 * 1024 * 1024)
}

@MainActor
private final class CardImageLoader: ObservableObject {
    @Published var image: CGImage?
    @Published var failed = false

    func load(itemID: UUID, data: Data?) async {
        if image != nil { return }
        if let cached = ClipboardCardThumbnails.service.cachedThumbnail(for: itemID) {
            image = cached
            return
        }
        guard let data else { failed = true; return }
        if let thumbnail = await ClipboardCardThumbnails.service.thumbnail(for: itemID, data: data) {
            image = thumbnail
        } else {
            failed = true
        }
    }
}

private final class CardHoverState: ObservableObject {
    @Published var isHovered = false
}

private final class CardTapDebouncer: ObservableObject {
    private var lastTap: Date = .distantPast

    func shouldProcessTap() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTap) > 0.3 else { return false }
        lastTap = now
        return true
    }
}

// MARK: - Card

/// One card of the clipboard strip: the source app and kind on top, a live preview, and the size and ⌘-number below.
struct ClipboardCardView: View {
    static let size = CGSize(width: 210, height: 236)
    static let cornerRadius: CGFloat = 24
    private static let headerHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 30

    let item: ClipboardItem
    let isSelected: Bool
    /// 1...9 for the cards ⌘1…⌘9 paste.
    let quickIndex: Int?
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// Paste as plain text or as a cleaned link.
    let onPasteVariant: (ClipboardPasteVariant) -> Void
    let onOpenLink: (URL) -> Void

    @StateObject private var hover = CardHoverState()
    @StateObject private var tapDebouncer = CardTapDebouncer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        let content = ClipboardCardContentCache.shared.content(for: item)
        VStack(spacing: 0) {
            header(content)
            preview(content)
            footer(content)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(shape.fill(HubSurface.fill))
        .clipShape(shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(ZenithTheme.accent, lineWidth: 2)
            } else {
                shape.strokeBorder(HubSurface.edge, lineWidth: 1)
            }
        }
        .shadow(color: isSelected ? ZenithTheme.accent.opacity(0.28) : .clear, radius: 8, y: 3)
        .offset(y: hover.isHovered && !reduceMotion ? -3 : 0)
        .animation(.easeOut(duration: 0.18), value: hover.isHovered)
        .contentShape(shape)
        .onHover { hover.isHovered = $0 }
        .onTapGesture(count: 2) { onActivate() }
        .simultaneousGesture(TapGesture().onEnded {
            guard tapDebouncer.shouldProcessTap() else { return }
            onSelect()
        })
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityDescription(content)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onActivate() }
        .accessibilityActions {
            if item.offersPasteVariant(.plainText) {
                Button("Paste as Plain Text") { onPasteVariant(.plainText) }
            }
            if item.offersPasteVariant(.cleanedLink) {
                Button("Paste Clean Link") { onPasteVariant(.cleanedLink) }
            }
            Button(item.isPinned ? "Unpin" : "Pin") { onTogglePin() }
            Button("Delete") { onDelete() }
        }
    }

    // MARK: Parts

    private func header(_ content: ClipboardCardContent) -> some View {
        HStack(spacing: 8) {
            sourceIcon(content)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: content.kindTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: ClipboardCardContent.relativeTime(of: item.timestamp))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
        .background(isSelected ? ZenithTheme.accent.opacity(0.26) : Color.primary.opacity(0.045))
    }

    @ViewBuilder
    private func sourceIcon(_ content: ClipboardCardContent) -> some View {
        if let icon = ClipboardSourceAppIcon.icon(for: item.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .overlay(
                    Image(systemName: content.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    @ViewBuilder
    private func preview(_ content: ClipboardCardContent) -> some View {
        switch content.preview {
        case .text(let text):
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .lineLimit(8)
                .foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

        case .code(let text):
            Text(verbatim: text)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .lineLimit(9)
                .foregroundStyle(.primary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

        case .link(let host, let path):
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ZenithTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ZenithTheme.accent.opacity(0.14)))
                    .padding(.bottom, 2)
                Text(verbatim: host)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !path.isEmpty {
                    Text(verbatim: path)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)

        case .color(let hex, let red, let green, let blue, let alpha):
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha))
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: hex)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(content.prefersDarkTextOnPreview ? Color.black.opacity(0.78) : Color.white)
                        .padding(10)
                }
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(10)

        case .image:
            ClipboardCardImage(itemID: item.id, data: item.rawImageData)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(10)
        }
    }

    private func footer(_ content: ClipboardCardContent) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: content.meta)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let quickIndex {
                Text(verbatim: "⌘\(quickIndex)")
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
    }

    // MARK: Menu and accessibility

    @ViewBuilder
    private var contextMenu: some View {
        Button("Paste") { onActivate() }
        if item.offersPasteVariant(.plainText) {
            Button("Paste as Plain Text") { onPasteVariant(.plainText) }
        }
        if item.offersPasteVariant(.cleanedLink) {
            Button("Paste Clean Link") { onPasteVariant(.cleanedLink) }
        }
        if let url = item.linkURL {
            Button("Open Link") { onOpenLink(url) }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { onTogglePin() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }

    /// "Link: example.com/docs, example.com, pinned": the kind, what the preview shows, and the meta line.
    private func accessibilityDescription(_ content: ClipboardCardContent) -> String {
        let shown: String
        switch content.preview {
        case .text(let text), .code(let text): shown = String(text.prefix(160))
        case .link(let host, let path): shown = host + path
        case .color(let hex, _, _, _, _): shown = hex
        case .image: shown = content.shortTitle
        }
        var parts = ["\(content.kindTitle): \(shown)"]
        if case .text = content.preview { parts.append(content.meta) }
        if case .code = content.preview { parts.append(content.meta) }
        if case .image = content.preview { parts = ["\(content.kindTitle): \(content.meta)"] }
        if item.isPinned { parts.append(String(localized: "Pinned")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Image

/// The thumbnail of an image card, filling its area. Read from the cache when it is there (no flash while scrolling
/// back), otherwise decoded once off the main thread.
private struct ClipboardCardImage: View {
    let itemID: UUID
    let data: Data?
    @StateObject private var loader = CardImageLoader()

    var body: some View {
        let image = loader.image ?? ClipboardCardThumbnails.service.cachedThumbnail(for: itemID)
        // `Color.clear` takes the size the card offers; an image filling the area would otherwise size the view.
        Color.primary.opacity(0.06)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .task(id: itemID) {
            await loader.load(itemID: itemID, data: data)
        }
        .accessibilityHidden(true)
    }
}
