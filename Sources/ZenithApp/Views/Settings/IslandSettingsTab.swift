import SwiftUI
import AppKit
import ZenithCore

/// Settings → Dynamic Island: the focus timer and the next calendar event shown in the notch.
public struct IslandSettingsTab: View {
    @ObservedObject private var settings: IslandWidgetSettings = .shared
    @ObservedObject private var timer: FocusTimerService = .shared
    @ObservedObject private var calendar: CalendarWidgetModel = .shared

    public init() {}

    /// The Widgets tab is 380 pt wide: with a timer, an event and the network speed side by side, the event title is cut.
    private var allWidgetsOn: Bool { settings.showTimer && settings.showCalendar && settings.showNetwork }

    public var body: some View {
        ZenithSettingsPage {
            ZenithSettingsSection(
                "Widgets",
                footer: allWidgetsOn
                    ? LocalizedStringKey("Move the pointer to the notch to open the island, then pick the Widgets tab. A running timer stays next to the notch. With all three widgets on, a long event title is shortened to fit.")
                    : LocalizedStringKey("Move the pointer to the notch to open the island, then pick the Widgets tab. A running timer stays next to the notch.")
            ) {
                ZenithSettingsRow(
                    "Focus Timer",
                    subtitle: "A Pomodoro-style timer with breaks.",
                    symbol: "timer",
                    tint: ZenithTint.timer
                ) {
                    Toggle("Focus Timer", isOn: $settings.showTimer)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if settings.showTimer {
                    ZenithSettingsDivider(inset: 44)
                    minutesRow("Focus Length", value: $settings.focusMinutes, range: IslandWidgetSettings.focusRange, step: 5)
                    ZenithSettingsDivider(inset: 44)
                    minutesRow("Break Length", value: $settings.breakMinutes, range: IslandWidgetSettings.breakRange, step: 1)
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Next Calendar Event",
                    subtitle: "Your next meeting from the Calendar app, with how long until it starts.",
                    symbol: "calendar",
                    tint: ZenithTint.calendar
                ) {
                    Toggle("Next Calendar Event", isOn: $settings.showCalendar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if settings.showCalendar {
                    ZenithSettingsDivider(inset: 44)
                    calendarAccessRow
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Network Speed",
                    subtitle: "Download and upload speed, measured only while the island is open on the Widgets tab.",
                    symbol: "arrow.up.arrow.down",
                    tint: ZenithTint.network
                ) {
                    Toggle("Network Speed", isOn: $settings.showNetwork)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            ZenithSettingsSection("Behavior") {
                ZenithSettingsRow(
                    "Volume and Brightness",
                    subtitle: "Show the level on the island when you change it.",
                    symbol: "speaker.wave.2.fill",
                    tint: ZenithTint.audio
                ) {
                    Toggle("Volume and Brightness", isOn: $settings.showLevelHUD)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Hover Delay",
                    subtitle: "How long the pointer rests on the closed island before it opens. A click opens it at once.",
                    symbol: "cursorarrow.rays",
                    tint: ZenithTint.island
                ) {
                    HStack(spacing: 6) {
                        Text("\(hoverDelayText) s")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .trailing)
                        Stepper(
                            "Hover Delay",
                            value: $settings.hoverOpenDelay,
                            in: IslandWidgetSettings.hoverDelayRange,
                            step: IslandWidgetSettings.hoverDelayStep
                        )
                        .labelsHidden()
                    }
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Swipe Gestures",
                    subtitle: "Swipe down on the island to open it, up to close it, and sideways to change track.",
                    symbol: "hand.draw",
                    tint: ZenithTint.island
                ) {
                    Toggle("Swipe Gestures", isOn: $settings.scrollGestures)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Hide in Full-Screen Apps",
                    subtitle: "Take the island away while an app is full screen. Notices then use the floating panel.",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    tint: ZenithTint.screen
                ) {
                    Toggle("Hide in Full-Screen Apps", isOn: $settings.hideInFullscreen)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if settings.showTimer {
                ZenithSettingsSection("Timer") {
                    timerControlRow
                }
            }
        }
        .onAppear {
            calendar.refresh()
        }
    }

    /// "0.25", or "0,25" where the decimal separator is a comma; two decimals, as the 0.05 s step needs.
    private var hoverDelayText: String {
        settings.hoverOpenDelay.formatted(.number.precision(.fractionLength(2)))
    }

    private func minutesRow(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        ZenithSettingsRow(title) {
            HStack(spacing: 6) {
                Text("\(value.wrappedValue) min")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
        .padding(.leading, 32)
    }

    @ViewBuilder
    private var calendarAccessRow: some View {
        ZenithSettingsRow("Calendar Access") {
            HStack(spacing: 10) {
                switch calendar.access {
                case .granted:
                    ZenithStatusBadge(text: "Allowed", kind: .ok)
                case .denied:
                    ZenithStatusBadge(text: "Not Allowed", kind: .warning)
                    Button("Open…") {
                        openCalendarPrivacySettings()
                    }
                    .controlSize(.small)
                    .help("Allow Zenith in System Settings → Privacy & Security → Calendars")
                case .notDetermined:
                    ZenithStatusBadge(text: "Not asked yet", kind: .neutral)
                    Button("Allow…") {
                        Task { await calendar.requestAccess() }
                    }
                    .controlSize(.small)
                    .help("macOS asks whether Zenith may read your calendars")
                case .unavailable:
                    ZenithStatusBadge(text: "Needs Zenith.app", kind: .warning)
                        .help("Calendar access can only be asked for by the bundled app (scripts/bundle_app.sh), not by `swift run`.")
                }
            }
        }
        .padding(.leading, 32)
    }

    private var timerControlRow: some View {
        let snapshot = timer.snapshot
        let sessions = timer.focusSessionsToday
        let subtitle: Text = {
            if let snapshot {
                return snapshot.isPaused
                    ? Text("\(snapshot.mode.title) · \(snapshot.remainingText) left (paused)")
                    : Text("\(snapshot.mode.title) · \(snapshot.remainingText) left")
            }
            switch sessions {
            case 0: return Text("No focus sessions finished today.")
            case 1: return Text("1 focus session finished today.")
            default: return Text("\(sessions) focus sessions finished today.")
            }
        }()
        return ZenithSettingsRow(
            title: snapshot == nil ? Text("Not Running") : Text("Running"),
            subtitle: subtitle,
            symbol: snapshot?.mode.symbolName ?? "timer",
            tint: ZenithTint.timer
        ) {
            HStack(spacing: 6) {
                if snapshot != nil {
                    Button(snapshot?.isPaused == true ? "Resume" : "Pause") {
                        timer.togglePause()
                    }
                    Button("Stop") {
                        timer.stop()
                    }
                } else {
                    Button("Start Break") {
                        timer.start(.shortBreak, minutes: settings.breakMinutes)
                    }
                    Button("Start Focus") {
                        timer.start(.focus, minutes: settings.focusMinutes)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
    }

    private func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
