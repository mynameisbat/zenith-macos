import SwiftUI
import ZenithCore

/// The "Live preview" card at the top of Settings → Dynamic Island: a small, static island drawn with the island's own
/// colors that follows the switches below it (the timer, calendar and network chips, the tool dock and its icon style).
///
/// Everything in it is made up (a song that does not exist, a fixed time) except the on/off state of the two switches in the
/// dock: it runs no timer and starts no service, so it costs nothing while the page is open.
struct IslandSettingsPreview: View {
    @ObservedObject private var settings: IslandWidgetSettings = .shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            island
            Text("Live preview")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.14, green: 0.14, blue: 0.23), Color(red: 0.09, green: 0.09, blue: 0.12)]
                        : [Color(red: 0.87, green: 0.90, blue: 0.96), Color(red: 0.96, green: 0.965, blue: 0.98)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy(duration: 0.25), value: settings.showTimer)
        .animation(.snappy(duration: 0.25), value: settings.showCalendar)
        .animation(.snappy(duration: 0.25), value: settings.showNetwork)
        .animation(.snappy(duration: 0.25), value: settings.showTools)
        .animation(.snappy(duration: 0.25), value: settings.dockLayout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live preview")
    }

    private var island: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color(red: 1, green: 0.70, blue: 0.42), Color(red: 1, green: 0.24, blue: 0.43), Color(red: 0.42, green: 0.17, blue: 1)],
                        center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 40
                    ))
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Dawn Chorus")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: "Example Band")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ZenithTheme.Island.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if settings.showTimer {
                    chip(Text(verbatim: "24:12"), symbol: nil, color: ZenithTint.timer)
                }
                if settings.showCalendar {
                    chip(Text(verbatim: "10:30"), symbol: "calendar", color: ZenithTint.calendar)
                }
                if settings.showNetwork {
                    chip(Text(verbatim: "2.4"), symbol: "arrow.down", color: ZenithTint.network)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 62)

            if settings.showTools {
                HStack(spacing: 8) {
                    ForEach(settings.dockLayout.tools) { tool in
                        dockIcon(tool)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .foregroundStyle(ZenithTheme.Island.textPrimary)
        .frame(maxWidth: 360)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous)
                .fill(Color.black)
        )
    }

    private func chip(_ text: Text, symbol: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            text.font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
    }

    /// The dock's own icon: it follows the style and draws Privacy Shield and Keep Awake as they really are, on or
    /// off (`IslandToolSwitches` only reads the two services' state; it starts nothing).
    private func dockIcon(_ tool: IslandTool) -> some View {
        IslandToolIcon(tool: tool, size: 26, isHovered: false)
    }
}
