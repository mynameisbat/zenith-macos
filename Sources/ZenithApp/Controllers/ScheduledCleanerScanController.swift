import AppKit
import ZenithCore

/// Starts the Cleaner's scheduled scan (`CleanerScanScheduler`, Core) and gives it a way to tell the user what it
/// found. The scan only reads the disk; nothing here can delete a file.
@MainActor
enum ScheduledCleanerScanController {
    /// How long the island keeps the notice up: longer than a confirmation toast, since nobody asked for it.
    private static let noticeDuration: TimeInterval = 6

    static func start() {
        let scheduler = CleanerScanScheduler.shared
        scheduler.notifier = { title, subtitle in
            let island = ZenithIslandState.shared
            if island.isEnabled, !island.isHiddenForFullscreen {
                island.triggerAlert(icon: "sparkles", title: title, subtitle: subtitle, duration: noticeDuration)
            } else {
                ToastHUDController.shared.show(verbatim: title, icon: "sparkles", subtitle: subtitle)
            }
        }
        scheduler.start()
    }
}
