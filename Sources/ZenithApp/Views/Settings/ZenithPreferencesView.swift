import SwiftUI
import AppKit
import ZenithCore

extension SettingsTab {
    var tint: Color {
        switch self {
        case .general: return ZenithTint.general
        case .shortcuts: return ZenithTint.shortcuts
        case .audio: return ZenithTint.audio
        case .island: return ZenithTint.island
        case .snippets: return ZenithTint.snippets
        case .privacy: return ZenithTint.privacy
        case .ports: return ZenithTint.network
        case .cleaner: return ZenithTint.cleaner
        case .homebrew: return HomebrewSettingsTab.tint
        case .permissions: return ZenithTint.permissions
        case .displays: return ZenithTint.displays
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

    /// The sidebar is a floating pane inset from the window's edges, as macOS 26's own sidebar is: Liquid Glass in a
    /// window (a material with a hairline edge: `glassEffect` flattened the labels to the wrong colour in an off-screen
    /// window and gains nothing over an opaque window background).
    private static let paneShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var sidebarPane: some View {
        sidebarView
            .background(.regularMaterial, in: Self.paneShape)
            .background(Color.primary.opacity(0.03), in: Self.paneShape)
            .overlay(Self.paneShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
    }

    private static let sidebarWidth: CGFloat = 200

    public var body: some View {
        HStack(spacing: 0) {
            sidebarPane
                .frame(width: Self.sidebarWidth)
                .padding(10)

            detailPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: SettingsWindowController.defaultWidth, maxWidth: .infinity,
            minHeight: SettingsWindowController.defaultHeight, maxHeight: .infinity
        )
        .ignoresSafeArea()
        .onAppear {
            takePendingTab()
            if HomebrewSettingsLink.takePending() { viewModel.selectedTab = .homebrew }
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenithSelectSettingsTab)) { _ in takePendingTab() }
        .onReceive(NotificationCenter.default.publisher(for: HomebrewSettingsLink.notification)) { _ in
            _ = HomebrewSettingsLink.takePending()
            viewModel.selectedTab = .homebrew
        }
    }

    /// Shows the tab another part of the app asked for (`SettingsTab.requestSelection`).
    private func takePendingTab() {
        if let tab = SettingsTab.pendingSelection {
            SettingsTab.pendingSelection = nil
            viewModel.selectedTab = tab
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights, which sit on the pane.
            Color.clear.frame(height: 34)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.bottom, 10)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                // As System Settings does: the pane follows the search, so the content never shows a section the
                // sidebar has filtered away ("proxy" listed Privacy Shield while General stayed open).
                .onChange(of: viewModel.searchText) { _, _ in
                    let results = filteredTabs
                    if let first = results.first, !results.contains(viewModel.selectedTab) {
                        viewModel.selectedTab = first
                    }
                }
                .onSubmit {
                    if let first = filteredTabs.first { viewModel.selectedTab = first }
                }
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
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
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
            VStack(alignment: .leading, spacing: 2) {
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
            HStack(spacing: 10) {
                ZenithIconTile(systemName: tab.iconName, tint: tab.tint, size: 22, cornerRatio: 0.3)
                Text(tab.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? ZenithTheme.accent : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)

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
                case .snippets:
                    SnippetsSettingsTab()
                case .privacy:
                    PrivacySettingsTab()
                case .ports:
                    PortsSettingsTab()
                case .cleaner:
                    CleanerSettingsTab()
                case .homebrew:
                    HomebrewSettingsTab()
                case .permissions:
                    PermissionsGuideView(viewModel: viewModel)
                case .displays:
                    DisplaysSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
