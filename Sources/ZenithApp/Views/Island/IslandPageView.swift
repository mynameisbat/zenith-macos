import SwiftUI
import AppKit
import ZenithCore

/// A page of the island: a strip with the way back, the page's name and a close button, and below it one of Zenith's
/// tools, drawn where it used to have a window. Only the two that fit the island's 380 pt are pages (System and
/// Tools); the others open Zenith's Settings window.
///
/// The tools are the same views the Command Hub shows. The island's window is dark (`ZenithIslandPanel` sets the
/// appearance), so they arrive in their dark look on the island's black.
struct IslandPageView: View {
    let page: IslandPage
    let geometry: ZenithIslandGeometry
    @ObservedObject var islandState: ZenithIslandState

    var body: some View {
        let content = geometry.pageContentSize(for: page)
        return VStack(spacing: 0) {
            header
                .frame(width: content.width, height: geometry.pageHeaderHeight)
            pageContent
                .frame(width: content.width, height: content.height)
                .clipped()
        }
        .onExitCommand { islandState.close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    private var title: String {
        page == .tools ? IslandTool.allTools.title : page.title
    }

    // MARK: Header

    /// The way back and the page's name on the left, the close button on the right. Beside a notch each side has
    /// about 97 pt: the back button and the close button fill it, and the name is left to VoiceOver (the page itself
    /// says what it is). The Tools page's "Edit Dock", Settings and Quit are in its dock strip at the bottom.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                backButton
                if !geometry.hasNotch { titleLabel }
            }
            Spacer(minLength: geometry.hasNotch ? geometry.notchRect.width + 16 : 8)
            closeButton
        }
        .padding(.horizontal, 12)
    }

    /// Back one step. When it leads to another page, its tooltip names it.
    private var backButton: some View {
        Button {
            islandState.closePage()
        } label: {
            headerCircle {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .help(islandState.backPage.map { String(localized: "Back to \($0.title)") } ?? String(localized: "Back"))
        .accessibilityLabel("Back")
    }

    private var titleLabel: some View {
        Text(verbatim: title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var closeButton: some View {
        Button {
            islandState.close()
        } label: {
            headerCircle {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
    }

    /// A 28 pt circle with a faint light fill, for a glyph.
    private func headerCircle<Glyph: View>(@ViewBuilder _ glyph: () -> Glyph) -> some View {
        glyph()
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(0.09)))
            .contentShape(Circle())
    }

    // MARK: Content

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .system:
            IslandSystemPage(islandState: islandState)
        case .tools:
            IslandAllToolsPage(islandState: islandState)
        }
    }
}

/// What the machine is doing, in the island: running apps and the meters (the Command Hub's view without its ports
/// row, switches and links, which have their own places on the island).
///
/// The numbers are refreshed every 2.5 s, as in the hub's popover, and only while this page is on screen: the loop
/// belongs to the view and ends with it.
struct IslandSystemPage: View {
    @ObservedObject var islandState: ZenithIslandState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZenithCommandHubView(
                onAreaCapture: { islandState.close(); ZenithToolActions.captureArea() },
                onFullscreenCapture: { islandState.close(); ZenithToolActions.captureScreen() },
                onScreenOCR: { islandState.close(); ScreenOCRCoordinator.shared.startAreaOCR() },
                onOpenClipboard: { islandState.close(); ClipboardPanelController.shared.show() },
                onOpenPreferences: { islandState.close(); ZenithToolActions.openSettings() },
                onQuit: { ZenithToolActions.quit() },
                onClose: {},
                inIsland: true
            )
        }
        .task {
            let lease = NetworkSpeedLease()
            lease.begin()
            defer { lease.end() }
            while !Task.isCancelled {
                ZenithCommandHubState.shared.refreshHardwareSnapshot()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
}
