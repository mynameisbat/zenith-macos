import AppKit
import ZenithCore

/// Starts the daily update check (`ZenithUpdater`, Core), shows its notice, and does the parts that need the app:
/// the install confirmation, opening a manual download, and quitting so the relaunch helper can reopen Zenith.
@MainActor
enum UpdateController {
    private static let noticeDuration: TimeInterval = 6

    static func start() {
        let updater = ZenithUpdater.shared
        updater.notifier = { title, subtitle in
            let island = ZenithIslandState.shared
            if island.isEnabled, !island.isHiddenForFullscreen {
                island.triggerAlert(icon: "arrow.down.circle.fill", title: title, subtitle: subtitle, duration: noticeDuration)
            } else {
                ToastHUDController.shared.show(verbatim: title, icon: "arrow.down.circle.fill", subtitle: subtitle)
            }
        }
        updater.start()
    }

    /// The Install button: confirm, install, then quit through the normal path (which restores the system proxy if
    /// Privacy Shield is on) and let the helper reopen the new version.
    static func installAndRelaunch(_ updater: ZenithUpdater = .shared) {
        Task { @MainActor in
            guard let installed = await updater.install(confirm: confirm) else { return }
            guard RelaunchHelper.start(appPath: installed.path) != nil else {
                ToastHUDController.shared.show(
                    message: "Zenith was updated. Quit and reopen it to start the new version.",
                    icon: "arrow.down.circle.fill"
                )
                return
            }
            AppDelegate.isExplicitQuit = true
            NSApp.terminate(nil)
        }
    }

    /// The fallback: save the DMG in Downloads and open it in Finder, as a download by hand would be.
    static func downloadForManualInstall(_ updater: ZenithUpdater = .shared) {
        Task { @MainActor in
            guard let file = await updater.downloadForManualInstall() else { return }
            NSWorkspace.shared.open(file)
        }
    }

    static func openReleasePage(_ release: UpdateRelease) {
        NSWorkspace.shared.open(release.releasePageURL)
    }

    /// Not destructive, so the install button is the default one; Cancel answers Escape.
    private static func confirm(_ release: UpdateRelease) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let version = release.version.description
        var message = String(localized: "Zenith downloads the update, checks that it is signed like this copy, replaces this copy and reopens. It quits for a moment while it does.")
        if PrivacyShieldStatistics.shared.isActive {
            message += "\n\n" + String(localized: "Privacy Shield is on: quitting turns it off and ends the connections other apps have open through it. Turn it on again after Zenith reopens.")
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Install Zenith \(version)?")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Install and Relaunch"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
