import SwiftUI
import ZenithCore

/// Settings → General → Cleaning Mode: time limit, look, the optional global shortcut, and a button to start it.
struct CleaningModeSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var settings: CleaningModeSettings = .shared

    var body: some View {
        ZenithSettingsSection(
            "Cleaning Mode",
            footer: "Blocks the keyboard, trackpad and mouse, media and brightness keys included, so you can wipe them. It always ends by itself when the time is up; to stop early, hold ⌃ ⌥ ⌘ for 2 seconds. Needs Accessibility."
        ) {
            ZenithSettingsRow(
                "Time Limit",
                subtitle: "Input comes back by itself after this long.",
                symbol: "timer",
                tint: ZenithTint.timer
            ) {
                Picker("Time Limit", selection: Binding(
                    get: { settings.durationSeconds },
                    set: { settings.durationSeconds = $0 }
                )) {
                    ForEach(CleaningModeSettings.durationChoices, id: \.self) { seconds in
                        Text(verbatim: CleaningModeSettings.durationText(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Screen",
                subtitle: "Black shows smudges best; Dimmed keeps the screen in view.",
                symbol: "display",
                tint: ZenithTint.screen
            ) {
                Picker("Screen", selection: Binding(
                    get: { settings.appearance },
                    set: { settings.appearance = $0 }
                )) {
                    ForEach(CleaningModeAppearance.allCases) { appearance in
                        Text(verbatim: appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Global Shortcut",
                subtitle: "Start Cleaning Mode from any app.",
                symbol: "command",
                tint: ZenithTint.shortcuts
            ) {
                HStack(spacing: 8) {
                    if settings.hotKeyEnabled {
                        let id = HotKeyDefinition.cleaningModeId
                        InteractiveShortcutRecorderView(
                            id: id,
                            title: String(localized: "Cleaning Mode"),
                            currentDefinition: viewModel.hotkey(for: id) ?? HotKeyDefinition.defaultCleaningMode,
                            onUpdate: { viewModel.updateHotkey($0) }
                        )
                    }
                    Toggle("Global Shortcut", isOn: Binding(
                        get: { settings.hotKeyEnabled },
                        set: { isOn in
                            settings.hotKeyEnabled = isOn
                            CleaningModeCoordinator.shared.applyHotKeySetting()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Start Cleaning Mode",
                subtitle: "Blocks input on every display right away.",
                symbol: "keyboard",
                tint: ZenithTint.general
            ) {
                Button("Start") {
                    CleaningModeCoordinator.shared.start()
                }
                .controlSize(.small)
            }
        }
    }
}
