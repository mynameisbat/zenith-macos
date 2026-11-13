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

    /// Something shows beside the notch while the island is closed: a running timer, or else playing media.
    private var isNowPlayingActive: Bool {
        islandState.hasCompactActivity
    }

    /// The closed island swells a little under the pointer before it opens (`ZenithIslandState.isHoverEmphasized`).
    private var isEmphasized: Bool {
        islandState.isHoverEmphasized && !islandState.isExpanded && !isDisplayingAlert
    }

    private var currentWidth: CGFloat {
        restingWidth + (isEmphasized ? 2 * ZenithTheme.Island.hoverEmphasisSide : 0)
    }

    /// Hanging from a notch it also grows down; a floating pill only stretches along the menu bar and stays in it.
    private var currentHeight: CGFloat {
        restingHeight + (isEmphasized && geometry.hasNotch ? ZenithTheme.Island.hoverEmphasisDrop : 0)
    }

    private var restingWidth: CGFloat {
        if isDisplayingAlert {
            return geometry.alertWidth
        } else if islandState.isExpanded {
            return geometry.expandedWidth
        } else if islandState.focusTimer != nil {
            return geometry.timerIdleWidth
        } else if isNowPlayingActive {
            return geometry.nowPlayingIdleWidth
        } else {
            return geometry.idleWidth
        }
    }

    private var restingHeight: CGFloat {
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
                Group {
                    if let level = alert.level {
                        levelCapsuleView(alert, level: level)
                    } else {
                        alertCapsuleView(alert)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if islandState.isExpanded {
                expandedIslandContent
                    .transition(contentArrival)
            } else if let timer = islandState.focusTimer {
                IslandTimerCompactWings(snapshot: timer, geometry: geometry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        islandState.activeTab = .widgets
                        islandState.open()
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the timer")
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
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
        .animation(islandState.isExpanded ? ZenithIslandState.openingAnimation : ZenithIslandState.closingAnimation,
                   value: islandState.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.activeAlert)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNowPlayingActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.focusTimer == nil)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: islandState.isDropTargeted)
        .onValueChange(of: islandState.isDropTargeted) { targeted in
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
            islandState.open()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing: \(track.title), \(track.artist)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the player")
    }

    // MARK: - Alert Capsule HUD

    /// The shape leads and the page follows: it waits for the island to be most of the way open, then comes into
    /// focus from the top edge. Leaving, it is gone before the shape has closed around it.
    private var contentArrival: AnyTransition {
        if islandState.prefersReducedMotion() { return .opacity }
        return .asymmetric(
            insertion: AnyTransition
                .modifier(active: IslandContentArrival(progress: 0), identity: IslandContentArrival(progress: 1))
                .animation(.easeOut(duration: 0.3).delay(0.1)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.12))
        )
    }

    /// A volume or brightness reading: its symbol, a bar and the percentage.
    private func levelCapsuleView(_ alert: IslandAlert, level: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: alert.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 18)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.12), value: level)

            Text(verbatim: "\(Int((level * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(width: geometry.alertWidth, height: geometry.alertHeight)
        .padding(.top, geometry.hasNotch ? geometry.notchRect.height : 0)
        .frame(width: geometry.alertWidth, height: geometry.effectiveAlertHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: alert.title))
        .accessibilityValue(Text(verbatim: "\(Int((level * 100).rounded()))%"))
    }

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

    /// The panel is a fixed 96 pt. On a notched display the hardware notch hides the first `notchRect.height` pt of it,
    /// so the content starts below that, once, here. (Each piece used to add its own notch inset, which pushed the
    /// tab switcher up behind the notch and the rest off the bottom whenever both Now Playing and the shelf existed.)
    private var availableTabs: [IslandExpandedTab] {
        ZenithIslandState.availableTabs(
            hasTrack: islandState.nowPlayingTrack != nil,
            hasShelfItems: !islandState.droppedItems.isEmpty,
            showsWidgets: islandState.showsWidgets
        )
    }

    private var currentTab: IslandExpandedTab {
        ZenithIslandState.resolvedTab(
            active: islandState.activeTab,
            hasTrack: islandState.nowPlayingTrack != nil,
            hasShelfItems: !islandState.droppedItems.isEmpty,
            showsWidgets: islandState.showsWidgets,
            isDropTargeted: islandState.isDropTargeted
        )
    }

    private var expandedIslandContent: some View {
        let tabs = availableTabs
        let current = currentTab
        let hasTabs = tabs.count > 1 && !islandState.isDropTargeted

        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Without a notch the tab switcher takes its own row; with one it sits in the free strips either
                // side of the notch (below).
                if hasTabs && !geometry.hasNotch {
                    tabSwitcherHeader(tabs: tabs, current: current)
                        .padding(.top, 4)
                }

                switch current {
                case .nowPlaying:
                    if let track = islandState.nowPlayingTrack {
                        NowPlayingExpandedView(
                            track: track,
                            onPrevious: { NowPlayingService.shared.previousTrack() },
                            onTogglePlayPause: { NowPlayingService.shared.togglePlayPause() },
                            onNext: { NowPlayingService.shared.nextTrack() },
                            onSeek: { NowPlayingService.shared.seek(to: $0) }
                        )
                    } else {
                        shelfContent
                    }
                case .widgets:
                    IslandWidgetsPanel(islandState: islandState)
                case .shelf:
                    shelfContent
                }
            }
            .padding(.top, geometry.hasNotch ? geometry.notchRect.height + 2 : (hasTabs ? 0 : 6))

            if hasTabs && geometry.hasNotch {
                tabSwitcherHeader(tabs: tabs, current: current)
                    .frame(height: geometry.notchRect.height)
            }
        }
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight, alignment: .top)
    }

    /// With a notch the tabs sit either side of it (icons only when three must share the space); without one they
    /// sit together at the left.
    private func tabSwitcherHeader(tabs: [IslandExpandedTab], current: IslandExpandedTab) -> some View {
        let compact = geometry.hasNotch && tabs.count > 2
        let leftCount = geometry.hasNotch ? (tabs.count + 1) / 2 : tabs.count
        return HStack(spacing: 4) {
            ForEach(Array(tabs.prefix(leftCount)), id: \.self) { tab in
                tabButton(for: tab, isSelected: tab == current, compact: compact)
            }
            if geometry.hasNotch {
                Spacer(minLength: geometry.notchRect.width + 8)
                ForEach(Array(tabs.dropFirst(leftCount)), id: \.self) { tab in
                    tabButton(for: tab, isSelected: tab == current, compact: compact)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 8)
    }

    private func tabButton(for tab: IslandExpandedTab, isSelected: Bool, compact: Bool) -> some View {
        let symbol: String
        let title: String
        switch tab {
        case .nowPlaying:
            symbol = "music.note"
            title = String(localized: "Now Playing")
        case .widgets:
            symbol = islandState.focusTimer != nil ? "timer" : "square.grid.2x2.fill"
            title = String(localized: "Widgets")
        case .shelf:
            symbol = "tray.and.arrow.down.fill"
            title = String(localized: "Shelf (\(islandState.droppedItems.count))")
        }
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                islandState.activeTab = tab
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 10 : 8.5))
                if !compact {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                } else if tab == .shelf {
                    Text("\(islandState.droppedItems.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .fixedSize()
            .foregroundColor(isSelected ? .white : .white.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Empties the shelf. Several items, or text that exists nowhere else, are not dropped without asking.
    private func clearShelf() {
        let count = islandState.droppedItems.count
        let hasText = islandState.droppedItems.contains { $0.textContent != nil }
        if count > 1 || hasText {
            guard DestructiveConfirmation.confirm(
                title: count == 1 ? "Remove 1 item from the shelf?" : "Remove \(count) items from the shelf?",
                message: "Files stay where they are; only their place on the shelf goes. Text snippets are lost.",
                destructiveTitle: "Remove"
            ) else { return }
        }
        islandState.clearAll()
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
                clearShelf()
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Remove everything from the shelf")
            .accessibilityLabel("Clear the shelf")
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
                .help("Remove from Shelf")
                .accessibilityLabel("Remove \(item.name) from the shelf")

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
                    .help("Quick Preview")
                    .accessibilityLabel(isCurrentlyPreviewed ? "Close preview" : "Preview \(item.name)")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityHint("Click to copy, double-click to preview, or drag it out")
        .accessibilityAction(named: "Copy") { onCopy() }
        .accessibilityAction(named: "Preview") { islandState.togglePreview(for: item) }
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
                        IslandAppActionCoordinator.shared.confirmAndUninstall(appAt: url) {
                            islandState.removeItem(id: item.id)
                        }
                    } label: {
                        Label("Deep Uninstall App & Leftovers", systemImage: "trash.fill")
                    }

                    Button {
                        IslandAppActionCoordinator.shared.confirmAndSlim(appAt: url)
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

/// How far the expanded island's page has arrived: 0 is out of focus, small and invisible; 1 is in place.
struct IslandContentArrival: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
    }
}
