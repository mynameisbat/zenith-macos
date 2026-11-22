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

    /// The open island's size: what is going on plus the dock, or the page it has grown into.
    private var expandedSize: CGSize {
        geometry.expandedSize(page: islandState.page, showsDock: islandState.showsToolsTab)
    }

    private var restingWidth: CGFloat {
        if isDisplayingAlert {
            return geometry.alertWidth
        } else if islandState.isExpanded {
            return expandedSize.width
        } else if islandState.compactActivityUsesWideWings {
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
            return expandedSize.height
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
        // The open island hangs from the top edge of the screen (or of the notch), so its top is square.
        return geometry.hasNotch || islandState.isExpanded ? 0 : (geometry.idleHeight / 2)
    }

    private var bottomRadius: CGFloat {
        if isDisplayingAlert {
            return 18
        }
        // 28 pt around the open island and its dock tray (22 pt, 6 pt in from the bottom edge); a page is a window, the same corners.
        if islandState.isExpanded { return 28 }
        return geometry.hasNotch ? 10 : (geometry.idleHeight / 2)
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
                    .transition(compactWingsTransition)
            } else if islandState.compactActivity == .nowPlaying, let track = islandState.nowPlayingTrack {
                nowPlayingIdleCapsule(track)
                    .transition(compactWingsTransition)
            } else if islandState.compactActivity == .aiAgent, let agent = islandState.workingAIAgent {
                AIAgentCompactWings(agent: agent, geometry: geometry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        islandState.activeTab = .aiAgents
                        islandState.open()
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows the AI agents")
                    .transition(compactWingsTransition)
            } else if islandState.compactActivity == .keepAwake, let awake = islandState.keepAwake {
                IslandKeepAwakeCompactWings(snapshot: awake, geometry: geometry)
                    .transition(compactWingsTransition)
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        .background(Color.black)
        .overlay(rimLightOverlay)
        .clipShape(currentShape)
        .scaleEffect(islandState.isDropTargeted ? 1.015 : 1.0, anchor: .top)
        .animation(islandState.isExpanded ? ZenithIslandState.openingAnimation : ZenithIslandState.closingAnimation,
                   value: islandState.isExpanded)
        .animation(islandState.page != nil ? ZenithIslandState.openingAnimation : ZenithIslandState.closingAnimation,
                   value: islandState.page)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: islandState.currentTab)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.activeAlert)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNowPlayingActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.focusTimer == nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.compactActivityUsesWideWings)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: islandState.workingAIAgent?.kind)
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
            islandState.open()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing: \(track.title), \(track.artist)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the player")
    }

    // MARK: - Alert Capsule HUD

    /// What sits beside the notch while the island is closed grows in as before, but leaves at once when something else
    /// takes the island (it opening onto a card, a notice): a slow fade-out under the arriving card read as two cards
    /// overlapping.
    private var compactWingsTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.08))
        )
    }

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
                    .minimumScaleFactor(0.85)

                if let subtitle = alert.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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

    /// What the open island can show, as tabs. On a notched display the hardware notch hides the first
    /// `notchRect.height` pt of the panel, so the card starts below that (`ZenithIslandGeometry.tabStripHeight`), once,
    /// in `contextCard`. (Each piece used to add its own notch inset, which pushed the tab switcher up behind the notch
    /// and the rest off the bottom whenever both Now Playing and the shelf existed.)
    private var availableTabs: [IslandExpandedTab] {
        ZenithIslandState.availableTabs(
            hasTrack: islandState.nowPlayingTrack != nil,
            hasShelfItems: !islandState.droppedItems.isEmpty,
            showsWidgets: islandState.showsWidgets,
            showsAIAgents: islandState.showsAIAgentsTab
        )
    }

    private var currentTab: IslandExpandedTab {
        ZenithIslandState.resolvedTab(
            active: islandState.activeTab,
            hasTrack: islandState.nowPlayingTrack != nil,
            hasShelfItems: !islandState.droppedItems.isEmpty,
            showsWidgets: islandState.showsWidgets,
            showsAIAgents: islandState.showsAIAgentsTab,
            isDropTargeted: islandState.isDropTargeted
        )
    }

    @ViewBuilder
    private var expandedIslandContent: some View {
        if let page = islandState.page {
            IslandPageView(page: page, geometry: geometry, islandState: islandState)
                .frame(width: expandedSize.width, height: expandedSize.height, alignment: .top)
        } else {
            tabbedIslandContent
        }
    }

    /// What is going on (music, a timer, an agent, staged files) in the island's usual 380 × 130 pt, and under it the dock
    /// of tools. A file being dragged in gets the whole island: the dock steps aside for the drop.
    private var tabbedIslandContent: some View {
        VStack(spacing: 0) {
            contextCard
            if islandState.showsToolsTab {
                IslandDock(islandState: islandState)
                    .opacity(islandState.isDropTargeted ? 0.35 : 1)
            }
        }
        .frame(width: geometry.expandedWidth, height: expandedSize.height, alignment: .top)
    }

    private var contextCard: some View {
        let tabs = availableTabs
        let current = currentTab
        let hasTabs = tabs.count > 1 && !islandState.isDropTargeted

        return ZStack(alignment: .top) {
            // The card sits at the bottom of the area and the strip of tabs at the top, so the strip is clear of the
            // hardware notch whatever its height.
            VStack(spacing: 0) {
                Spacer(minLength: geometry.tabStripHeight)
                cardContent(current)
                    .frame(width: geometry.expandedWidth, height: ZenithIslandGeometry.cardHeight)
                Color.clear.frame(height: ZenithIslandGeometry.cardBottomGap)
            }

            if hasTabs {
                tabSwitcherHeader(tabs: tabs, current: current)
                    .frame(height: geometry.tabStripHeight, alignment: .center)
            }
        }
        .frame(width: geometry.expandedWidth, height: geometry.expandedHeight, alignment: .top)
    }

    @ViewBuilder
    private func cardContent(_ current: IslandExpandedTab) -> some View {
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
        case .aiAgents:
            IslandAIAgentsPanel(islandState: islandState)
        case .shelf:
            shelfContent
        }
    }

    /// The tabs as icon-only pills in segmented capsules. Beside a notch there are only about 97 pt either side of it,
    /// so the tabs are shared between the two sides, two pills each, and the shelf is a pill with a small count
    /// (`IslandTabStrip`). Without a notch the pills are one capsule at the left and the shelf, with the number of
    /// items on it, a small capsule at the right. Nothing sits in the middle: beside a notch that is the hardware.
    private func tabSwitcherHeader(tabs: [IslandExpandedTab], current: IslandExpandedTab) -> some View {
        let strip = IslandTabStrip.layout(tabs: tabs, hasNotch: geometry.hasNotch)
        return HStack(spacing: 0) {
            tabCapsule(strip.left, current: current)
            Spacer(minLength: geometry.hasNotch ? geometry.notchRect.width + 8 : 8)
            if geometry.hasNotch {
                tabCapsule(strip.right, current: current)
            } else if tabs.contains(.shelf) {
                shelfCapsule(isSelected: current == .shelf)
            }
        }
        .padding(.horizontal, ZenithIslandGeometry.tabEdgeInset)
    }

    @ViewBuilder
    private func tabCapsule(_ tabs: [IslandExpandedTab], current: IslandExpandedTab) -> some View {
        if !tabs.isEmpty {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    tabPill(for: tab, isSelected: tab == current)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func select(_ tab: IslandExpandedTab) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            islandState.activeTab = tab
        }
    }

    private func tabPill(for tab: IslandExpandedTab, isSelected: Bool) -> some View {
        let symbol: String
        let title: String
        switch tab {
        case .nowPlaying:
            symbol = "music.note"
            title = String(localized: "Now Playing")
        case .widgets:
            symbol = islandState.focusTimer != nil ? "timer" : "square.grid.2x2.fill"
            title = String(localized: "Widgets")
        case .aiAgents:
            symbol = islandState.workingAIAgent != nil ? "sparkles" : "sparkle"
            title = String(localized: "AI")
        case .shelf:
            symbol = "tray.and.arrow.down.fill"
            title = String(localized: "Shelf (\(islandState.droppedItems.count))")
        }
        return Button {
            select(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .frame(width: ZenithIslandGeometry.tabPillWidth, height: 24)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.clear))
                .overlay(alignment: .topTrailing) {
                    // The shelf's pill has no room for its count: a small badge, only beside a notch.
                    if tab == .shelf, !islandState.droppedItems.isEmpty {
                        Text(verbatim: String(islandState.droppedItems.count))
                            .font(.system(size: 8.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(.black)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shelfCapsule(isSelected: Bool) -> some View {
        let count = islandState.droppedItems.count
        let title = String(localized: "Shelf (\(count))")
        return Button {
            select(.shelf)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(verbatim: String(count))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
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
        .padding(.horizontal, 14)
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(islandState.isDropTargeted ? 0.09 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
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
