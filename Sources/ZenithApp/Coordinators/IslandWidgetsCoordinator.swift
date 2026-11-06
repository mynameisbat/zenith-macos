import AppKit
import Combine
import ZenithCore

/// Connects the island widgets to their settings: starts the calendar model while the Calendar widget is on (asking
/// for access only when the user turns it on, never at launch) and plays a sound when a timer ends.
@MainActor
final class IslandWidgetsCoordinator {
    static let shared = IslandWidgetsCoordinator()

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let settings = IslandWidgetSettings.shared

        FocusTimerService.shared.onFinish = { _ in
            let store = SettingsStore.shared
            guard store.soundEffectsEnabled, let sound = NSSound(named: "Glass") else { return }
            sound.volume = store.soundVolume
            sound.play()
        }

        // At launch: show the next event if the widget is on, without prompting.
        if settings.showCalendar {
            CalendarWidgetModel.shared.start()
        }

        // Later changes come from the Settings switch, so asking is expected then.
        settings.$showCalendar
            .dropFirst()
            .removeDuplicates()
            .sink { isOn in
                let model = CalendarWidgetModel.shared
                if isOn {
                    model.start()
                    if model.access == .notDetermined {
                        Task { await model.requestAccess() }
                    }
                } else {
                    model.stop()
                }
            }
            .store(in: &cancellables)
    }
}
