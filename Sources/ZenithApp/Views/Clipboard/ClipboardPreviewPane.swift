import SwiftUI
import AppKit
import ZenithCore

/// Loads a larger, downsampled copy of a clipboard image for the preview pane, off the main thread.
/// Not cached under the item's id: the list's small thumbnails use that cache.
@MainActor
final class PreviewImageLoader: ObservableObject {
    @Published var image: CGImage?
    private(set) var itemID: UUID?

    func load(item: ClipboardItem) async {
        guard itemID != item.id else { return }
        itemID = item.id
        image = nil
        guard let data = item.rawImageData else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageThumbnailService.shared.generateThumbnail(from: data, maxPixelDimension: 900)
        }.value
        // Another item may have been selected meanwhile.
        if itemID == item.id {
            image = decoded
        }
    }
}

/// The right-hand side of the clipboard panel: the selected item at full size, its details, and what you can do.
struct ClipboardPreviewPane: View {
    let item: ClipboardItem?
    let onPaste: (ClipboardItem) -> Void
    let onTogglePin: (ClipboardItem) -> Void
    let onDelete: (ClipboardItem) -> Void

    @StateObject private var imageLoader = PreviewImageLoader()

    /// Text beyond this many characters is not drawn in the preview (an item can be megabytes long).
    private static let maxPreviewCharacters = 20_000

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                details(for: item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()

                actions(for: item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No Selection")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        switch item.contentKind {
        case .image:
            ZStack {
                if let image = imageLoader.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)
            .task(id: item.id) {
                await imageLoader.load(item: item)
            }

        case .color:
            if let rgba = item.colorComponents, let hex = item.colorHex {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    Text(hex)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(String(format: "rgb(%d, %d, %d)", Int(round(rgba.red * 255)), Int(round(rgba.green * 255)), Int(round(rgba.blue * 255))))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(16)
            }

        case .link:
            if let url = item.linkURL {
                VStack(spacing: 10) {
                    ZenithIconTile(systemName: "link", tint: ZenithTint.capture, size: 44)
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(20)
            }

        case .text, .richText:
            ScrollView(.vertical) {
                Text(previewText(for: item))
                    .font(.system(size: 12.5, design: looksLikeCode(item) ? .monospaced : .default))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
    }

    private func previewText(for item: ClipboardItem) -> String {
        guard let text = item.plainTextContent else { return item.previewText }
        // `count` would walk a multi-megabyte string; compare UTF-8 bytes first (always at least the character count).
        if text.utf8.count <= Self.maxPreviewCharacters { return text }
        return String(text.prefix(Self.maxPreviewCharacters)) + "\n…"
    }

    /// Shell commands and source code read better in a monospaced font.
    private func looksLikeCode(_ item: ClipboardItem) -> Bool {
        guard let text = item.plainTextContent?.prefix(400) else { return false }
        let commandPrefixes = ["$ ", "swift ", "git ", "brew ", "npm ", "yarn ", "cd ", "sudo ", "curl ", "docker ", "python", "pip ", "make", "./"]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if commandPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        let codeMarks = ["{", "}", ";", "=>", "->", "</", "()", "==", "func ", "let ", "const ", "import "]
        return codeMarks.filter { text.contains($0) }.count >= 2
    }

    // MARK: Details

    private func details(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Type", item.contentKind.title)
            detailRow("Copied", item.timestamp.formatted(date: .abbreviated, time: .shortened))
            if case .image(_, let width, let height) = item.payload {
                detailRow("Dimensions", "\(width) × \(height)")
            }
            detailRow("Size", SystemCleanerService.formatBytes(Int64(item.byteSize)))
            if let stats = item.textStats, item.contentKind == .text || item.contentKind == .richText {
                detailRow("Content", stats.lines == 1
                    ? String(localized: "\(stats.characters.formatted()) characters · \(stats.words.formatted()) words · 1 line")
                    : String(localized: "\(stats.characters.formatted()) characters · \(stats.words.formatted()) words · \(stats.lines.formatted()) lines"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func actions(for item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            Button {
                onPaste(item)
            } label: {
                Text("Paste")
                    .frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("Paste into the app you were using (Return)")

            if let url = item.linkURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .help("Open \(url.host ?? "the link") in your browser")
            }

            Spacer(minLength: 0)

            Button {
                onTogglePin(item)
            } label: {
                Image(systemName: item.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.bordered)
            .help(item.isPinned ? "Unpin (⌘P)" : "Pin, so it is never pushed out of the history (⌘P)")
            .accessibilityLabel(item.isPinned ? "Unpin" : "Pin")

            Button(role: .destructive) {
                onDelete(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Delete from history (⌘⌫)")
            .accessibilityLabel("Delete")
        }
    }
}
