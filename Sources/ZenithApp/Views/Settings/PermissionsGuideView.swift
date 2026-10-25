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
                        description: "Required by ScreenCaptureKit to capture screen pixels, coordinate marquee crops, and render high-resolution Retina snapshots.",
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
                        description: "Zenith uses zero-permission Carbon HotKeys by default (no Accessibility required). Enabling Accessibility allows future synthetic paste automation.",
                        isGranted: viewModel.accessibilityGranted,
                        actionTitle: "Open Accessibility Settings...",
                        action: { viewModel.openAccessibilitySettings() }
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
        isGranted: Bool,
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

    private func statusBadge(isGranted: Bool) -> some View {
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
