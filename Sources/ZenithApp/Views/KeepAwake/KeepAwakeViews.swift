import SwiftUI
import AppKit
import ZenithCore

extension ZenithTint {
    static let keepAwake = Color(nsColor: .systemYellow)
}

private extension KeepAwakeMode {
    /// The small symbol on the right of the closed island when there is no time to show.
    var islandSymbol: String {
        switch self {
        case .duration, .indefinite: return "infinity"
        case .whileAppsRunning: return "app.fill"
        case .whileOnACPower: return "powerplug.fill"
        }
    }
}

// MARK: - Closed island

/// Beside the notch while keep awake holds the Mac awake: a cup on the left, the time left (or what it waits on) on
/// the right. Uses the timer's wide wings only when there is a time to fit.
struct IslandKeepAwakeCompactWings: View {
    let snapshot: KeepAwakeSnapshot
    let geometry: ZenithIslandGeometry

    private var width: CGFloat {
        snapshot.remaining != nil ? geometry.timerIdleWidth : geometry.nowPlayingIdleWidth
    }

    var body: some View {
        HStack {
            Image(systemName: snapshot.keepsDisplayOn ? "sun.max.fill" : "mug.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ZenithTint.keepAwake)
                .padding(.leading, 10)

            Spacer()

            Group {
                if let text = snapshot.remainingText {
                    Text(verbatim: text)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Image(systemName: snapshot.mode.islandSymbol)
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(ZenithTint.keepAwake)
            .padding(.trailing, 10)
        }
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height / 2 - 8) : 5)
        .frame(width: width, height: geometry.nowPlayingIdleHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: snapshot.accessibilityDescription))
    }
}

// MARK: - Mode menu

/// The choices shared by the Command Hub and Settings: durations, until off, apps, power adapter, and off.
struct KeepAwakeModeMenuItems: View {
    @ObservedObject var service: KeepAwakeService
    @ObservedObject var settings: KeepAwakeSettings

    var body: some View {
        Section("Keep Awake For") {
            ForEach(KeepAwakeMode.presetDurations, id: \.self) { seconds in
                Button(KeepAwakeMode.durationTitle(seconds)) {
                    service.start(.duration(seconds))
                }
            }
            Button("Custom (\(KeepAwakeMode.durationTitle(TimeInterval(settings.customMinutes * 60))))") {
                service.start(minutes: settings.customMinutes)
            }
        }
        Divider()
        Button(KeepAwakeMode.indefinite.title) {
            service.start(.indefinite)
        }
        Button(KeepAwakeMode.whileAppsRunning.title) {
            service.start(.whileAppsRunning)
        }
        .disabled(settings.watchedApps.isEmpty)
        Button(KeepAwakeMode.whileOnACPower.title) {
            service.start(.whileOnACPower)
        }
        if service.isActive {
            Divider()
            Button("Turn Off") {
                service.stop()
            }
        }
    }
}

/// The on/off switch: on means "until turned off". SwiftUI calls these on the main thread.
@MainActor
private func keepAwakeBinding(_ service: KeepAwakeService) -> Binding<Bool> {
    Binding(
        get: { MainActor.assumeIsolated { service.isActive } },
        set: { wantsOn in
            MainActor.assumeIsolated {
                if wantsOn != service.isActive { service.toggle() }
            }
        }
    )
}

// MARK: - Command Hub

/// A row under the hub's controls: the switch ("until turned off"), the status, and a menu of modes.
struct KeepAwakeHubRow: View {
    @ObservedObject private var service: KeepAwakeService = .shared
    @ObservedObject private var settings: KeepAwakeSettings = .shared

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: keepAwakeBinding(service)) {
                HStack(spacing: 6) {
                    ZenithIconTile(systemName: "mug.fill", tint: ZenithTint.keepAwake, size: 20)
                    Text("Keep Awake")
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(service.isActive ? "On: the Mac does not go to sleep on its own" : "Off. Turn on to keep the Mac from going to sleep until you turn it off")

            Spacer(minLength: 4)

            if let snapshot = service.snapshot {
                Text(verbatim: snapshot.statusText)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Menu {
                KeepAwakeModeMenuItems(service: service, settings: settings)
            } label: {
                Image(systemName: "clock")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Keep the Mac awake for a while, or while apps run or the adapter is connected")
            .accessibilityLabel("Keep Awake Options")
        }
    }
}

// MARK: - Settings

/// Running apps for the picker, refreshed when apps launch or quit.
@MainActor
final class KeepAwakeRunningAppsModel: ObservableObject {
    @Published private(set) var apps: [KeepAwakeApp] = []
    private let source = WorkspaceRunningApplications()

    func refresh() {
        let current = source.runningApplications()
        if current != apps { apps = current }
    }

    static func icon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Settings → General → Keep Awake.
struct KeepAwakeSettingsSection: View {
    @ObservedObject private var service: KeepAwakeService = .shared
    @ObservedObject private var settings: KeepAwakeSettings = .shared
    @ObservedObject private var hotKey: KeepAwakeHotKeyController = .shared
    @StateObject private var running = KeepAwakeRunningAppsModel()

    private var statusText: Text {
        if let snapshot = service.snapshot {
            return Text(verbatim: "\(snapshot.mode.title) · \(snapshot.statusText)")
        }
        return Text("Off. The Mac sleeps as set in System Settings.")
    }

    var body: some View {
        ZenithSettingsSection(
            "Keep Awake",
            footer: "Keep awake ends when you quit Zenith. Closing the lid still puts the Mac to sleep: keeping it awake with the lid closed needs administrator rights, so Zenith does not offer it."
        ) {
            ZenithSettingsRow(title: Text("Keep Mac Awake"), subtitle: statusText, symbol: "mug.fill", tint: ZenithTint.keepAwake) {
                HStack(spacing: 8) {
                    Menu("Mode") {
                        KeepAwakeModeMenuItems(service: service, settings: settings)
                    }
                    .fixedSize()
                    Toggle("Keep Mac Awake", isOn: keepAwakeBinding(service))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if service.assertionFailed {
                ZenithSettingsDivider()
                ZenithSettingsNotice(text: String(localized: "macOS refused to keep the Mac awake. Try again, or restart Zenith."))
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Keep the Display On",
                subtitle: "Also stop the screen from dimming and turning off.",
                symbol: "sun.max.fill",
                tint: ZenithTint.keepAwake
            ) {
                Toggle("Keep the Display On", isOn: $settings.keepsDisplayOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Custom Duration",
                subtitle: "The Custom choice in the keep-awake menu.",
                symbol: "timer",
                tint: ZenithTint.keepAwake
            ) {
                HStack(spacing: 6) {
                    Text(verbatim: KeepAwakeMode.durationTitle(TimeInterval(settings.customMinutes * 60)))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                    Stepper(
                        "Custom Duration",
                        value: $settings.customMinutes,
                        in: KeepAwakeSettings.customMinutesRange,
                        step: KeepAwakeSettings.customMinutesStep
                    )
                    .labelsHidden()
                }
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Show on the Island",
                subtitle: "A cup beside the notch while the Mac is kept awake, with the time left.",
                symbol: "capsule.fill",
                tint: ZenithTint.island
            ) {
                Toggle("Show on the Island", isOn: $settings.showsOnIsland)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            ZenithSettingsDivider(inset: 44)

            appsRow

            ForEach(settings.watchedApps) { app in
                watchedAppRow(app)
            }

            ZenithSettingsDivider(inset: 44)

            shortcutRow

            if let problem = hotKey.changeProblem {
                ZenithSettingsDivider()
                ZenithSettingsNotice(text: problem)
            } else if hotKey.registrationFailed {
                ZenithSettingsDivider()
                ZenithSettingsNotice(text: String(localized: "This shortcut could not be registered, probably because another app uses it. Choose other keys."))
            }
        }
        .onAppear { running.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            running.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            running.refresh()
        }
    }

    private var appsRow: some View {
        let choices = running.apps.filter { app in !settings.watchedApps.contains { $0.bundleIdentifier == app.bundleIdentifier } }
        return ZenithSettingsRow(
            "Chosen Apps",
            subtitle: settings.watchedApps.isEmpty
                ? "Add apps for “While Chosen Apps Run”: the Mac stays awake while one of them is open."
                : "The Mac stays awake while one of these is open, when that mode is on.",
            symbol: "app.badge.checkmark",
            tint: ZenithTint.keepAwake
        ) {
            Menu("Add App") {
                if choices.isEmpty {
                    Text("No other apps are running")
                }
                ForEach(choices) { app in
                    Button(app.name) {
                        settings.addWatchedApp(app)
                    }
                }
            }
            .fixedSize()
        }
    }

    private func watchedAppRow(_ app: KeepAwakeApp) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = KeepAwakeRunningAppsModel.icon(for: app.bundleIdentifier) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Text(verbatim: app.name)
                .font(.system(size: 12.5))
            Spacer(minLength: 8)
            Button {
                settings.removeWatchedApp(bundleIdentifier: app.bundleIdentifier)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove \(app.name)")
            .accessibilityLabel("Remove \(app.name)")
        }
        .padding(.leading, 44)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
    }

    private var shortcutRow: some View {
        ZenithSettingsRow(
            "Keyboard Shortcut",
            subtitle: "Turns keep awake on and off from any app.",
            symbol: "command",
            tint: ZenithTint.shortcuts
        ) {
            HStack(spacing: 8) {
                InteractiveShortcutRecorderView(
                    id: HotKeyDefinition.keepAwakeToggleId,
                    title: String(localized: "Keep Awake"),
                    currentDefinition: hotKey.definition,
                    onUpdate: { hotKey.change($0) == .applied }
                )
                Toggle("Keyboard Shortcut", isOn: Binding(
                    get: { settings.hotKeyEnabled },
                    set: { hotKey.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }
}
