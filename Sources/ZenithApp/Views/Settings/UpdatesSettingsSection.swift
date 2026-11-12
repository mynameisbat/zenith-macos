import SwiftUI
import ZenithCore

/// Settings → General → Updates: the version, the daily check switch, Check for Updates, and Install (or Download
/// when this copy cannot verify an update) with What's New.
struct UpdatesSettingsSection: View {
    /// Which updater the section shows. `--render-screenshots` swaps in one with made-up state that never asks GitHub
    /// and never reads this Mac.
    @MainActor static var updaterProvider: () -> ZenithUpdater = { .shared }

    @ObservedObject var updater: ZenithUpdater
    @ObservedObject var settings: UpdateSettings

    init(updater: ZenithUpdater? = nil) {
        let resolved = updater ?? Self.updaterProvider()
        self.updater = resolved
        self.settings = resolved.settings
    }

    var body: some View {
        ZenithSettingsSection(
            "Updates",
            footer: "Updates come from Zenith's releases on GitHub. Zenith installs one only if it is signed with the same certificate as this copy, and only after you click Install."
        ) {
            ZenithSettingsRow(
                title: Text("Zenith \(updater.runningVersion.description)"),
                subtitle: Text(verbatim: updater.statusDescription(at: Date())),
                symbol: "arrow.down.circle.fill",
                tint: ZenithTint.general
            ) {
                HStack(spacing: 8) {
                    if updater.phase == .checking || updater.phase == .verifying || updater.phase == .installing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check for Updates") {
                        Task { await updater.checkNow() }
                    }
                    .disabled(updater.isBusy)
                }
            }

            if case .downloading(let fraction) = updater.phase {
                ProgressView(value: fraction ?? 0)
                    .progressViewStyle(.linear)
                    .opacity(fraction == nil ? 0.4 : 1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }

            if let error = updater.errorMessage {
                ZenithSettingsDivider()
                ZenithSettingsNotice(text: error)
            }

            if let release = updater.availableRelease {
                ZenithSettingsDivider(inset: 44)
                availableRow(release)
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Check Automatically",
                subtitle: "Look for a new version once a day while Zenith is running.",
                symbol: "clock.arrow.circlepath",
                tint: ZenithTint.general
            ) {
                Toggle("Check Automatically", isOn: $settings.checksAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func availableRow(_ release: UpdateRelease) -> some View {
        ZenithSettingsRow(
            title: Text("Zenith \(release.version.description) is available"),
            subtitle: updater.installRefusal.map { Text(verbatim: $0.message) },
            symbol: "sparkles",
            tint: ZenithTint.permissions
        ) {
            HStack(spacing: 8) {
                Button("What's New") {
                    UpdateController.openReleasePage(release)
                }
                .buttonStyle(.link)
                if updater.installRefusal == nil {
                    Button("Install and Relaunch") {
                        UpdateController.installAndRelaunch(updater)
                    }
                    .disabled(updater.isBusy)
                } else {
                    Button("Download…") {
                        UpdateController.downloadForManualInstall(updater)
                    }
                    .disabled(updater.isBusy)
                }
            }
        }
    }
}
