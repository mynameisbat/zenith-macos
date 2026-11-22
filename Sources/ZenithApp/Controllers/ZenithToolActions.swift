import AppKit
import ZenithCore

/// What Zenith's launch buttons do, in one place: the Command Hub and the island's Tools tab run the same code, with
/// the same confirmations.
@MainActor
enum ZenithToolActions {
    /// Runs one of the island's tools: opens its page in the island, flips its switch, or does what the hub's button did.
    static func run(_ tool: IslandTool) {
        if let page = tool.page {
            if tool == .uninstall {
                CleanerSettingsLink.request(section: CleanerSettingsLink.uninstallSection)
            }
            ZenithIslandState.shared.openPage(page)
            return
        }
        switch tool {
        case .area: captureArea()
        case .screen: captureScreen()
        case .record: ScreenRecordingCoordinator.shared.toggle()  // starts choosing, or stops a running recording
        case .ocr: ScreenOCRCoordinator.shared.startAreaOCR()
        case .clipboard: ClipboardPanelController.shared.show()
        case .cleaning: CleaningModeCoordinator.shared.start()
        case .clean: clean()
        case .boost: boost()
        case .privacyShield: PrivacyShieldController.shared.toggle()
        case .keepAwake: KeepAwakeService.shared.toggle()
        case .quit: quit()
        case .uninstall, .cleaner, .system, .ports, .homebrew, .settings, .allTools: break  // pages, handled above
        }
    }

    static func quit() {
        AppDelegate.isExplicitQuit = true
        NSApp.terminate(nil)
    }

    static func captureArea() {
        CaptureOverlayController.shared.startAreaCapture { image in
            guard let image = image else { return }
            AnnotationWindowController.shared.present(image: image)
        }
    }

    static func captureScreen() {
        CaptureOverlayController.shared.captureFullscreen { image in
            guard let image = image else { return }
            AnnotationWindowController.shared.present(image: image)
        }
    }

    static func openSettings() {
        SettingsWindowController.shared.configureDefaultContent()
        SettingsWindowController.shared.show()
    }

    /// Settings → Cleaner → Uninstall.
    static func openUninstaller() {
        CleanerSettingsLink.request(section: CleanerSettingsLink.uninstallSection)
        SettingsTab.requestSelection(.cleaner)
        openSettings()
    }

    /// Scans if nothing has been scanned, shows what would go, and deletes only after a yes.
    static func clean() {
        let cleaner = SystemCleanerService.shared
        Task {
            // Nothing has been scanned yet: look first, so there is something to confirm.
            if cleaner.categories.isEmpty && !cleaner.isScanning {
                // From the island the button is gone once it is clicked: say that something is happening.
                ToastHUDController.shared.show(message: "Scanning for system junk…", icon: "sparkles")
                await cleaner.scan()
                CleanerScanScheduler.shared.noteManualScan(reclaimableBytes: cleaner.selectedJunkSize, itemCount: cleaner.selectedItemCount)
            }
            guard cleaner.selectedJunkSize > 0 else {
                ToastHUDController.shared.show(message: "No system junk found", icon: "checkmark.circle.fill")
                return
            }
            guard DestructiveConfirmation.confirm(
                    title: "Delete \(cleaner.formatSelectedSize) permanently?",
                    message: "These cannot be restored:\n\(cleaner.selectionSummary)",
                    destructiveTitle: "Delete Permanently"
                  ) else { return }

            let freed = await cleaner.cleanSelected()
            if freed > 0 {
                ToastHUDController.shared.show(
                    message: "Freed \(SystemCleanerService.formatBytes(freed))",
                    icon: "sparkles"
                )
            }
            if let message = ZenithCommandHubView.failureMessage(for: cleaner.lastFailedItemNames) {
                ToastHUDController.shared.show(verbatim: message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    static func boost() {
        Task {
            let result = await ZenithCommandHubState.shared.boostSystem()
            ToastHUDController.shared.show(verbatim: result.message, icon: "bolt.fill")
        }
    }
}

/// Opens Settings → Cleaner on one of its sections. The tab may not exist yet when asked, so the request is kept
/// until it appears (as `HomebrewSettingsLink` does for its tab).
@MainActor
enum CleanerSettingsLink {
    static let notification = Notification.Name("zenith.showCleanerSection")
    static let uninstallSection = "Uninstall"
    private static var pendingSection: String?

    static func request(section: String) {
        pendingSection = section
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func takePending() -> String? {
        defer { pendingSection = nil }
        return pendingSection
    }
}

/// Carries the dialog into the run-loop block, which only ever runs on the main thread. (Whether `NSWindow` is
/// `Sendable` differs between SDKs, so neither a plain capture nor `nonisolated(unsafe)` builds cleanly on both.)
private struct DialogWindow: @unchecked Sendable {
    let window: NSWindow
}

/// Dialogs asked for from an island page (a confirmation, a file chooser) must not open underneath it: the island
/// floats above the menu bar, and a page can cover the middle of the screen.
@MainActor
enum IslandDialogs {
    static func raiseAboveIsland(_ window: NSWindow) {
        guard ZenithIslandState.shared.page != nil else { return }
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.level = level
        // `runModal()` puts an alert or open panel back at the modal-panel level as it starts, which is under the
        // island: the dialog was there but hidden, and Zenith looked stuck. Raise it again once the modal session runs.
        let dialog = DialogWindow(window: window)
        RunLoop.main.perform(inModes: [.modalPanel, .common]) {
            MainActor.assumeIsolated { dialog.window.level = level }
        }
    }
}
