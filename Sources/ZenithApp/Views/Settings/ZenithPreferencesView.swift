import SwiftUI
import AppKit
import ZenithCore

/// An AppKit visual-effect view, for the translucent sidebar material SwiftUI's `Material` cannot pick.
struct ZenithVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

extension SettingsTab {
    var tint: Color {
        switch self {
        case .general: return ZenithTint.general
        case .shortcuts: return ZenithTint.shortcuts
        case .audio: return ZenithTint.audio
        case .island: return ZenithTint.island
        case .privacy: return ZenithTint.privacy
        case .cleaner: return ZenithTint.cleaner
        case .homebrew: return HomebrewSettingsTab.tint
        case .permissions: return ZenithTint.permissions
        }
    }
}

/// The Settings window, laid out like System Settings: a translucent sidebar of tinted icons on the left and the
/// chosen pane, with its title on top, on the right.
public struct ZenithPreferencesView: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel
    }

    private static let sidebarWidth: CGFloat = 210

    public var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: Self.sidebarWidth)
                .background(ZenithVisualEffect(material: .sidebar))

            Divider()

            detailPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: SettingsWindowController.defaultWidth, maxWidth: .infinity, minHeight: SettingsWindowController.defaultHeight, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear { if HomebrewSettingsLink.takePending() { viewModel.selectedTab = .homebrew } }
        .onReceive(NotificationCenter.default.publisher(for: HomebrewSettingsLink.notification)) { _ in
            _ = HomebrewSettingsLink.takePending()
            viewModel.selectedTab = .homebrew
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 44)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        identityRow
                    }

                    sidebarGroup(filteredTabs.filter { $0.sectionTitle == "WORKSPACE" })
                    sidebarGroup(filteredTabs.filter { $0.sectionTitle == "SYSTEM & SECURITY" })

                    if filteredTabs.isEmpty {
                        Text("No Results")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    /// The app's own row at the top, where System Settings shows the Apple Account.
    private var identityRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(ZenithTheme.appName)
                    .font(.system(size: 13, weight: .semibold))
                Text("Version \(ZenithTheme.appVersion)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var filteredTabs: [SettingsTab] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return SettingsTab.allCases
        }
        return SettingsTab.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query) ||
            $0.searchKeywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private func sidebarGroup(_ tabs: [SettingsTab]) -> some View {
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(tabs) { tab in
                    sidebarRow(tab)
                }
            }
        }
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = viewModel.selectedTab == tab
        let isHovered = viewModel.hoveredTab == tab

        return Button {
            viewModel.selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                ZenithIconTile(systemName: tab.iconName, tint: tab.tint, size: 20)
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? ZenithTheme.selection : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onHover { hovering in
            if hovering {
                viewModel.hoveredTab = tab
            } else if viewModel.hoveredTab == tab {
                viewModel.hoveredTab = nil
            }
        }
    }

    // MARK: - Detail Pane

    private var detailPaneView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.selectedTab.title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52)
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)

            Divider()

            Group {
                switch viewModel.selectedTab {
                case .general:
                    GeneralSettingsTab(viewModel: viewModel)
                case .shortcuts:
                    ShortcutsSettingsTab(viewModel: viewModel)
                case .audio:
                    AudioSettingsTab(viewModel: viewModel)
                case .island:
                    IslandSettingsTab()
                case .privacy:
                    PrivacySettingsTab()
                case .cleaner:
                    CleanerSettingsTab()
                case .homebrew:
                    HomebrewSettingsTab()
                case .permissions:
                    PermissionsGuideView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
