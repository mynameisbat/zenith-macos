import SwiftUI
import AppKit
import ZenithCore

@MainActor
final class IslandPreviewLoader: ObservableObject {
    @Published var image: CGImage?
    @Published var isLoading: Bool = false

    func load(for item: IslandDropItem) async {
        guard item.isImageFile, let url = item.fileURL else { return }
        if let cached = ImageThumbnailService.shared.cachedThumbnail(for: item.id) {
            self.image = cached
            return
        }
        self.isLoading = true
        let thumb = await ImageThumbnailService.shared.thumbnail(for: item.id, url: url, maxPixelDimension: 600)
        self.image = thumb
        self.isLoading = false
    }
}

/// Floating preview HUD card displayed directly below the Dynamic Island Drop Shelf.
/// Renders high-resolution image previews, code/text snippets, file metadata, and one-click quick actions.
public struct IslandItemPreviewCard: View {
    public let item: IslandDropItem
    public var onClose: () -> Void
    public var onCopy: () -> Void
    public var onRemove: () -> Void

    @StateObject private var loader = IslandPreviewLoader()

    public init(
        item: IslandDropItem,
        onClose: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onRemove: @escaping () -> Void = {}
    ) {
        self.item = item
        self.onClose = onClose
        self.onCopy = onCopy
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerBar
            contentBody
            metadataBar
            actionsBar
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 10)
        .task(id: item.id) {
            await loader.load(for: item)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            fileTypeIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !item.fileExtension.isEmpty {
                    Text(item.fileExtension.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(ZenithTheme.accent)
                }
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Close Preview (Esc)")
        }
    }

    private var fileTypeIcon: some View {
        Group {
            if item.isImageFile {
                Image(systemName: "photo.fill")
                    .foregroundColor(.purple)
            } else if item.isTextOrCodeFile {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundColor(.blue)
            } else if item.isAudioOrVideoFile {
                Image(systemName: "play.rectangle.fill")
                    .foregroundColor(.pink)
            } else if item.isPDF {
                Image(systemName: "doc.richtext.fill")
                    .foregroundColor(.red)
            } else {
                Image(systemName: "doc.fill")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    // MARK: - Content Body

    private var contentBody: some View {
        Group {
            if item.isImageFile {
                imagePreviewBox
            } else if item.isTextOrCodeFile || item.textContent != nil {
                textSnippetBox
            } else {
                genericFileBox
            }
        }
    }

    private var imagePreviewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            if let cgImage = loader.image {
                Image(decorative: cgImage, scale: 2.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 292, maxHeight: 170)
            } else if loader.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var textSnippetBox: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(item.textSnippet ?? "No content preview available")
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var genericFileBox: some View {
        VStack(spacing: 8) {
            if let url = item.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            if let url = item.fileURL {
                Text(url.path)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        HStack(spacing: 8) {
            if let size = item.formattedFileSize {
                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9))
                    Text(size)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.secondary)
            }

            if let dims = item.imageDimensions {
                Text("•")
                    .foregroundColor(.secondary.opacity(0.5))
                HStack(spacing: 3) {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 9))
                    Text("\(Int(dims.width)) × \(Int(dims.height)) px")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9.5))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        HStack(spacing: 6) {
            // Native macOS Quick Look button
            if let url = item.fileURL {
                Button {
                    IslandQuickLookCoordinator.shared.openQuickLook(for: url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 10.5))
                        Text("Quick Look")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open macOS Quick Look (Space)")

                // Reveal in Finder
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
            }

            // Copy to Clipboard
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy to Clipboard")

            // Remove from shelf
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Remove from Drop Shelf")
        }
    }
}
