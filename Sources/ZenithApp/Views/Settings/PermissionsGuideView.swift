import SwiftUI
import ZenithCore

public struct PermissionsGuideView: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZenithSettingsPage {
            ZenithSettingsSection(
                "Required",
                footer: "Without Screen Recording, capture and text recognition only see the desktop picture."
            ) {
                permissionRow(
                    title: String(localized: "Screen Recording"),
                    description: "To capture the screen and read text from it.",
                    symbol: "rectangle.dashed.badge.record",
                    tint: Color(nsColor: .systemRed),
                    status: viewModel.screenRecordingGranted ? .allowed : .notAllowed,
                    action: { viewModel.openScreenRecordingSettings() }
                )
            }

            ZenithSettingsSection(
                "Optional",
                footer: "Global shortcuts need neither. Automation is asked once for each app the first time Zenith talks to it; Cleaner → Leftovers also asks Finder to move protected folders (such as those in ~/Library/Containers) to the Trash."
            ) {
                permissionRow(
                    title: String(localized: "Accessibility"),
                    description: "To paste for you (⌘V) and to send media keys to a browser tab. Without it, items are only copied.",
                    symbol: SymbolName.accessibility,
                    tint: Color(nsColor: .systemBlue),
                    status: viewModel.accessibilityGranted ? .allowed : .notAllowed,
                    action: { viewModel.openAccessibilitySettings() }
                )
                ZenithSettingsDivider(inset: 44)
                permissionRow(
                    title: String(localized: "Automation"),
                    description: "To control Music and Spotify, and to read the front browser tab\u{2019}s title for Now Playing.",
                    symbol: "gearshape.2.fill",
                    tint: Color(nsColor: .systemGray),
                    status: .perApp,
                    action: { viewModel.openAutomationSettings() }
                )
            }

            HStack {
                Spacer()
                Button("Check Again") {
                    withAnimation(.zenithSpring) {
                        viewModel.refreshPermissions()
                    }
                }
                .help("Read the permissions again, e.g. after changing them in System Settings")
            }
        }
        .onAppear {
            viewModel.refreshPermissions()
        }
    }

    private enum Status {
        case allowed, notAllowed, perApp
    }

    private func permissionRow(
        title: String,
        description: LocalizedStringKey,
        symbol: String,
        tint: Color,
        status: Status,
        action: @escaping () -> Void
    ) -> some View {
        ZenithSettingsRow(title: Text(verbatim: title), subtitle: Text(description), symbol: symbol, tint: tint) {
            HStack(spacing: 10) {
                switch status {
                case .allowed:
                    ZenithStatusBadge(text: "Allowed", kind: .ok)
                case .notAllowed:
                    ZenithStatusBadge(text: "Not Allowed", kind: .warning)
                case .perApp:
                    ZenithStatusBadge(text: "Asked per app", kind: .neutral)
                }
                Button("Open…") {
                    action()
                }
                .controlSize(.small)
                .help("Open \(title) in System Settings → Privacy & Security")
                .accessibilityLabel("Open \(title) settings")
            }
        }
    }
}
