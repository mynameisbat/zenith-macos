import SwiftUI
import GoldenGateCore

/// Redesigned macOS Sequoia / Apple Design Award Preferences window with Sidebar navigation.
public struct ZenithPreferencesView: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel
    }

    private func closeSettings() {
        SettingsWindowController.shared.dismiss()
        for win in NSApp.windows where win is SettingsWindow {
            win.orderOut(nil)
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            // 1. Left Sidebar (Navigation Pane)
            sidebarView
                .frame(width: 200)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)

            // 2. Right Detail Pane (Tab Content)
            detailPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.015))
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 490, maxHeight: .infinity)
    }


    // MARK: - Sidebar View

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Window Traffic Light Controls Bar
            HStack(spacing: 7) {
                Button {
                    closeSettings()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: .systemRed).opacity(0.9))
                            .frame(width: 12, height: 12)
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundColor(Color.black.opacity(0.65))
                            .opacity(viewModel.isCloseHovered ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    viewModel.isCloseHovered = hovering
                }
                .help("Close Settings Studio (Esc)")

                Circle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 12, height: 12)

                Circle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 12, height: 12)

                Spacer()
            }
            .padding(.leading, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // App Brand Header
            HStack(spacing: 12) {
                if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(ZenithTheme.appName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)

                    Text("Settings Studio")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)

            // Search Filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search settings...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            // Navigation Sections
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection(
                        title: "WORKSPACE",
                        tabs: filteredTabs.filter { $0.sectionTitle == "WORKSPACE" }
                    )

                    sidebarSection(
                        title: "SYSTEM & SECURITY",
                        tabs: filteredTabs.filter { $0.sectionTitle == "SYSTEM & SECURITY" }
                    )
                }
                .padding(.horizontal, 10)
            }

            Spacer()

            // Footer Version Info & Close Button
            HStack {
                Text("Zenith v\(ZenithTheme.appVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
                Button {
                    closeSettings()
                } label: {
                    Text("Close")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Close Settings Studio (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var filteredTabs: [SettingsTab] {
        if viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return SettingsTab.allCases
        }
        return SettingsTab.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(viewModel.searchText) ||
            $0.subtitle.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    private func sidebarSection(title: String, tabs: [SettingsTab]) -> some View {
        Group {
            if !tabs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                        .tracking(0.6)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)

                    ForEach(tabs) { tab in
                        sidebarRow(tab)
                    }
                }
            }
        }
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = viewModel.selectedTab == tab
        let isHovered = viewModel.hoveredTab == tab

        return Button {
            withAnimation(.goldenGateSpring) {
                viewModel.selectedTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? ZenithTheme.accent.opacity(0.2) : Color.primary.opacity(0.06))
                        .frame(width: 26, height: 26)

                    Image(systemName: tab.iconName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? ZenithTheme.accent : .primary.opacity(0.8))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .primary : .primary.opacity(0.85))

                    Text(tab.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? ZenithTheme.accent.opacity(0.14)
                            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected
                            ? ZenithTheme.accent.opacity(0.28)
                            : (isHovered ? Color.primary.opacity(0.08) : Color.clear),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                viewModel.hoveredTab = tab
            } else if viewModel.hoveredTab == tab {
                viewModel.hoveredTab = nil
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered || isSelected)
    }

    // MARK: - Detail Pane View

    private var detailPaneView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedTab.rawValue)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.primary)

                    Text(tabDescription(for: viewModel.selectedTab))
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Explicit, clickable Close Button with keyboard shortcuts
                Button {
                    closeSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("esc")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut("w", modifiers: .command)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close Settings Studio (Esc)")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)

            // Active Tab Content
            Group {
                switch viewModel.selectedTab {
                case .general:
                    GeneralSettingsTab(viewModel: viewModel)
                case .shortcuts:
                    ShortcutsSettingsTab(viewModel: viewModel)
                case .audio:
                    AudioSettingsTab(viewModel: viewModel)
                case .privacy:
                    PrivacySettingsTab()
                case .cleaner:
                    CleanerSettingsTab()
                case .permissions:
                    PermissionsGuideView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabDescription(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return "Configure login launch behavior and clipboard retention limits."
        case .shortcuts:
            return "Customize global keyboard shortcuts for clipboard and screenshot capture."
        case .audio:
            return "Enable or disable audio feedback and sound effects."
        case .privacy:
            return "Protect network traffic with Cloudflare DNS-over-HTTPS local proxy."
        case .cleaner:
            return "Scan and safely purge developer caches, logs, and build artifacts."
        case .permissions:
            return "Review Screen Recording and Accessibility permissions status."
        }
    }
}
