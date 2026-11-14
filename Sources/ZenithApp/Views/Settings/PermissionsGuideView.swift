import SwiftUI
import ZenithCore

/// For each permission: its state, what it is for, which Zenith features use it and whether they are on. The
/// decisions are made by `ZenithPermissionsReport` (Core); this view only draws them.
public struct PermissionsGuideView: View {
    @StateObject private var model: ZenithPermissionsModel

    public init(viewModel: SettingsViewModel) {
        _model = StateObject(wrappedValue: ZenithPermissionsModel(permissions: viewModel.permissionsService))
    }

    public var body: some View {
        ZenithSettingsPage {
            ForEach(model.statuses) { status in
                permissionSection(status)
            }

            HStack {
                Text("Zenith never asks for a permission on this page. Allow or remove them in System Settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Check Again") {
                    withAnimation(.zenithSpring) {
                        model.refresh()
                    }
                }
                .help("Read the permissions again, e.g. after changing them in System Settings")
            }
        }
        .onAppear {
            model.refresh()
        }
    }

    private func symbol(_ kind: ZenithPermissionKind) -> (name: String, tint: Color) {
        switch kind {
        case .screenRecording: return ("rectangle.dashed.badge.record", Color(nsColor: .systemRed))
        case .accessibility: return (SymbolName.accessibility, Color(nsColor: .systemBlue))
        case .automation: return ("gearshape.2.fill", ZenithTint.general)
        case .calendar: return ("calendar", ZenithTint.calendar)
        case .microphone: return ("mic.fill", Color(nsColor: .systemOrange))
        }
    }

    private func permissionSection(_ status: ZenithPermissionStatus) -> some View {
        let kind = status.kind
        let icon = symbol(kind)
        return ZenithSettingsSection {
            ZenithSettingsRow(title: Text(verbatim: kind.title), subtitle: Text(verbatim: kind.purpose), symbol: icon.name, tint: icon.tint) {
                HStack(spacing: 10) {
                    badge(status)
                    if status.offersSettingsButton {
                        Button("Open\u{2026}") {
                            model.openSettings(for: kind)
                        }
                        .controlSize(.small)
                        .help("Open \(kind.title) in System Settings \u{2192} Privacy & Security")
                        .accessibilityLabel("Open \(kind.title) settings")
                    }
                }
            }

            if let notice = status.notice {
                ZenithSettingsDivider(inset: 44)
                ZenithSettingsNotice(
                    text: notice,
                    symbol: status.noticeIsWarning ? "exclamationmark.triangle.fill" : "info.circle.fill",
                    tint: status.noticeIsWarning ? ZenithTheme.warning : .secondary
                )
            }

            ZenithSettingsDivider(inset: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("Used by")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(status.features) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: item.feature.title)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(verbatim: item.activity.label)
                            .font(.system(size: 11.5, weight: item.activity == .on ? .medium : .regular))
                            .foregroundStyle(item.activity == .on ? Color.primary : Color.secondary)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(verbatim: kind.withoutIt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func badge(_ status: ZenithPermissionStatus) -> some View {
        switch status.verdict {
        case .inUse, .grantedButUnused:
            ZenithStatusBadge(text: LocalizedStringKey(status.badgeText), kind: .ok)
        case .neededButMissing, .notGranted, .unavailable:
            ZenithStatusBadge(text: LocalizedStringKey(status.badgeText), kind: .warning)
        case .notAskedYet, .askedPerApp:
            ZenithStatusBadge(text: LocalizedStringKey(status.badgeText), kind: .neutral)
        }
    }
}
