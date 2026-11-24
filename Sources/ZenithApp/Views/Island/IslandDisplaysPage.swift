import SwiftUI
import ZenithCore

/// The Displays page of the island: one card per display with a brightness slider (and, for a monitor that takes it over
/// DDC, a volume slider).
///
/// The sliders talk to `DisplayBrightnessService`, which sends the newest value about ten times a second and the final
/// one when the drag ends, off the main thread. Nothing here polls: the values are read when the page opens.
struct IslandDisplaysPage: View {
    /// The service the page shows. The screenshot renderer swaps it for one with made-up displays, so a published
    /// picture never shows this Mac's displays.
    @MainActor static var serviceProvider: () -> DisplayBrightnessService = { .shared }

    @ObservedObject private var service: DisplayBrightnessService

    @MainActor
    init() {
        _service = ObservedObject(wrappedValue: Self.serviceProvider())
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: IslandDisplaysPageSizing.spacing) {
                if !service.hasLoaded {
                    statusLine(symbol: nil, text: Text("Looking for displays…"))
                } else if service.displays.isEmpty {
                    statusLine(symbol: "display", text: Text("No displays found"))
                } else {
                    ForEach(service.displays) { display in
                        IslandDisplayCard(display: display, service: service)
                    }

                    Button {
                        ZenithIslandState.shared.close()
                        ZenithToolActions.openSettings(on: .displays)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.below.rectangle")
                            Text("Display Settings…")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(ZenithTheme.Island.textSecondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(IslandDisplaysPageSizing.padding)
        }
    }

    private func statusLine(symbol: String?, text: Text) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                ProgressView().controlSize(.small)
            }
            text
        }
        .font(.system(size: 12.5))
        .foregroundColor(ZenithTheme.Island.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 64)
    }
}

private struct IslandDisplayCard: View {
    let display: ControlledDisplay
    @ObservedObject var service: DisplayBrightnessService

    private var tint: Color { IslandToolStyle.tint(for: .displays) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if display.isProbing {
                note(Text("Reading the display…"), symbol: nil)
            } else if display.backend == .none {
                note(Text("Brightness can't be changed on this display"), symbol: "exclamationmark.circle")
            } else {
                brightnessRow
                if display.volume != nil { volumeRow }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubModule(radius: 18)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ZenithTheme.Island.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: display.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ZenithTheme.Island.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if display.backend == .gamma && !display.isProbing {
                Text("Software dimming")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(ZenithTheme.Island.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .help("The picture is dimmed in software. The screen's own backlight stays as it is.")
            }
        }
    }

    private func note(_ text: Text, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                ProgressView().controlSize(.small)
            }
            text
        }
        .font(.system(size: 11.5))
        .foregroundColor(ZenithTheme.Island.textSecondary)
        .frame(minHeight: 24, alignment: .leading)
    }

    private var brightnessRow: some View {
        let id = display.id
        let service = service
        let fallback = display.brightness
        let binding = Binding<Double>(
            get: { MainActor.assumeIsolated { service.displays.first { $0.id == id }?.brightness ?? fallback } },
            set: { value in MainActor.assumeIsolated { service.setBrightness(value, for: id, isFinal: false) } }
        )
        return sliderRow(
            low: "sun.min.fill", high: "sun.max.fill", tint: tint, value: binding,
            finish: { service.setBrightness($0, for: id, isFinal: true) },
            label: Text("Brightness of \(display.name)")
        )
    }

    private var volumeRow: some View {
        let id = display.id
        let service = service
        let fallback = display.volume ?? 0
        let binding = Binding<Double>(
            get: { MainActor.assumeIsolated { service.displays.first { $0.id == id }?.volume ?? fallback } },
            set: { value in MainActor.assumeIsolated { service.setVolume(value, for: id, isFinal: false) } }
        )
        return sliderRow(
            low: "speaker.fill", high: "speaker.wave.3.fill", tint: Color(white: 0.85), value: binding,
            finish: { service.setVolume($0, for: id, isFinal: true) },
            label: Text("Volume of \(display.name)")
        )
    }

    private func sliderRow(
        low: String, high: String, tint: Color, value: Binding<Double>, finish: @escaping (Double) -> Void, label: Text
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: low)
                .font(.system(size: 11))
                .foregroundColor(ZenithTheme.Island.textTertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Slider(
                value: value,
                in: 0...1,
                onEditingChanged: { editing in if !editing { finish(value.wrappedValue) } }
            )
            .tint(tint)
            .controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))%"))
            Image(systemName: high)
                .font(.system(size: 13))
                .foregroundColor(ZenithTheme.Island.textTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundColor(ZenithTheme.Island.textSecondary)
                .frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
