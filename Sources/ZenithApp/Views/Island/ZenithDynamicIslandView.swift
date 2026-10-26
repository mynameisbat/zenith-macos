import SwiftUI
import AppKit
import ZenithCore

/// Hardware-integrated notch shelf and transient alert HUD for Zenith.
/// Pure black stealth integration into MacBook hardware notch.
/// Seamlessly transitions between idle notch indicator, transient alert HUD, and file drop shelf.
public struct ZenithDynamicIslandView: View {
    @ObservedObject public var islandState: ZenithIslandState = .shared

    public var geometry: ZenithIslandGeometry

    public init(geometry: ZenithIslandGeometry = ZenithIslandGeometry()) {
        self.geometry = geometry
    }

    private var isDisplayingAlert: Bool {
        islandState.activeAlert != nil
    }

    private var isNowPlayingActive: Bool {
        islandState.nowPlayingTrack?.isPlaying == true
    }

    private var currentWidth: CGFloat {
        if isDisplayingAlert {
            return geometry.alertWidth
        } else if islandState.isExpanded {
            return geometry.expandedWidth
        } else if isNowPlayingActive {
            return geometry.nowPlayingIdleWidth
        } else {
            return geometry.idleWidth
        }
    }

    private var currentHeight: CGFloat {
        if isDisplayingAlert {
            return geometry.effectiveAlertHeight
        } else if islandState.isExpanded {
            return geometry.expandedHeight
        } else if isNowPlayingActive {
            return geometry.nowPlayingIdleHeight
        } else {
            return geometry.idleHeight
        }
    }

    private var topRadius: CGFloat {
        if isDisplayingAlert {
            return geometry.hasNotch ? 0 : 18
        }
        return geometry.hasNotch ? 0 : (islandState.isExpanded ? 16 : (geometry.idleHeight / 2))
    }

    private var bottomRadius: CGFloat {
        if isDisplayingAlert {
            return 18
        }
        return islandState.isExpanded ? 18 : (geometry.hasNotch ? 10 : (geometry.idleHeight / 2))
    }

    private var currentShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }

    private var targetRimLightOpacity: Double {
        guard islandState.isRimLightVisible else { return 0.0 }
        if islandState.isDropTargeted {
            return 0.25
        } else if isDisplayingAlert {
            return 0.18
        } else {
            return 0.12
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            islandContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Unified Morphing Container

    private var targetRimLightColor: Color {
        if let alert = islandState.activeAlert {
            return alert.resolvedColor
        }
        return Color.white
    }

    private var rimLightOverlay: some View {
        currentShape
            .strokeBorder(targetRimLightColor.opacity(targetRimLightOpacity), lineWidth: 0.5)
            .opacity(islandState.isRimLightVisible ? 1.0 : 0.0)
            .mask {
                if geometry.hasNotch {
                    // Strictly mask out top 0.75pt stroke line so no border leaks onto hardware notch bezel
                    Rectangle()
                        .padding(.top, 0.75)
                } else {
                    Rectangle()
                }
            }
    }

    private var islandContainer: some View {
        ZStack(alignment: .top) {
            if let alert = islandState.activeAlert {
                alertCapsuleView(alert)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if islandState.isExpanded {
                expandedIslandContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if isNowPlayingActive, let track = islandState.nowPlayingTrack {
                nowPlayingIdleCapsule(track)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        .background(Color.black)
        .overlay(rimLightOverlay)
        .clipShape(currentShape)
        .scaleEffect(islandState.isDropTargeted ? 1.015 : 1.0, anchor: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.activeAlert)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNowPlayingActive)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: islandState.isDropTargeted)
        .onChange(of: islandState.isDropTargeted) { _, targeted in
            if targeted {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
        }
    }

    // MARK: - Now Playing Idle Capsule (Wings on left & right of notch)

    private func nowPlayingIdleCapsule(_ track: NowPlayingTrack) -> some View {
        HStack {
            NowPlayingCompactDiscView(track: track)
                .padding(.leading, 6)

            Spacer()

            NowPlayingVisualizerView(brandColor: track.app.brandColor, isPlaying: track.isPlaying)
                .padding(.trailing, 6)
        }
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height / 2 - 8) : 5)
        .frame(width: geometry.nowPlayingIdleWidth, height: geometry.nowPlayingIdleHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            islandState.onMouseEnter()
        }
    }

    // MARK: - Alert Capsule HUD

    private func alertCapsuleView(_ alert: IslandAlert) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Image(systemName: alert.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(alert.resolvedColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let subtitle = alert.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: geometry.alertWidth, height: geometry.alertHeight)
        .padding(.top, geometry.hasNotch ? geometry.notchRect.height : 0)
        .frame(width: geometry.alertWidth, height: geometry.effectiveAlertHeight, alignment: .top)
    }

    // MARK: - Expanded Dynamic Island (Tabbed Shelf or Now Playing)

    private var expandedIslandContent: some View {
        VStack(spacing: 0) {
            // If both Now Playing and Shelf items exist, provide smooth tab switcher
            if islandState.nowPlayingTrack != nil && !islandState.droppedItems.isEmpty {
                tabSwitcherHeader
            }

            // Tab content
            if islandState.nowPlayingTrack != nil && (islandState.activeTab == .nowPlaying || islandState.droppedItems.isEmpty) {
                if let track = islandState.nowPlayingTrack {
                    NowPlayingExpandedView(
                        track: track,
                        onPrevious: { NowPlayingService.shared.previousTrack() },
                        onTogglePlayPause: { NowPlayingService.shared.togglePlayPause() },
                        onNext: { NowPlayingService.shared.nextTrack() }
                    )
                    .padding(.top, geometry.hasNotch ? (geometry.notchRect.height + 2) : 6)
                }
            } else {
                shelfContent
            }
        }
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight)
    }

    private var tabSwitcherHeader: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    islandState.activeTab = .nowPlaying
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "music.note")
                        .font(.system(size: 8.5))
                    Text("Now Playing")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(islandState.activeTab == .nowPlaying ? .white : .white.opacity(0.45))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(islandState.activeTab == .nowPlaying ? Color.white.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    islandState.activeTab = .shelf
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 8.5))
                    Text("Shelf (\(islandState.droppedItems.count))")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(islandState.activeTab == .shelf ? .white : .white.opacity(0.45))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(islandState.activeTab == .shelf ? Color.white.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height + 2) : 4)
    }

    // MARK: - Shelf Content

    private var shelfContent: some View {
        ZStack {
            if islandState.droppedItems.isEmpty {
                emptyShelfGuidance
            } else {
                populatedShelfDock
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height + 2) : 8)
        .padding(.bottom, 8)
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight)
    }

    // MARK: - Empty Shelf Guidance

    private var emptyShelfGuidance: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(islandState.isDropTargeted ? 0.85 : 0.4))

            Text(islandState.isDropTargeted ? "Release to stage" : "Drop files here to stage")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(islandState.isDropTargeted ? 0.95 : 0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(islandState.isDropTargeted ? 0.08 : 0.045))
        )
    }

    // MARK: - Populated Shelf Dock

    private var populatedShelfDock: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(islandState.droppedItems) { item in
                        IslandDropItemCardView(
                            item: item,
                            islandState: islandState,
                            onCopy: {
                                copyItemToClipboard(item: item)
                            },
                            makeItemProvider: {
                                makeItemProvider(for: item)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )

            // Clear shelf button
            Button {
                islandState.clearAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Clear Shelf")
        }
    }

    private func copyItemToClipboard(item: IslandDropItem) {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        if let url = item.fileURL {
            pboard.writeObjects([url as NSURL, url.path as NSString])
            ToastHUDController.shared.show(message: "Copied \(item.name)", icon: "doc.on.clipboard")
        } else if let text = item.textContent {
            pboard.setString(text, forType: .string)
            ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
        }
    }

    private func makeItemProvider(for item: IslandDropItem) -> NSItemProvider {
        if let url = item.fileURL {
            let provider = NSItemProvider()
            // 1. URL representation (Standard for Finder, Telegram, Slack, Desktop, Notes)
            provider.registerObject(url as NSURL, visibility: .all)
            // 2. Plain text path (Fallback for web chat inputs, terminal, code editors)
            provider.registerObject(url.path as NSString, visibility: .all)

            // 3. Regular file data representation (only if not an app bundle or directory)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                provider.registerFileRepresentation(forTypeIdentifier: "public.item", fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            }
            return provider
        } else if let text = item.textContent {
            return NSItemProvider(object: text as NSString)
        } else {
            return NSItemProvider(object: item.name as NSString)
        }
    }
}

// MARK: - Shelf Item Card View with Rich Thumbnail & Preview Triggers

@MainActor
final class IslandCardHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

@MainActor
final class IslandCardThumbnailLoader: ObservableObject {
    @Published var image: CGImage?

    func load(for item: IslandDropItem) async {
        guard item.isImageFile, let url = item.fileURL else { return }
        if let cached = ImageThumbnailService.shared.cachedThumbnail(for: item.id) {
            self.image = cached
            return
        }
        let thumb = await ImageThumbnailService.shared.thumbnail(for: item.id, url: url, maxPixelDimension: 64)
        self.image = thumb
    }
}

public struct IslandDropItemCardView: View {
    public let item: IslandDropItem
    @ObservedObject public var islandState: ZenithIslandState
    public var onCopy: () -> Void
    public var makeItemProvider: () -> NSItemProvider

    @StateObject private var hoverState = IslandCardHoverState()
    @StateObject private var loader = IslandCardThumbnailLoader()

    public init(
        item: IslandDropItem,
        islandState: ZenithIslandState,
        onCopy: @escaping () -> Void,
        makeItemProvider: @escaping () -> NSItemProvider
    ) {
        self.item = item
        self.islandState = islandState
        self.onCopy = onCopy
        self.makeItemProvider = makeItemProvider
    }

    private var isCurrentlyPreviewed: Bool {
        islandState.previewItem?.id == item.id
    }

    public var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                thumbnailBox

                // Delete individual item button
                Button {
                    islandState.removeItem(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -4)

                // Quick preview eye button on hover or active preview
                if hoverState.isHovered || isCurrentlyPreviewed {
                    Button {
                        islandState.togglePreview(for: item)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.8))
                                .frame(width: 17, height: 17)
                            Image(systemName: "eye.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .offset(x: -16, y: 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }

            Text(item.name)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: 60)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrentlyPreviewed ? ZenithTheme.accent.opacity(0.2) : (hoverState.isHovered ? Color.white.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrentlyPreviewed ? ZenithTheme.accent : Color.clear, lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverState.isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            islandState.togglePreview(for: item)
        }
        .onTapGesture(count: 1) {
            onCopy()
        }
        .onDrag {
            islandState.beginDragOut()
            return makeItemProvider()
        }
        .contextMenu {
            Button {
                islandState.togglePreview(for: item)
            } label: {
                Label("Quick Preview", systemImage: "eye.fill")
            }

            if let url = item.fileURL {
                Button {
                    IslandQuickLookCoordinator.shared.openQuickLook(for: url)
                } label: {
                    Label("Quick Look in macOS (Space)", systemImage: "macwindow")
                }

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open with Default App", systemImage: "arrow.up.forward.app")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Divider()

                if url.pathExtension.lowercased() == "app" {
                    Button {
                        Task {
                            if let plan = AppUninstallerService.shared.analyzeApp(atPath: url.path) {
                                do {
                                    let freed = try AppUninstallerService.shared.uninstall(plan: plan, moveToTrash: true)
                                    ToastHUDController.shared.show(
                                        message: "Uninstalled \(plan.app.displayName) (Freed \(SystemCleanerService.formatBytes(freed)))",
                                        icon: "trash.fill"
                                    )
                                    islandState.removeItem(id: item.id)
                                } catch {
                                    ToastHUDController.shared.show(message: "Uninstall error: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                                }
                            }
                        }
                    } label: {
                        Label("Deep Uninstall App & Leftovers", systemImage: "trash.fill")
                    }

                    Button {
                        Task {
                            if let plan = BinarySlimmerService.shared.scanApp(atPath: url.path) {
                                do {
                                    let saved = try BinarySlimmerService.shared.slimApp(plan: plan)
                                    ToastHUDController.shared.show(
                                        message: "Slimmed \(plan.appName) (Saved \(SystemCleanerService.formatBytes(saved)))",
                                        icon: "scissors"
                                    )
                                } catch {
                                    ToastHUDController.shared.show(message: "Slimming error: \(error.localizedDescription)", icon: "exclamationmark.triangle")
                                }
                            } else {
                                ToastHUDController.shared.show(message: "Already native Apple Silicon binary", icon: "checkmark.seal")
                            }
                        }
                    } label: {
                        Label("Slim Universal App (Strip Intel code)", systemImage: "scissors")
                    }

                    Divider()
                }
            }

            Button {
                onCopy()
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
            }

            Button(role: .destructive) {
                islandState.removeItem(id: item.id)
            } label: {
                Label("Remove from Shelf", systemImage: "xmark")
            }
        }
        .task(id: item.id) {
            await loader.load(for: item)
        }
    }

    private var thumbnailBox: some View {
        Group {
            if item.isImageFile {
                if let thumb = loader.image {
                    Image(decorative: thumb, scale: 2.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 32, height: 32)
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            } else if let url = item.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
            }
        }
    }
}
