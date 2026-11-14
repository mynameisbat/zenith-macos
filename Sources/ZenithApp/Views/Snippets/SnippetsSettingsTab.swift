import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZenithCore

/// What the Snippets page shows besides the stores: the snippet being edited and the last import/export message.
@MainActor
final class SnippetsSettingsUIModel: ObservableObject {
    @Published var editor: SnippetEditorModel?
    @Published var message: String?
}

/// Settings → Snippets: typed expansion on/off, the snippets (add, edit, delete, import, export) and the apps where
/// triggers never expand.
struct SnippetsSettingsTab: View {
    @ObservedObject var library: SnippetLibrary
    @ObservedObject var settings: SnippetSettings
    @ObservedObject var service: SnippetExpansionService
    @StateObject private var ui = SnippetsSettingsUIModel()

    init(
        library: SnippetLibrary = .shared,
        settings: SnippetSettings = .shared,
        service: SnippetExpansionService = .shared
    ) {
        self.library = library
        self.settings = settings
        self.service = service
    }

    var body: some View {
        ZenithSettingsPage {
            typingSection
            snippetsSection
            excludedAppsSection
        }
        .onAppear { service.refresh() }
        .sheet(item: $ui.editor) { editor in
            SnippetEditorSheet(editor: editor) { ui.editor = nil }
        }
    }

    // MARK: Typing

    private var typingSection: some View {
        ZenithSettingsSection(
            "Typing",
            footer: "Type a snippet's trigger in any app and it is replaced by the snippet. Never in password fields, in the apps the clipboard ignores, or in the apps listed below. The snippet menu inserts a snippet by name."
        ) {
            ZenithSettingsRow(
                "Expand Snippets as You Type",
                subtitle: "Watches your typing for triggers. Needs Accessibility.",
                symbol: "keyboard",
                tint: ZenithTint.snippets
            ) {
                Toggle("Expand Snippets as You Type", isOn: $settings.isTypedExpansionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if service.needsAccessibility {
                ZenithSettingsDivider()
                HStack(spacing: 8) {
                    ZenithSettingsNotice(text: String(localized: "Zenith needs Accessibility permission to see what you type and to insert snippets."))
                    Button("Open Settings") {
                        _ = SystemPermissions.requestAccessibilityPermission()
                        _ = SystemPermissions.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                    Button("Check Again") { service.refresh() }
                        .controlSize(.small)
                        .padding(.trailing, 12)
                }
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Snippet Menu",
                subtitle: "Search your snippets and insert one. Change the shortcut in Shortcuts.",
                symbol: "text.magnifyingglass",
                tint: ZenithTint.snippets
            ) {
                ZenithShortcutText(
                    SettingsStore.shared.effectiveHotkey(for: HotKeyDefinition.snippetsMenuId)?.menuStyleKeyEquivalent
                        ?? HotKeyDefinition.defaultSnippetsMenu.menuStyleKeyEquivalent
                )
            }
        }
    }

    // MARK: Snippets

    private var snippetsSection: some View {
        ZenithSettingsSection(
            "Snippets",
            footer: "Variables: {clipboard}, {date}, {time}, {datetime}, and {cursor} for where the caret ends up. A date can take a format, such as {date:yyyy-MM-dd}."
        ) {
            if let error = library.lastError {
                ZenithSettingsNotice(text: error)
                ZenithSettingsDivider()
            }
            if let message = ui.message {
                ZenithSettingsNotice(text: message, symbol: "info.circle.fill", tint: ZenithTheme.accent)
                ZenithSettingsDivider()
            }

            ForEach(library.snippets) { snippet in
                SnippetRow(
                    snippet: snippet,
                    issues: SnippetTriggerRules.issues(for: snippet, among: library.snippets),
                    onEdit: { edit(snippet) },
                    onDelete: { delete(snippet) }
                )
                ZenithSettingsDivider()
            }

            if library.snippets.isEmpty {
                Text("No snippets yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                ZenithSettingsDivider()
            }

            HStack(spacing: 8) {
                Button("Import…") { importFile() }
                Button("Export…") { exportFile() }
                    .disabled(library.snippets.isEmpty)
                Spacer(minLength: 0)
                Button("Add Snippet") { edit(nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func edit(_ snippet: Snippet?) {
        let service = self.service
        ui.editor = SnippetEditorModel(snippet: snippet, library: library) { service.expand($0) }
    }

    private func delete(_ snippet: Snippet) {
        guard DestructiveConfirmation.confirm(
            verbatimTitle: String(localized: "Delete “\(snippet.displayName)”?"),
            message: String(localized: "The snippet is removed. Export your snippets first if you may want it back."),
            destructiveTitle: String(localized: "Delete")
        ) else { return }
        library.delete(id: snippet.id)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try library.importSnippets(from: Data(contentsOf: url))
            ui.message = String(localized: "Imported \(result.added) new and \(result.replaced) updated snippets.")
        } catch {
            ui.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Zenith Snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportData().write(to: url, options: .atomic)
            ui.message = library.snippets.count == 1
                ? String(localized: "Exported 1 snippet.")
                : String(localized: "Exported \(library.snippets.count) snippets.")
        } catch {
            ui.message = error.localizedDescription
        }
    }

    // MARK: Excluded apps

    private var excludedAppsSection: some View {
        ZenithSettingsSection(
            "Apps Without Snippets",
            footer: "Triggers you type in these apps are left as they are. The apps the clipboard ignores (Settings → General) are left alone too."
        ) {
            ForEach(settings.excludedAppBundleIdentifiers, id: \.self) { bundleID in
                SnippetExcludedAppRow(bundleIdentifier: bundleID) {
                    settings.removeExcludedApp(bundleIdentifier: bundleID)
                }
                ZenithSettingsDivider(inset: 44)
            }

            if settings.excludedAppBundleIdentifiers.isEmpty {
                Text("No apps excluded.")
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
                            settings.addExcludedApp(bundleIdentifier: app.bundleIdentifier)
                        } label: {
                            Text(verbatim: app.name)
                        }
                    }
                }
                .fixedSize()

                Button("Choose App…") { chooseApp() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var runningApps: [(bundleIdentifier: String, name: String)] {
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleIdentifier: String, name: String)? in
                guard let id = app.bundleIdentifier, id != ownID,
                      !settings.isExcluded(bundleIdentifier: id),
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
        panel.prompt = String(localized: "Exclude")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                settings.addExcludedApp(bundleIdentifier: id)
            }
        }
    }
}

// MARK: - Rows

private struct SnippetRow: View {
    let snippet: Snippet
    let issues: [SnippetTriggerIssue]
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: snippet.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if !snippet.trigger.isEmpty {
                        Text(verbatim: snippet.trigger)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(verbatim: snippet.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        Text(verbatim: issue.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZenithTheme.warning)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button("Edit", action: onEdit)
                .controlSize(.small)
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete this snippet")
            .accessibilityLabel(Text("Delete \(snippet.displayName)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

private struct SnippetExcludedAppRow: View {
    let bundleIdentifier: String
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleIdentifier
        HStack(spacing: 10) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZenithIconTile(systemName: "app.dashed", tint: ZenithTint.general, size: 22)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
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
            .help("Expand snippets in this app again")
            .accessibilityLabel(Text("Remove \(name)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Editor

/// Adds or edits one snippet, with a live preview of what it inserts.
private struct SnippetEditorSheet: View {
    @ObservedObject var editor: SnippetEditorModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (editor.isNew ? Text("New Snippet") : Text("Edit Snippet"))
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Email signature", text: $editor.name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Trigger")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Trigger", text: $editor.trigger, prompt: Text(verbatim: ";sig"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        Text("Optional. A short word you would not type by accident, such as ;sig.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ForEach(Array(editor.issues.enumerated()), id: \.offset) { _, issue in
                            Label {
                                Text(verbatim: issue.message)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZenithTheme.warning)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Text")
                    Spacer()
                    Menu("Insert Variable") {
                        ForEach(SnippetExpander.variables, id: \.self) { variable in
                            Button {
                                editor.appendVariable(variable)
                            } label: {
                                Text(verbatim: "{\(variable)}")
                            }
                        }
                    }
                    .fixedSize()
                }
                TextEditor(text: $editor.body)
                    .font(.system(size: 13))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: editor.previewText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 64)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                Text("Shown with the clipboard and time right now; | marks where the caret ends up.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if editor.save() { onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
