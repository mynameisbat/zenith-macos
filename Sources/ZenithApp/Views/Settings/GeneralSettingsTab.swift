import SwiftUI
import ZenithCore

public struct GeneralSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZenithSettingsPage {
            ZenithSettingsSection("Startup") {
                ZenithSettingsRow(
                    "Open at Login",
                    subtitle: "Start Zenith in the menu bar when you log in.",
                    symbol: "power",
                    tint: ZenithTint.general
                ) {
                    Toggle("Open at Login", isOn: Binding(
                        get: { viewModel.isLaunchAtLoginEnabled },
                        set: { viewModel.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                if let error = viewModel.launchAtLoginError {
                    ZenithSettingsDivider()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ZenithTheme.warning)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open Login Items…") {
                            SystemLaunchAtLoginService.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }

            UpdatesSettingsSection()

            CleaningModeSettingsSection(viewModel: viewModel)

            ZenithSettingsSection(
                "Clipboard",
                footer: "When the history is full, the oldest unpinned item makes room for the next one. Pinned items always stay."
            ) {
                ZenithSettingsRow(
                    "History Size",
                    subtitle: "How many items to keep (5 to 500).",
                    symbol: "list.clipboard.fill",
                    tint: ZenithTint.clipboard
                ) {
                    HStack(spacing: 6) {
                        Text("\(viewModel.historyLimit) items")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 70, alignment: .trailing)
                        Stepper("History Size", value: $viewModel.historyLimit, in: 5...500, step: 5)
                            .labelsHidden()
                    }
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Clear History",
                    subtitle: "Remove every unpinned item now.",
                    symbol: "trash.fill",
                    tint: Color(nsColor: .systemRed)
                ) {
                    Button("Clear History…") {
                        viewModel.showClearConfirmation = true
                    }
                }
            }

            ClipboardPrivacySettingsSection()

            KeepAwakeSettingsSection()
            ScreenRecordingSettingsSection()

            HStack {
                Spacer()
                Button("Restore All Defaults") {
                    withAnimation(.zenithSpring) {
                        viewModel.resetAllDefaults()
                        IslandWidgetSettings.shared.resetToDefaults()
                        ClipboardPrivacySettings.shared.resetToDefaults()
                        UpdateSettings.shared.resetToDefaults()
                        KeepAwakeSettings.shared.resetToDefaults()
                        KeepAwakeHotKeyController.shared.apply()
                        ScreenRecordingSettings.shared.resetToDefaults()
                    }
                }
                .help("Put every setting, shortcut, sound and island widget back the way Zenith ships")
            }
        }
        .confirmationDialog(
            "Clear Clipboard History?",
            isPresented: $viewModel.showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Unpinned Items", role: .destructive) {
                viewModel.clearClipboardHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Pinned items are kept.")
        }
    }
}
