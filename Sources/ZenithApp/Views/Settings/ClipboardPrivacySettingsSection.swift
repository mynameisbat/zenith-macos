import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZenithCore

/// Settings → General, under Clipboard: clearing the clipboard, cleaning copied links, and the apps whose copies are
/// never kept.
struct ClipboardPrivacySettingsSection: View {
    /// Which settings the section shows. `--render-screenshots` swaps in made-up ones, so a picture never lists the
    /// apps this Mac's owner chose to ignore.
    @MainActor static var settingsProvider: () -> ClipboardPrivacySettings = { .shared }

    @ObservedObject var settings: ClipboardPrivacySettings

    init(settings: ClipboardPrivacySettings? = nil) {
        self.settings = settings ?? Self.settingsProvider()
    }

    var body: some View {
        ZenithSettingsSection(
            "Clipboard Privacy",
            footer: "Copies that the app marks as a password or as temporary are never kept. Clearing empties the clipboard only if it still holds that copy, and the history keeps the item."
        ) {
            ZenithSettingsRow(
                "Clear Clipboard",
                subtitle: "Empty the clipboard a while after you copy something.",
                symbol: "timer",
                tint: ZenithTint.clipboard
            ) {
                Picker("Clear Clipboard", selection: $settings.autoClearDelay) {
                    ForEach(ClipboardAutoClearDelay.allCases) { delay in
                        Text(verbatim: delay.title).tag(delay)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Clear When the Mac Locks",
                subtitle: "Empty the clipboard when the screen locks or the Mac goes to sleep.",
                symbol: "lock.fill",
                tint: ZenithTint.clipboard
            ) {
                Toggle("Clear When the Mac Locks", isOn: $settings.clearOnLock)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Clean Links When I Copy Them",
                subtitle: "Remove tracking parameters such as utm_source from a copied web link.",
                symbol: "link",
                tint: ZenithTint.clipboard
            ) {
                Toggle("Clean Links When I Copy Them", isOn: $settings.cleanLinksOnCopy)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        ZenithSettingsSection(
            "Ignored Apps",
            footer: "Nothing you copy while one of these apps is in front is kept in the history."
        ) {
            ForEach(settings.ignoredAppBundleIdentifiers, id: \.self) { bundleID in
                IgnoredAppRow(bundleIdentifier: bundleID) {
                    withAnimation(.zenithSpring) {
                        settings.removeIgnoredApp(bundleIdentifier: bundleID)
                    }
                }
                ZenithSettingsDivider(inset: 44)
            }

            if settings.ignoredAppBundleIdentifiers.isEmpty {
                Text("No ignored apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                ZenithSettingsDivider()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Menu("Add Running App") {
                    let running = runningApps
                    if running.isEmpty {
                        Text("No other apps are open")
                    }
                    ForEach(running, id: \.bundleIdentifier) { app in
                        Button {
                            settings.addIgnoredApp(bundleIdentifier: app.bundleIdentifier)
                        } label: {
                            Text(verbatim: app.name)
                        }
                    }
                }
                .fixedSize()

                Button("Choose App…") {
                    chooseApp()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    /// Open apps with a window and a bundle identifier, not already ignored, by name.
    private var runningApps: [(bundleIdentifier: String, name: String)] {
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleIdentifier: String, name: String)? in
                guard let id = app.bundleIdentifier, id != ownID,
                      !settings.isIgnored(bundleIdentifier: id),
                      seen.insert(id.lowercased()).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Ignore")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                settings.addIgnoredApp(bundleIdentifier: id)
            }
        }
    }
}

/// One ignored app: its icon and name when it is installed, with the bundle identifier under it.
private struct IgnoredAppRow: View {
    let bundleIdentifier: String
    let onRemove: () -> Void

    var body: some View {
        let info = Self.appInfo(for: bundleIdentifier)
        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZenithIconTile(systemName: "app.dashed", tint: ZenithTint.general, size: 22)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: info.name)
                    .font(.system(size: 13))
                Text(verbatim: bundleIdentifier)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Keep copies from this app again")
            .accessibilityLabel(Text("Remove \(info.name)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private static func appInfo(for bundleIdentifier: String) -> (name: String, icon: NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (ClipboardPrivacySettings.knownName(for: bundleIdentifier) ?? bundleIdentifier, nil)
    }
}
