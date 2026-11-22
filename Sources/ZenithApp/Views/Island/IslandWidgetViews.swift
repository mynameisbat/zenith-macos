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

    /// Two cards or more share the island's 380 pt: the timer card is the compact one then.
    private var cardCount: Int {
        [islandState.showsTimerWidget, islandState.showsCalendarWidget, islandState.showsNetworkWidget].filter { $0 }.count
    }

    /// At most two cards side by side. With all three widgets on, the network speed is not a card of its own but a
    /// one-line chip (download and upload) at the foot of the event's card, so the event keeps room for a title like
    /// "Design review".
    private var foldsNetworkIntoEvent: Bool {
        cardCount == 3
    }

    var body: some View {
        HStack(spacing: 8) {
            if islandState.showsTimerWidget {
                // Beside another card the timer keeps to what it needs, so the other gets the rest.
                // With an event beside it the timer keeps to 156 pt; beside the network speed alone it takes the rest.
                IslandTimerCard(snapshot: islandState.focusTimer, isCompact: cardCount > 1)
                    .frame(maxWidth: islandState.showsCalendarWidget ? 156 : .infinity)
            }
            if islandState.showsCalendarWidget {
                IslandCalendarCard(
                    event: islandState.upcomingEvent, access: islandState.calendarAccess,
                    isCompact: cardCount > 1, showsNetworkChip: foldsNetworkIntoEvent
                )
            }
            if islandState.showsNetworkWidget && !foldsNetworkIntoEvent {
                IslandNetworkCard(isCompact: false)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared card look for the island widgets: a light surface with an inner stroke, concentric with the island.
struct IslandCardBackground: ViewModifier {
    /// A small uppercase label above the content, saying what the card is. Without one the content is centred.
    var caption: LocalizedStringKey?
    /// Less padding beside the sides, for the Widgets tab when it has to fit three cards.
    var horizontalPadding: CGFloat = 14

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                Text(caption)
                    .textCase(.uppercase)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

struct IslandTimerCard: View {
    let snapshot: FocusTimerSnapshot?
    var isCompact = false
    @ObservedObject private var settings: IslandWidgetSettings = .shared
    @ObservedObject private var timer: FocusTimerService = .shared

    /// After a focus session the next thing to start is a break, and the other way round.
    private var nextMode: FocusTimerMode {
        timer.lastFinishedMode == .focus ? .shortBreak : .focus
    }

    private func minutes(for mode: FocusTimerMode) -> Int {
        mode == .focus ? settings.focusMinutes : settings.breakMinutes
    }

    private var ringSize: CGFloat { isCompact ? 26 : 34 }
    private var buttonSize: CGFloat { isCompact ? 20 : 26 }

    var body: some View {
        HStack(spacing: isCompact ? 4 : 8) {
            if let snapshot {
                IslandTimerRing(progress: snapshot.progress, tint: snapshot.mode.tint, symbol: snapshot.mode.symbolName, size: ringSize, lineWidth: 3.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.remainingText)
                        .font(.system(size: isCompact ? 18 : 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ZenithTheme.Island.textPrimary)
                        .fixedSize()
                    (snapshot.isPaused ? Text("Paused") : Text(verbatim: snapshot.mode.title))
                        .font(.system(size: 11))
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
                    isProminent: true,
                    size: buttonSize
                ) {
                    timer.togglePause()
                }
                IslandRoundButton(symbol: "stop.fill", label: "Stop timer", size: buttonSize) {
                    timer.stop()
                }
            } else {
                IslandTimerRing(progress: 0, tint: nextMode.tint, symbol: nextMode.symbolName, size: ringSize, lineWidth: 3.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nextMode == .focus ? "Focus" : "Break")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(ZenithTheme.Island.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(ZenithTheme.Island.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                IslandRoundButton(
                    symbol: "play.fill",
                    label: "Start a \(minutes(for: nextMode))-minute \(nextMode.title.lowercased())",
                    tint: nextMode.tint,
                    isProminent: true,
                    size: buttonSize
                ) {
                    timer.start(nextMode, minutes: minutes(for: nextMode))
                }
            }
        }
        .modifier(IslandCardBackground(caption: "Focus Timer", horizontalPadding: isCompact ? 8 : 14))
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

/// Download and upload speed. It measures only while this card is on screen. Beside a timer and an event
/// (`isCompact`) it is a small chip with no caption.
struct IslandNetworkCard: View {
    var isCompact = false
    @ObservedObject private var monitor: NetworkSpeedMonitor = .shared
    @StateObject private var lease = NetworkSpeedLease()

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 3 : 4) {
            row(symbol: "arrow.down", text: monitor.speed.formattedDownload, label: "Download")
            row(symbol: "arrow.up", text: monitor.speed.formattedUpload, label: "Upload")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(IslandCardBackground(caption: isCompact ? nil : "Network Speed", horizontalPadding: isCompact ? 10 : 14))
        // Narrower than the other cards, so a timer or an event still fits beside it.
        .frame(width: isCompact ? 88 : 128)
        .onAppear { lease.begin() }
        .onDisappear { lease.end() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network speed"))
        .accessibilityValue(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
    }

    private func row(symbol: String, text: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(ZenithTheme.Island.textSecondary)
                .frame(width: 10)
            Text(verbatim: text)
                .font(.system(size: isCompact ? 12 : 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ZenithTheme.Island.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help(label)
    }
}

/// The network speed as one line of a card (`IslandCalendarCard` when all three widgets are on): download and upload.
/// It measures only while it is on screen.
struct IslandNetworkChip: View {
    @ObservedObject private var monitor: NetworkSpeedMonitor = .shared
    @StateObject private var lease = NetworkSpeedLease()

    var body: some View {
        HStack(spacing: 8) {
            speed(symbol: "arrow.down", text: monitor.speed.formattedDownload)
            speed(symbol: "arrow.up", text: monitor.speed.formattedUpload)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .onAppear { lease.begin() }
        .onDisappear { lease.end() }
        .help(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network speed"))
        .accessibilityValue(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
    }

    private func speed(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(verbatim: text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(ZenithTheme.Island.textSecondary)
    }
}

struct IslandCalendarCard: View {
    let event: UpcomingEvent?
    let access: CalendarAccessState
    var isCompact = false
    /// The network speed as a line under the event.
    var showsNetworkChip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            cardBody
            if showsNetworkChip {
                IslandNetworkChip()
            }
        }
        .modifier(IslandCardBackground(caption: "Next Event", horizontalPadding: isCompact ? 12 : 14))
    }

    private var cardBody: some View {
        HStack(spacing: 8) {
            switch access {
            case .granted:
                if let event {
                    eventView(event)
                } else {
                    message(symbol: "calendar", title: "No more events", detail: "The next 12 hours are free")
                }
            case .notDetermined:
                message(symbol: "calendar.badge.exclamationmark", title: "Your next event", detail: "Needs calendar access")
                IslandRoundButton(symbol: "checkmark", label: "Allow calendar access", tint: Color(nsColor: .systemRed), isProminent: true, size: 28) {
                    Task { await CalendarWidgetModel.shared.requestAccess() }
                }
            case .denied:
                message(symbol: "calendar.badge.exclamationmark", title: "Calendar is off", detail: "Allow Zenith in System Settings")
                IslandRoundButton(symbol: "gearshape.fill", label: "Open Calendar privacy settings", size: 28) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .unavailable:
                message(symbol: "calendar.badge.exclamationmark", title: "Calendar", detail: "Available in Zenith.app")
            }
        }
    }

    private func eventColor(_ event: UpcomingEvent) -> Color {
        if let c = event.colorComponents, c.count >= 3 {
            return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: 1)
        }
        return Color(nsColor: .systemRed)
    }

    private func eventView(_ event: UpcomingEvent) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(eventColor(event))
                .frame(width: 3, height: showsNetworkChip ? 26 : 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(event.relativeDescription(now: context.date))
                        .font(.system(size: 11.5))
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
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ZenithTheme.Island.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
