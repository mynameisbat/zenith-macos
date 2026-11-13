import SwiftUI
import AppKit
import ZenithCore

// Settings → Homebrew. The page is split into small view structs on purpose: one big `some View` tree here was deep
// enough to overflow the main thread's stack while SwiftUI instantiated its type in a debug build.

/// Opens Settings on the Homebrew tab (from the Command Hub). The window may not exist yet when asked, so the request
/// is also kept until the Settings view appears.
@MainActor
enum HomebrewSettingsLink {
    static let notification = Notification.Name("zenith.showHomebrewSettings")
    private static var isPending = false

    static func request() {
        isPending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func takePending() -> Bool {
        defer { isPending = false }
        return isPending
    }
}

/// What is installed, what is outdated, search, and a queue of brew commands with a live log. Everything that changes
/// the Mac goes through `HomebrewManagerModel` (Core), which confirms removals and upgrades.
public struct HomebrewSettingsTab: View {
    nonisolated static let tint = Color(nsColor: .systemBrown)

    @ObservedObject private var model: HomebrewManagerModel

    public init(model: HomebrewManagerModel = .shared) {
        self.model = model
    }

    public var body: some View {
        content
            .onAppear {
                if model.brewPath == nil { model.locate() }
                if model.brewPath != nil && !model.hasLoaded {
                    Task { await model.refresh() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .unknown:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            HomebrewMissingView(model: model)
        case .available(let path):
            HomebrewManagerView(model: model, brewPath: path)
        }
    }
}

// MARK: - brew is not installed

private struct HomebrewMissingView: View {
    @ObservedObject var model: HomebrewManagerModel
    private static let website = URL(string: "https://brew.sh")!

    var body: some View {
        ZenithSettingsPage {
            ZenithSettingsSection(footer: "Zenith never installs Homebrew itself. Install it from its website by pasting the command shown there into Terminal, then come back here.") {
                ZenithSettingsRow(
                    "Homebrew is not installed",
                    subtitle: "Homebrew installs command-line tools and apps with one command and keeps them up to date. Zenith looked in /opt/homebrew and /usr/local.",
                    symbol: "shippingbox.fill",
                    tint: HomebrewSettingsTab.tint
                )
                ZenithSettingsDivider()
                HStack(spacing: 8) {
                    Spacer()
                    Button("Check Again") {
                        if model.locate() != nil {
                            Task { await model.refresh() }
                        }
                    }
                    Button("Open brew.sh") {
                        NSWorkspace.shared.open(Self.website)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
    }
}

// MARK: - The manager

/// Which list shows and whether the log is open. (Not `@State`: the SwiftUI macro plugin is not available to a
/// Command Line Tools build.)
private final class HomebrewViewState: ObservableObject {
    enum Section: Hashable {
        case installed, updates, search
    }

    @Published var section: Section = .installed
    @Published var showsLog = false
}

private struct HomebrewManagerView: View {
    @ObservedObject var model: HomebrewManagerModel
    let brewPath: String
    @StateObject private var state = HomebrewViewState()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Homebrew", selection: $state.section) {
                Text("Installed").tag(HomebrewViewState.Section.installed)
                Text(model.upgradable.isEmpty ? "Updates" : "Updates (\(model.upgradable.count))").tag(HomebrewViewState.Section.updates)
                Text("Search").tag(HomebrewViewState.Section.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 2)

            ZenithSettingsPage {
                sectionContent
            }

            if !model.jobs.isEmpty || !model.log.text.isEmpty {
                Divider()
                HomebrewActivityPanel(model: model, state: state)
            }
        }
    }

    private var sectionContent: AnyView {
        switch state.section {
        case .installed: return AnyView(HomebrewInstalledSection(model: model, brewPath: brewPath))
        case .updates: return AnyView(HomebrewUpdatesSection(model: model))
        case .search: return AnyView(HomebrewSearchSection(model: model))
        }
    }
}

// MARK: Installed

private struct HomebrewInstalledSection: View {
    @ObservedObject var model: HomebrewManagerModel
    let brewPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            list
        }
    }

    private var header: some View {
        ZenithSettingsSection {
            ZenithSettingsRow(
                title: Text("Homebrew"),
                subtitle: Text(verbatim: brewPath),
                symbol: "shippingbox.fill",
                tint: HomebrewSettingsTab.tint
            ) {
                HStack(spacing: 6) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isRefreshing)
                    .help("Read the installed and outdated packages again")

                    HomebrewUpdateButton(model: model)
                }
                .controlSize(.small)
            }
            if let error = model.refreshError {
                ZenithSettingsDivider()
                ZenithSettingsNotice(text: error)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        let casks = model.installed.filter { $0.kind == .cask }
        let formulae = model.installed.filter { $0.kind == .formula }
        if model.installed.isEmpty {
            Text(model.hasLoaded ? "Nothing is installed with Homebrew yet. Use Search to find something." : "Reading what Homebrew has installed…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        if !casks.isEmpty {
            ZenithSettingsSection(casks.count == 1 ? "1 App" : "\(casks.count) Apps") {
                HomebrewRows(packages: casks) { HomebrewInstalledRow(model: model, package: $0) }
            }
        }
        if !formulae.isEmpty {
            ZenithSettingsSection(formulae.count == 1 ? "1 Command-Line Tool" : "\(formulae.count) Command-Line Tools") {
                HomebrewRows(packages: formulae) { HomebrewInstalledRow(model: model, package: $0) }
            }
        }
    }
}

/// Rows with hairlines between them.
private struct HomebrewRows<Item: Identifiable, Row: View>: View {
    let packages: [Item]
    let row: (Item) -> Row

    var body: some View {
        ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
            if index > 0 { ZenithSettingsDivider(inset: 42) }
            row(package)
        }
    }
}

private struct HomebrewUpdateButton: View {
    @ObservedObject var model: HomebrewManagerModel

    var body: some View {
        Button("Update Homebrew") {
            model.update()
        }
        .disabled(model.isQueued(.update))
        .help("Run brew update: fetch the newest package list, so new versions show up")
    }
}

private struct HomebrewInstalledRow: View {
    @ObservedObject var model: HomebrewManagerModel
    let package: HomebrewPackage

    var body: some View {
        let outdated = model.outdatedEntry(for: package)
        HStack(alignment: .center, spacing: 10) {
            HomebrewKindIcon(kind: package.kind)
            HomebrewInstalledLabel(package: package, outdated: outdated)
            if let bytes = package.bytes {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let outdated, !outdated.isPinned {
                Button("Upgrade") {
                    model.upgrade(outdated)
                }
                .controlSize(.small)
                .disabled(model.isQueued(.upgrade(names: [outdated.name], kind: outdated.kind)))
            }
            uninstallButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var uninstallButton: some View {
        Button {
            model.uninstall(package) { confirmation in
                DestructiveConfirmation.confirm(
                    verbatimTitle: confirmation.title,
                    message: confirmation.message,
                    destructiveTitle: confirmation.actionTitle
                )
            }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.isQueued(.uninstall(name: package.name, kind: package.kind)))
        .help("Uninstall")
        .accessibilityLabel("Uninstall \(package.displayName)")
    }
}

private struct HomebrewInstalledLabel: View {
    let package: HomebrewPackage
    let outdated: HomebrewOutdatedPackage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: package.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(verbatim: package.version)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !package.isInstalledOnRequest {
                    HomebrewTag(text: "Dependency")
                }
                if package.isPinned {
                    HomebrewTag(text: "Pinned")
                }
                if let outdated {
                    Text(verbatim: "→ \(outdated.currentVersion)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ZenithTheme.warning)
                        .lineLimit(1)
                }
            }
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let summary = package.summary ?? ""
        guard package.displayName != package.name else { return summary }
        return summary.isEmpty ? package.name : "\(package.name) · \(summary)"
    }
}

// MARK: Updates

private struct HomebrewUpdatesSection: View {
    @ObservedObject var model: HomebrewManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZenithSettingsSection(footer: "Homebrew only knows about new versions after it updates its package list. Pinned formulae are left as they are.") {
                ZenithSettingsRow(title: Text(headline), symbol: "arrow.up.circle.fill", tint: HomebrewSettingsTab.tint) {
                    HStack(spacing: 6) {
                        HomebrewUpdateButton(model: model)
                        Button("Upgrade All…") {
                            model.upgradeAll { confirmation in
                                DestructiveConfirmation.confirm(
                                    verbatimTitle: confirmation.title,
                                    message: confirmation.message,
                                    destructiveTitle: confirmation.actionTitle
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.upgradable.isEmpty)
                    }
                    .controlSize(.small)
                }
            }
            if !model.outdated.isEmpty {
                ZenithSettingsSection {
                    HomebrewRows(packages: model.outdated) { HomebrewOutdatedRow(model: model, entry: $0) }
                }
            }
        }
    }

    private var headline: LocalizedStringKey {
        let count = model.upgradable.count
        if !model.hasLoaded { return "Checking for updates…" }
        if count == 0 { return "Everything is up to date" }
        return count == 1 ? "1 package can be upgraded" : "\(count) packages can be upgraded"
    }
}

private struct HomebrewOutdatedRow: View {
    @ObservedObject var model: HomebrewManagerModel
    let entry: HomebrewOutdatedPackage

    var body: some View {
        HStack(spacing: 10) {
            HomebrewKindIcon(kind: entry.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(verbatim: "\(entry.installedVersion) → \(entry.currentVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if entry.isPinned {
                HomebrewTag(text: "Pinned")
            } else {
                Button("Upgrade") {
                    model.upgrade(entry)
                }
                .controlSize(.small)
                .disabled(model.isQueued(.upgrade(names: [entry.name], kind: entry.kind)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: Search

private struct HomebrewSearchSection: View {
    @ObservedObject var model: HomebrewManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            searchField
            results
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search formulae and casks", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.search() } }
            Button {
                Task { await model.search() }
            } label: {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Search")
                }
            }
            .disabled(model.isSearching || HomebrewCommand.normalizedQuery(model.searchQuery) == nil)
        }
    }

    @ViewBuilder
    private var results: some View {
        let casks = model.searchResults.filter { $0.kind == .cask }
        let formulae = model.searchResults.filter { $0.kind == .formula }
        if let error = model.searchError {
            ZenithSettingsSection {
                ZenithSettingsNotice(text: error)
            }
        } else if model.hasSearched && model.searchResults.isEmpty && !model.isSearching {
            Text("Nothing found.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        if !formulae.isEmpty {
            ZenithSettingsSection("Command-Line Tools") {
                HomebrewRows(packages: formulae) { HomebrewSearchRow(model: model, package: $0) }
            }
        }
        if !casks.isEmpty {
            ZenithSettingsSection("Apps") {
                HomebrewRows(packages: casks) { HomebrewSearchRow(model: model, package: $0) }
            }
        }
    }
}

private struct HomebrewSearchRow: View {
    @ObservedObject var model: HomebrewManagerModel
    let package: HomebrewPackage

    var body: some View {
        HStack(spacing: 10) {
            HomebrewKindIcon(kind: package.kind)
            label
            if let homepage {
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open the homepage")
                .accessibilityLabel("Open the homepage of \(package.name)")
            }
            if package.isInstalled || model.isInstalled(package.name, kind: package.kind) {
                ZenithStatusBadge(text: "Installed", kind: .ok)
            } else {
                Button("Install") {
                    model.install(package)
                }
                .controlSize(.small)
                .disabled(model.isQueued(.install(name: package.name, kind: package.kind)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var homepage: URL? {
        guard let url = package.homepage.flatMap(URL.init(string:)), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private var summary: String {
        [package.displayName != package.name ? package.displayName : nil, package.summary].compactMap { $0 }.joined(separator: " · ")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: package.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(verbatim: package.version)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity and log

private struct HomebrewActivityPanel: View {
    @ObservedObject var model: HomebrewManagerModel
    @ObservedObject var state: HomebrewViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            logToggle
            if state.showsLog {
                HomebrewLogView(model: model)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var status: some View {
        if let job = model.currentJob {
            HomebrewRunningLine(model: model, job: job)
        } else if let last = model.jobs.last(where: \.isFinished) {
            if let failure = last.failure {
                HomebrewFailureView(job: last, failure: failure)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ZenithTheme.success)
                    Text(verbatim: last.operation.title)
                        .font(.system(size: 12, weight: .medium))
                    Text("Done")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var logToggle: some View {
        HStack {
            Button {
                state.showsLog.toggle()
            } label: {
                Label(state.showsLog ? "Hide Log" : "Show Log", systemImage: state.showsLog ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            Spacer()
            if state.showsLog && !model.log.text.isEmpty {
                Button("Clear") { model.clearLog() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .disabled(model.isBusy)
            }
        }
    }
}

private struct HomebrewRunningLine: View {
    @ObservedObject var model: HomebrewManagerModel
    let job: HomebrewJob

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: job.operation.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            let waiting = model.pendingJobs.count
            if waiting > 0 {
                Text(waiting == 1 ? "1 more waiting" : "\(waiting) more waiting")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                model.cancel(job.id)
            }
            .controlSize(.small)
            .help("Stop this command")
        }
    }
}

private struct HomebrewFailureView: View {
    let job: HomebrewJob
    let failure: HomebrewFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: failure == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failure == .cancelled ? Color.secondary : ZenithTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: job.operation.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(verbatim: failure.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let command = failure.terminalCommand {
                HomebrewTerminalCommand(command: command)
            }
        }
    }
}

/// The command to run in Terminal, where sudo can ask for the password.
private struct HomebrewTerminalCommand: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 4)
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            Button("Open Terminal") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            }
        }
        .controlSize(.small)
    }
}

private struct HomebrewLogView: View {
    @ObservedObject var model: HomebrewManagerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.log.text.isEmpty ? " " : model.log.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                .padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
            .onValueChange(of: model.log.text.count) { _ in
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }
}

// MARK: - Pieces

private struct HomebrewKindIcon: View {
    let kind: HomebrewPackageKind

    var body: some View {
        Image(systemName: kind == .cask ? "app.dashed" : "terminal")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .help(kind == .cask ? "App (cask)" : "Command-line tool (formula)")
    }
}

private struct HomebrewTag: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()
    }
}
