import SwiftUI
import AppKit
import ZenithCore

/// A page of the island: a strip with the way back, the page's name and a close button, and below it one of
/// Zenith's tools, drawn where it used to have a window.
///
/// The tools are the same views the Command Hub and the Settings window show. The island's window is dark
/// (`ZenithIslandPanel` sets the appearance), so they arrive in their dark look on the island's black.
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
    }

    // MARK: Header

    /// Beside a notch the back button has the strip on its left and the page's name and the close button the strip on
    /// its right, like the tabs; without one they share a row.
    private var header: some View {
        HStack(spacing: 0) {
            backButton
            if geometry.hasNotch {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    titleLabel
                    appButtons
                    closeButton
                }
                .frame(width: sideStripWidth, alignment: .trailing)
            } else {
                titleLabel.padding(.leading, 8)
                Spacer(minLength: 8)
                appButtons.padding(.trailing, 6)
                closeButton
            }
        }
        .padding(.horizontal, 10)
    }

    /// The room either side of the notch, inside the header's padding.
    private var sideStripWidth: CGFloat {
        max(0, (geometry.pageContentSize(for: page).width - geometry.notchRect.width) / 2 - 10 - 4)
    }

    /// Back one step. It names the page it leads to; when it leads to the island as it opens, an arrow says that
    /// well enough.
    private var backButton: some View {
        Button {
            islandState.closePage()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                if let previous = islandState.backPage {
                    Text(verbatim: previous.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 22, minHeight: 18)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Back")
        .accessibilityLabel("Back")
    }

    private var titleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: page.icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(verbatim: page.title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(.white)
        .accessibilityAddTraits(.isHeader)
    }

    /// Settings and Quit, on the Tools page only, and apart from the tools on purpose: small, in the corner, where
    /// nobody reaching for a tool lands on Quit.
    @ViewBuilder
    private var appButtons: some View {
        if page == .tools {
            headerIconButton(.settings)
            headerIconButton(.quit)
        }
    }

    private func headerIconButton(_ tool: IslandTool) -> some View {
        Button {
            IslandToolStyle.activate(tool, islandState: islandState)
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(Text(verbatim: tool.title))
    }

    private var closeButton: some View {
        Button {
            islandState.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close")
    }

    // MARK: Content

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .system:
            IslandSystemPage(islandState: islandState)
        case .cleaner:
            CleanerSettingsTab()
        case .ports:
            PortsSettingsTab()
        case .homebrew:
            HomebrewSettingsTab()
        case .settings:
            IslandSettingsPage()
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
                onOpenPreferences: { islandState.openPage(.settings) },
                onQuit: { ZenithToolActions.quit() },
                // The hub closes itself before it opens something else; here that something is the next page.
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

/// Zenith's settings, in the island. The chosen pane lives here, so it survives the island redrawing itself (which
/// it does on every hover).
struct IslandSettingsPage: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        ZenithPreferencesView(viewModel: viewModel, inIsland: true)
    }
}
