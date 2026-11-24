import SwiftUI
import AppKit
import ZenithCore

/// Settings → Displays: per-display resolution, refresh rate and brightness controls with automatic 15-second safety revert.
public struct DisplaysSettingsTab: View {
    /// (Not `@State`: the SwiftUI macro plugin is not available to a Command Line Tools build.)
    private final class DisplaysTabState: ObservableObject {
        @Published var selectedDisplayID: UInt32 = 0
        @Published var showAllResolutions: Bool = false
    }

    @ObservedObject private var modeService: DisplayModeService
    @ObservedObject private var brightnessService: DisplayBrightnessService
    @StateObject private var state = DisplaysTabState()

    public init(
        modeService: DisplayModeService = .shared,
        brightnessService: DisplayBrightnessService = .shared
    ) {
        _modeService = ObservedObject(wrappedValue: modeService)
        _brightnessService = ObservedObject(wrappedValue: brightnessService)
    }

    private var activeDisplayID: UInt32 {
        if state.selectedDisplayID != 0 && modeService.displays.contains(where: { $0.id == state.selectedDisplayID }) {
            return state.selectedDisplayID
        }
        return modeService.displays.first?.id ?? 0
    }

    private var currentDisplay: DisplayDescriptor? {
        modeService.displays.first { $0.id == activeDisplayID }
    }

    private var controlledDisplay: ControlledDisplay? {
        brightnessService.displays.first { $0.id == activeDisplayID }
    }

    public var body: some View {
        ZenithSettingsPage {
            if let pending = modeService.pendingRevert {
                safetyRevertBanner(pending: pending)
            }

            if modeService.displays.isEmpty {
                emptyState
            } else {
                if modeService.displays.count > 1 {
                    displayPicker
                }

                if let display = currentDisplay {
                    displayDetailSection(display: display)
                }
            }
        }
        .onAppear {
            modeService.refreshDisplays()
            if state.selectedDisplayID == 0, let first = modeService.displays.first {
                state.selectedDisplayID = first.id
            }
        }
    }

    // MARK: - Safety Revert Banner

    private func safetyRevertBanner(pending: PendingRevertState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Confirm Display Setting"))
                    .font(.system(size: 13, weight: .bold))
                Text(String(format: String(localized: "Reverting in %d seconds…"), pending.secondsLeft))
                    .font(.system(size: 11.5))
                    .foregroundColor(ZenithTheme.Island.textSecondary)
            }

            Spacer()

            Button(String(localized: "Revert")) {
                modeService.revertChanges()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(String(localized: "Keep Changes")) {
                modeService.confirmKeepChanges()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        )
        .padding(.horizontal, 2)
    }

    // MARK: - Display Picker

    private var displayPicker: some View {
        ZenithSettingsSection("Displays") {
            Picker("Display", selection: $state.selectedDisplayID) {
                ForEach(modeService.displays) { display in
                    Text(display.name).tag(display.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Detail Section

    private func displayDetailSection(display: DisplayDescriptor) -> some View {
        let modes = modeService.modes(for: display.id)
        let currentMode = modeService.currentMode(for: display.id)

        return Group {
            ZenithSettingsSection(
                title: Text(verbatim: display.name),
                footer: Text(display.isBuiltIn ? String(localized: "Built-in Apple display.") : String(localized: "External monitor connected over cable."))
            ) {
                ZenithSettingsRow(
                    title: Text("Resolution"),
                    subtitle: Text(verbatim: currentMode?.resolutionString ?? "–"),
                    symbol: display.isBuiltIn ? "laptopcomputer" : "display",
                    tint: ZenithTint.displays
                ) {
                    resolutionPicker(displayID: display.id, modes: modes, current: currentMode)
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    title: Text("Refresh Rate"),
                    subtitle: Text(verbatim: currentMode?.refreshRateString ?? "–"),
                    symbol: "speedometer",
                    tint: ZenithTint.displays
                ) {
                    refreshRatePicker(displayID: display.id, modes: modes, current: currentMode)
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Show all resolutions",
                    subtitle: "Show low resolution and scaled modes",
                    symbol: "list.bullet.rectangle",
                    tint: ZenithTint.displays
                ) {
                    Toggle("Show all resolutions", isOn: $state.showAllResolutions)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if let controlled = controlledDisplay {
                brightnessSection(controlled: controlled)
            }
        }
    }

    // MARK: - Resolution Picker

    private func resolutionPicker(displayID: UInt32, modes: [DisplayModeDescriptor], current: DisplayModeDescriptor?) -> some View {
        let filtered: [DisplayModeDescriptor] = {
            if state.showAllResolutions {
                return modes
            }
            // By default, prefer HiDPI modes or unique resolution strings
            var seen = Set<String>()
            var list: [DisplayModeDescriptor] = []
            for m in modes where m.isHiDPI || !modes.contains(where: { $0.width == m.width && $0.height == m.height && $0.isHiDPI }) {
                if seen.insert(m.resolutionString).inserted || m.isCurrent {
                    list.append(m)
                }
            }
            return list.isEmpty ? modes : list
        }()

        let selectedID = current?.id ?? (filtered.first?.id ?? 0)

        return Menu {
            ForEach(filtered) { mode in
                Button {
                    modeService.applyMode(mode, for: displayID)
                } label: {
                    HStack {
                        Text(mode.fullTitle)
                        if mode.id == selectedID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(current?.fullTitle ?? String(localized: "Default for display"))
                .frame(minWidth: 160, alignment: .trailing)
        }
    }

    // MARK: - Refresh Rate Picker

    private func refreshRatePicker(displayID: UInt32, modes: [DisplayModeDescriptor], current: DisplayModeDescriptor?) -> some View {
        guard let current else {
            return AnyView(Text("–").foregroundColor(ZenithTheme.Island.textSecondary))
        }

        // Available refresh rates for the current width x height
        let matchingModes = modes.filter { $0.width == current.width && $0.height == current.height && $0.isHiDPI == current.isHiDPI }
        let rates = matchingModes.isEmpty ? [current] : matchingModes

        return AnyView(
            Menu {
                ForEach(rates) { mode in
                    Button {
                        modeService.applyMode(mode, for: displayID)
                    } label: {
                        HStack {
                            Text(mode.refreshRateString)
                            if mode.id == current.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(current.refreshRateString)
                    .frame(minWidth: 80, alignment: .trailing)
            }
        )
    }

    // MARK: - Brightness Section

    private func brightnessSection(controlled: ControlledDisplay) -> some View {
        ZenithSettingsSection("Brightness & Picture") {
            ZenithSettingsRow(
                title: Text("Brightness"),
                subtitle: Text(verbatim: controlled.backend == .gamma ? String(localized: "Software dimming") : "\(Int(controlled.brightness * 100))%"),
                symbol: "sun.max.fill",
                tint: ZenithTint.displays
            ) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { controlled.brightness },
                            set: { brightnessService.setBrightness($0, for: controlled.id) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 140)

                    Text("\(Int(controlled.brightness * 100))%")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundColor(ZenithTheme.Island.textSecondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if let volume = controlled.volume {
                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    title: Text("Volume"),
                    subtitle: Text(verbatim: "\(Int(volume * 100))%"),
                    symbol: "speaker.wave.2.fill",
                    tint: ZenithTint.audio
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { volume },
                                set: { brightnessService.setVolume($0, for: controlled.id) }
                            ),
                            in: 0...1
                        )
                        .frame(width: 140)

                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(ZenithTheme.Island.textSecondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(ZenithTheme.Island.textSecondary)
            Text(String(localized: "No displays found"))
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}
