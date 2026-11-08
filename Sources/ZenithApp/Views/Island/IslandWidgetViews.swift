import SwiftUI
import AppKit
import ZenithCore

private extension FocusTimerMode {
    var tint: Color {
        switch self {
        case .focus: return Color(nsColor: .systemOrange)
        case .shortBreak: return Color(nsColor: .systemGreen)
        }
    }
}

// MARK: - Progress Ring

/// A thin ring that fills as the timer runs, with the mode's symbol inside.
struct IslandTimerRing: View {
    let progress: Double
    let tint: Color
    let symbol: String
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.9), value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Closed Island Wings

/// What sits either side of the notch while a timer runs: the ring on the left, the time left on the right.
struct IslandTimerCompactWings: View {
    let snapshot: FocusTimerSnapshot
    let geometry: ZenithIslandGeometry

    var body: some View {
        HStack {
            IslandTimerRing(progress: snapshot.progress, tint: snapshot.mode.tint, symbol: snapshot.isPaused ? "pause.fill" : snapshot.mode.symbolName)
                .padding(.leading, 10)

            Spacer()

            Text(snapshot.remainingText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(snapshot.isPaused ? ZenithTheme.Island.textSecondary : snapshot.mode.tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 10)
        }
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height / 2 - 8) : 5)
        .frame(width: geometry.timerIdleWidth, height: geometry.nowPlayingIdleHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.isPaused
            ? Text("\(snapshot.mode.title) timer, \(snapshot.remainingText) left, paused")
            : Text("\(snapshot.mode.title) timer, \(snapshot.remainingText) left"))
    }
}

// MARK: - Round Button

/// The small round buttons on the island's dark surface.
struct IslandRoundButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color = .white
    var isProminent = false
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(isProminent ? Color.black : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(isProminent ? tint : Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Widgets Panel

/// The Widgets tab of the expanded island: the focus timer and the next calendar event, side by side.
struct IslandWidgetsPanel: View {
    @ObservedObject var islandState: ZenithIslandState

    var body: some View {
        HStack(spacing: 8) {
            if islandState.showsTimerWidget {
                IslandTimerCard(snapshot: islandState.focusTimer)
            }
            if islandState.showsCalendarWidget {
                IslandCalendarCard(event: islandState.upcomingEvent, access: islandState.calendarAccess)
            }
            if islandState.showsNetworkWidget {
                IslandNetworkCard()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared card look for the island widgets.
private struct IslandCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ZenithTheme.Island.fill)
            )
    }
}

struct IslandTimerCard: View {
    let snapshot: FocusTimerSnapshot?
    @ObservedObject private var settings: IslandWidgetSettings = .shared
    @ObservedObject private var timer: FocusTimerService = .shared

    /// After a focus session the next thing to start is a break, and the other way round.
    private var nextMode: FocusTimerMode {
        timer.lastFinishedMode == .focus ? .shortBreak : .focus
    }

    private func minutes(for mode: FocusTimerMode) -> Int {
        mode == .focus ? settings.focusMinutes : settings.breakMinutes
    }

    var body: some View {
        HStack(spacing: 8) {
            if let snapshot {
                IslandTimerRing(progress: snapshot.progress, tint: snapshot.mode.tint, symbol: snapshot.mode.symbolName, size: 28, lineWidth: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.remainingText)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ZenithTheme.Island.textPrimary)
                        .fixedSize()
                    (snapshot.isPaused ? Text("Paused") : Text(verbatim: snapshot.mode.title))
                        .font(.system(size: 10))
                        .foregroundStyle(ZenithTheme.Island.textSecondary)
                        .fixedSize()
                }
                .lineLimit(1)
                .layoutPriority(1)
                Spacer(minLength: 2)
                IslandRoundButton(
                    symbol: snapshot.isPaused ? "play.fill" : "pause.fill",
                    label: snapshot.isPaused ? "Resume" : "Pause",
                    tint: snapshot.mode.tint,
                    isProminent: true
                ) {
                    timer.togglePause()
                }
                IslandRoundButton(symbol: "stop.fill", label: "Stop timer") {
                    timer.stop()
                }
            } else {
                IslandTimerRing(progress: 0, tint: nextMode.tint, symbol: nextMode.symbolName, size: 28, lineWidth: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nextMode == .focus ? "Focus" : "Break")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ZenithTheme.Island.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(ZenithTheme.Island.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                IslandRoundButton(
                    symbol: "play.fill",
                    label: "Start a \(minutes(for: nextMode))-minute \(nextMode.title.lowercased())",
                    tint: nextMode.tint,
                    isProminent: true
                ) {
                    timer.start(nextMode, minutes: minutes(for: nextMode))
                }
            }
        }
        .modifier(IslandCardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus timer")
    }

    private var subtitle: String {
        let sessions = timer.focusSessionsToday
        let length = minutes(for: nextMode)
        return sessions == 0
            ? String(localized: "\(length) min")
            : String(localized: "\(length) min · \(sessions) done today")
    }
}

/// Download and upload speed. It measures only while this card is on screen.
struct IslandNetworkCard: View {
    @ObservedObject private var monitor: NetworkSpeedMonitor = .shared
    @StateObject private var lease = NetworkSpeedLease()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(symbol: "arrow.down", text: monitor.speed.formattedDownload, label: "Download")
            row(symbol: "arrow.up", text: monitor.speed.formattedUpload, label: "Upload")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(IslandCardBackground())
        // Narrower than the other cards, so a timer and an event still fit beside it.
        .frame(width: 86)
        .onAppear { lease.begin() }
        .onDisappear { lease.end() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network speed"))
        .accessibilityValue(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
    }

    private func row(symbol: String, text: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ZenithTheme.Island.textSecondary)
                .frame(width: 10)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ZenithTheme.Island.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help(label)
    }
}

struct IslandCalendarCard: View {
    let event: UpcomingEvent?
    let access: CalendarAccessState

    var body: some View {
        HStack(spacing: 9) {
            switch access {
            case .granted:
                if let event {
                    eventView(event)
                } else {
                    message(symbol: "calendar", title: "No more events", detail: "The next 12 hours are free")
                }
            case .notDetermined:
                message(symbol: "calendar.badge.exclamationmark", title: "Your next event", detail: "Needs calendar access")
                IslandRoundButton(symbol: "checkmark", label: "Allow calendar access", tint: Color(nsColor: .systemRed), isProminent: true) {
                    Task { await CalendarWidgetModel.shared.requestAccess() }
                }
            case .denied:
                message(symbol: "calendar.badge.exclamationmark", title: "Calendar is off", detail: "Allow Zenith in System Settings")
                IslandRoundButton(symbol: "gearshape.fill", label: "Open Calendar privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .unavailable:
                message(symbol: "calendar.badge.exclamationmark", title: "Calendar", detail: "Available in Zenith.app")
            }
        }
        .modifier(IslandCardBackground())
    }

    private func eventColor(_ event: UpcomingEvent) -> Color {
        if let c = event.colorComponents, c.count >= 3 {
            return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
        }
        return Color(nsColor: .systemRed)
    }

    private func eventView(_ event: UpcomingEvent) -> some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(eventColor(event))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(event.relativeDescription(now: context.date))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(event.isOngoing(at: context.date) ? AnyShapeStyle(eventColor(event)) : AnyShapeStyle(ZenithTheme.Island.textSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func message(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(ZenithTheme.Island.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
