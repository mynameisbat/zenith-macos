import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZenithCore

/// Settings → Cleaner → Uninstall: pick an installed app, see what goes with it, and move it to the Trash.
///
/// Everything that reads or removes files is in `AppUninstallerModel` and the `CleanupToolModel` it creates (Core);
/// this view only shows them. The picked app's list is the same `CleanupToolView` the other cleanup tools use.
struct AppUninstallerView: View {
    @ObservedObject var model: AppUninstallerModel
    @ObservedObject var projectRoots: ProjectSearchRootsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tool = model.tool, let app = model.selectedApp {
                AppUninstallerDetailBar(app: app) { model.back() }
                CleanupToolView(model: tool, projectRoots: projectRoots) {
                    await model.afterCleaning()
                }
            } else {
                header
                searchField
                appList
            }
        }
        .onAppear {
            if !model.hasLoaded { Task { await model.loadApps() } }
        }
    }

    // MARK: App list

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall an app")
                        .font(.system(size: 14, weight: .bold))
                    Text("Pick an app to see the files it keeps in your Library. Nothing is removed until you confirm, and everything goes to the Trash. Apps that are part of macOS are not listed.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button {
                        Task { await model.loadApps() }
                    } label: {
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 11.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isLoading)

                    Button {
                        chooseApp()
                    } label: {
                        Label("Choose App…", systemImage: "folder").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pick an app that is not in the Applications folder")
                }
            }
            if let notice = model.notice {
                Text(verbatim: notice).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 14)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
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

    @ViewBuilder
    private var appList: some View {
        let shown = model.filteredApps
        if model.isLoading && model.apps.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for apps…").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else if shown.isEmpty {
            Text(model.apps.isEmpty ? "No apps found in the Applications folders." : "No app matches your search.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(shown, id: \.bundlePath) { app in
                    AppUninstallerRow(app: app) {
                        Task { await model.select(app) }
                    }
                }
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 8)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Choose App")
        IslandDialogs.raiseAboveIsland(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.choose(appAtPath: url.path) }
    }
}

/// One installed app in the list. The whole row is the button.
private struct AppUninstallerRow: View {
    let app: InstalledAppInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: "\(app.version) · \((app.bundlePath as NSString).abbreviatingWithTildeInPath)")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Above a picked app's list: the way back, and which app this is.
private struct AppUninstallerDetailBar: View {
    let app: InstalledAppInfo
    let back: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: back) {
                Label("All Apps", systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: "\(app.displayName) \(app.version)")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: app.bundleIdentifier)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }
}
