import AppKit
import Combine
import ZenithCore

/// Starts and stops `AIAgentMonitor` with its settings (off by default) and shows its "finished" notices: on the
/// island, or as a floating toast when the island is off or hidden for a full-screen app. Both are read aloud.
@MainActor
final class AIAgentsCoordinator {
    static let shared = AIAgentsCoordinator()

    /// Longer than a confirmation toast: nobody asked for this one.
    private static let noticeDuration: TimeInterval = 5

    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        AIAgentMonitor.shared.onNotice = { notice in
            let island = ZenithIslandState.shared
            if island.isEnabled, !island.isHiddenForFullscreen {
                island.triggerAlert(
                    icon: "checkmark.circle.fill", title: notice.title, subtitle: notice.subtitle,
                    duration: Self.noticeDuration, tintColor: notice.kind.tint
                )
            } else {
                ToastHUDController.shared.show(verbatim: notice.title, icon: "checkmark.circle.fill", subtitle: notice.subtitle)
            }
        }

        apply()
        // `objectWillChange` fires before the new value is stored: apply on the next turn of the run loop.
        AIAgentSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
    }

    private func apply() {
        let settings = AIAgentSettings.shared
        let monitor = AIAgentMonitor.shared
        monitor.longTaskThreshold = settings.longTaskThreshold
        monitor.notifiesWhenFinished = settings.notifyWhenFinished
        monitor.start(kinds: settings.activeTools)
    }
}
