import Foundation
import SwiftUI

/// A focus (Pomodoro) timer shown in the Dynamic Island.
///
/// Counts down to an end date rather than counting ticks, so it stays right across sleep and a busy main thread.
/// While it runs it writes a `FocusTimerSnapshot` into the island state once a second; when it ends it shows an island
/// alert, counts a finished focus session, and calls `onFinish` (the app plays a sound there).
@MainActor
public final class FocusTimerService: ObservableObject {
    public static let shared = FocusTimerService()

    @Published public private(set) var snapshot: FocusTimerSnapshot?
    /// Focus sessions run to the end today.
    @Published public private(set) var completedFocusSessions: Int = 0
    /// The kind of timer that finished last, so the widget can offer the other one next.
    @Published public private(set) var lastFinishedMode: FocusTimerMode?

    /// Called when a timer reaches zero (not when it is stopped).
    public var onFinish: ((FocusTimerMode) -> Void)?

    private let now: () -> Date
    private let calendar: Calendar
    private weak var island: ZenithIslandState?
    private let autoTick: Bool

    private var mode: FocusTimerMode = .focus
    private var duration: TimeInterval = 0
    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var tickTask: Task<Void, Never>?
    private var sessionsDay: Date?

    /// - Parameters:
    ///   - now: The clock (tests pass their own).
    ///   - island: Where the timer is shown.
    ///   - autoTick: Whether to refresh once a second on its own; tests call `tick()` instead.
    public init(
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        island: ZenithIslandState? = .shared,
        autoTick: Bool = true
    ) {
        self.now = now
        self.calendar = calendar
        self.island = island
        self.autoTick = autoTick
    }

    /// Focus sessions finished today (the count starts again each day).
    public var focusSessionsToday: Int {
        sessionsDay == calendar.startOfDay(for: now()) ? completedFocusSessions : 0
    }

    public var isRunning: Bool {
        snapshot != nil && snapshot?.isPaused == false
    }

    // MARK: Controls

    /// Starts (or restarts) a timer of the given length.
    public func start(_ mode: FocusTimerMode, minutes: Int) {
        let seconds = TimeInterval(max(1, minutes) * 60)
        self.mode = mode
        duration = seconds
        endDate = now().addingTimeInterval(seconds)
        pausedRemaining = nil
        publish()
        startTicking()
    }

    public func pause() {
        guard let endDate, pausedRemaining == nil else { return }
        pausedRemaining = max(0, endDate.timeIntervalSince(now()))
        self.endDate = nil
        stopTicking()
        publish()
    }

    public func resume() {
        guard let remaining = pausedRemaining else { return }
        endDate = now().addingTimeInterval(remaining)
        pausedRemaining = nil
        publish()
        startTicking()
    }

    public func togglePause() {
        if pausedRemaining != nil {
            resume()
        } else {
            pause()
        }
    }

    /// Ends the timer without counting it as finished.
    public func stop() {
        endDate = nil
        pausedRemaining = nil
        duration = 0
        stopTicking()
        publish()
    }

    /// Adds time to the running or paused timer.
    public func extend(byMinutes minutes: Int) {
        let extra = TimeInterval(minutes * 60)
        if let endDate {
            self.endDate = endDate.addingTimeInterval(extra)
        } else if let remaining = pausedRemaining {
            pausedRemaining = remaining + extra
        } else {
            return
        }
        duration += extra
        publish()
    }

    /// Recomputes the remaining time; finishes the timer when it has run out.
    public func tick() {
        guard let endDate else { return }
        if endDate.timeIntervalSince(now()) <= 0 {
            finish()
        } else {
            publish()
        }
    }

    // MARK: Internals

    private func finish() {
        let finished = mode
        endDate = nil
        pausedRemaining = nil
        duration = 0
        stopTicking()
        lastFinishedMode = finished
        if finished == .focus {
            rollSessionDayIfNeeded()
            completedFocusSessions += 1
        }
        publish()
        island?.triggerAlert(
            icon: finished == .focus ? "checkmark.circle.fill" : "cup.and.saucer.fill",
            title: finished == .focus ? String(localized: "Focus session done") : String(localized: "Break is over"),
            subtitle: finished == .focus ? String(localized: "Time for a short break") : String(localized: "Ready for the next focus session?"),
            duration: 4,
            tintColor: Color(nsColor: .systemOrange)
        )
        onFinish?(finished)
    }

    private func rollSessionDayIfNeeded() {
        let today = calendar.startOfDay(for: now())
        if sessionsDay != today {
            sessionsDay = today
            completedFocusSessions = 0
        }
    }

    private func publish() {
        let value: FocusTimerSnapshot?
        if let endDate {
            value = FocusTimerSnapshot(mode: mode, isPaused: false, duration: duration, remaining: max(0, endDate.timeIntervalSince(now())))
        } else if let pausedRemaining {
            value = FocusTimerSnapshot(mode: mode, isPaused: true, duration: duration, remaining: pausedRemaining)
        } else {
            value = nil
        }
        if snapshot != value {
            snapshot = value
        }
        if island?.focusTimer != value {
            island?.focusTimer = value
        }
    }

    private func startTicking() {
        guard autoTick else { return }
        stopTicking()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
