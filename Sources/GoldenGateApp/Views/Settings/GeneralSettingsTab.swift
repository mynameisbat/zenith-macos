import SwiftUI
import GoldenGateCore

public struct GeneralSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. System Integration Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("SYSTEM INTEGRATION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(
                            "Launch Zenith at system login",
                            isOn: Binding(
                                get: { viewModel.isLaunchAtLoginEnabled },
                                set: { viewModel.setLaunchAtLogin($0) }
                            )
                        )
                        .toggleStyle(.checkbox)

                        Text("Automatically starts Zenith in the menu bar when your Mac boots.")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)

                        if let error = viewModel.launchAtLoginError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button("Open Login Items...") {
                                    SystemLaunchAtLoginService.openLoginItemsSettings()
                                }
                                .font(.system(size: 11))
                            }
                            .padding(.top, 2)
                        }
                    }
                    .zenithSettingsCard()
                }

                // 2. Clipboard History Capacity Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("CLIPBOARD HISTORY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("History Capacity:")
                                .font(.system(size: 12.5))
                            Spacer()
                            HStack(spacing: 8) {
                                Text("\(viewModel.historyLimit) items")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()

                                Stepper(
                                    "",
                                    value: $viewModel.historyLimit,
                                    in: 5...500,
                                    step: 5
                                )
                                .labelsHidden()
                            }
                        }

                        Slider(
                            value: Binding(
                                get: { Double(viewModel.historyLimit) },
                                set: { viewModel.historyLimit = Int($0) }
                            ),
                            in: 5...500,
                            step: 5
                        )

                        Text("Retains between 5 and 500 items. Excess unpinned items are automatically evicted.")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    .zenithSettingsCard()
                }

                // 3. Data Management Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("DATA MANAGEMENT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Purge Clipboard History")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("Removes all unpinned entries from memory and storage.")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Clear History...") {
                            viewModel.showClearConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .zenithSettingsCard()
                }

                // 4. Restore Defaults
                HStack {
                    Spacer()
                    Button("Restore All Defaults") {
                        withAnimation(.goldenGateSpring) {
                            viewModel.resetAllDefaults()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
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
            Text("This action cannot be undone. Pinned items will be preserved.")
        }
    }
}
