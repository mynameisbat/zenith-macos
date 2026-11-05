import SwiftUI
import ZenithCore

public struct PermissionsGuideView: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Required Permissions
                VStack(alignment: .leading, spacing: 8) {
                    Text("REQUIRED PERMISSIONS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    permissionRow(
                        title: "Screen Recording",
                        description: "Needed to capture the screen and to read text from it (OCR). Without it, capture and OCR cannot see anything but the desktop picture.",
                        isGranted: viewModel.screenRecordingGranted,
                        actionTitle: "Open Screen Recording Settings...",
                        action: { viewModel.openScreenRecordingSettings() }
                    )
                    .zenithSettingsCard()
                }

                // 2. Optional Enhancements
                VStack(alignment: .leading, spacing: 8) {
                    Text("OPTIONAL ENHANCEMENTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    permissionRow(
                        title: "Accessibility (Optional)",
                        description: "Global shortcuts do not need it. Accessibility lets Zenith press ⌘V to paste for you and send the media keys that control a browser tab. Without it, items are only copied and the island says how to allow it.",
                        isGranted: viewModel.accessibilityGranted,
                        actionTitle: "Open Accessibility Settings...",
                        action: { viewModel.openAccessibilitySettings() }
                    )
                    .zenithSettingsCard()

                    permissionRow(
                        title: "Automation (Optional)",
                        description: "Lets Zenith control Music and Spotify and read the front tab of Safari and Chromium browsers for the Now Playing title. macOS asks the first time, once for each app. Without it the island still shows that a browser is playing, but not what. Cleaner → Leftovers also asks Finder to move folders that macOS protects (such as those in ~/Library/Containers) to the Trash.",
                        isGranted: nil,
                        actionTitle: "Open Automation Settings...",
                        action: { viewModel.openAutomationSettings() }
                    )
                    .zenithSettingsCard()
                }

                // 3. Refresh Action
                HStack {
                    Spacer()
                    Button("Refresh Status") {
                        withAnimation(.zenithSpring) {
                            viewModel.refreshPermissions()
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
        .onAppear {
            viewModel.refreshPermissions()
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        isGranted: Bool?,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                statusBadge(isGranted: isGranted)
            }

            Text(description)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)

            Button(actionTitle) {
                action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func statusBadge(isGranted: Bool?) -> some View {
        guard let isGranted else {
            // Automation is asked per app, so there is no single answer to show.
            return AnyView(
                Text("Asked per app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            )
        }
        return AnyView(grantedBadge(isGranted: isGranted))
    }

    private func grantedBadge(isGranted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(isGranted ? .accentColor : .secondary)
            Text(isGranted ? "Granted" : "Not Granted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isGranted ? .accentColor : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isGranted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isGranted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}
