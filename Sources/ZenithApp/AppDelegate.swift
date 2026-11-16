import AppKit
import Combine
import ZenithCore

/// Main application lifecycle, status item setup, and global hotkey wiring delegate.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public static var isExplicitQuit = false

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Zenith] Application did finish launching in accessory mode.")

        // 1. Reassert accessory activation policy for LaunchServices / login items
        NSApplication.shared.setActivationPolicy(.accessory)

        // 2. Disable macOS automatic termination so closing Settings never kills the background app
        ProcessInfo.processInfo.disableAutomaticTermination("Zenith persistent menu bar accessory")

        // 3. Configure Settings window content provider
        SettingsWindowController.shared.configureDefaultContent()
        // Settings are a page of the island. The window is what is left when the island cannot show one (a
        // full-screen app has hidden it).
        SettingsWindowController.shared.presentationOverride = {
            let island = ZenithIslandState.shared
            guard island.isEnabled, !island.isHiddenForFullscreen else { return false }
            island.openPage(.settings)
            return true
        }

        // 4. Setup persistent Menu Bar status item & dropdown menu (F42, F43)
        // The icon is there only if Settings asks for it or the island has no Tools tab (`needsMenuBarIcon`):
        // otherwise everything is reached from the island.
        wireMenuBarActions()
        applyMenuBarIcon()
        menuBarIconObserver = IslandWidgetSettings.shared.objectWillChange.sink { [weak self] _ in
            // The new value is published before it is stored.
            Task { @MainActor [weak self] in self?.applyMenuBarIcon() }
        }

        // 5. Start background clipboard monitoring (F01)
        ClipboardStore.shared.soundService = AudioFeedbackManager.shared
        ClipboardStore.shared.startMonitoring()

        // 6. Register global hotkeys (F06, F13, F14)
        setupGlobalHotKeys()

        // 7. Launch Zenith Dynamic Island & Floating Pill
        ZenithIslandWindowController.shared.setup()

        // 8. Undo a system proxy left behind by an earlier crash before it leaves the user without internet
        let shieldPort = UInt16(clamping: PrivacyShieldStatistics.shared.port)
        Task.detached(priority: .utility) {
            _ = SystemProxyManager.shared.recoverFromUncleanShutdown(legacyPort: shieldPort)
        }
        ScheduledCleanerScanController.start()  // Cleaner's scheduled scan: off by default, scans only, never deletes
        UpdateController.start()  // daily update check: on by default, installs only after the user's click
        KeepAwakeHotKeyController.shared.apply()  // keep awake's shortcut: off by default
        CleaningModeCoordinator.shared.configure()  // full-screen windows, and the shortcut if Settings turned it on
        SnippetExpansionService.shared.refresh()  // typed snippet expansion: off by default, needs Accessibility
        AIAgentsCoordinator.shared.start()  // AI agents on the island: off by default, reads local logs only
    }

    private var menuBarIconObserver: AnyCancellable?

    private func applyMenuBarIcon() {
        if IslandWidgetSettings.shared.needsMenuBarIcon {
            MenuBarController.shared.setup()
        } else {
            MenuBarController.shared.teardown()
        }
    }

    /// Zenith was opened again while it runs (Finder, Spotlight, the Dock). With no menu bar icon this is the way
    /// in that always exists: show the settings, on the island when it can, else in their window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ZenithToolActions.openSettings()
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NSLog("[Zenith] Application will terminate. Releasing resources.")
        CleaningModeController.shared.end(.appQuit)  // releases the event tap
        if SystemProxyManager.shared.hasPendingRestore {
            _ = SystemProxyManager.shared.disableProxySynchronously()
        }
        LocalProxyServer.shared.stop()
        KeepAwakeService.shared.stop()  // release the power assertion; the Mac may sleep again
        ZenithIslandWindowController.shared.teardown()
        ClipboardStore.shared.stopMonitoring()
        MenuBarController.shared.teardown()
        HotKeyManager.shared.unregisterAll()
        SnippetExpansionService.shared.stop()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A running recording is finished and saved first; an unfinished file would not play.
        if ScreenRecorder.shared.state.isRecording {
            Task { @MainActor in
                await ScreenRecorder.shared.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // Allow clean termination when requested by user (⌘Q, Quit menu) or macOS System Settings ("Quit & Reopen")
        return .terminateNow
    }

    // MARK: - Menu Bar Routing

    private func wireMenuBarActions() {
        let menuBar = MenuBarController.shared

        menuBar.onClipboardHistory = {
            ClipboardPanelController.shared.toggle()
        }

        menuBar.onCaptureArea = {
            CaptureOverlayController.shared.startAreaCapture { image in
                guard let image = image else { return }
                AnnotationWindowController.shared.present(image: image)
            }
        }

        menuBar.onCaptureFullscreen = {
            CaptureOverlayController.shared.captureFullscreen { image in
                guard let image = image else { return }
                AnnotationWindowController.shared.present(image: image)
            }
        }

        menuBar.onRecordScreen = {
            ScreenRecordingCoordinator.shared.toggle()
        }

        menuBar.onScrollingCapture = {
            ScrollingCaptureCoordinator.shared.toggle()
        }

        menuBar.onClearHistory = {
            ClipboardStore.shared.clear()
            ToastHUDController.shared.show(message: "History Cleared", icon: "trash.fill")
        }

        menuBar.onTogglePrivacyShield = {
            PrivacyShieldController.shared.toggle()
        }

        menuBar.onShowPreferences = {
            SettingsWindowController.shared.configureDefaultContent()
            SettingsWindowController.shared.show()
        }

        menuBar.onQuit = {
            Self.isExplicitQuit = true
            NSApp.terminate(nil)
        }

        menuBar.onStatusItemClick = { button in
            ZenithCommandHubController.shared.toggle(relativeTo: button)
        }
    }

    // MARK: - Global HotKey Wiring

    public func setupGlobalHotKeys() {
        // Each action gets the shortcut saved in Settings, or its built-in one (see HotKeyConfigurator).
        let failed = HotKeyConfigurator.shared.registerAll([
            // Toggle Clipboard History
            (HotKeyDefinition.defaultClipboard, {
                Task { @MainActor in
                    ClipboardPanelController.shared.toggle()
                }
            }),
            // Area Screen Capture
            (HotKeyDefinition.defaultAreaCapture, {
                Task { @MainActor in
                    CaptureOverlayController.shared.startAreaCapture { image in
                        guard let image = image else { return }
                        NSLog("[Zenith] Area captured: \(image.width)x\(image.height)")
                        AnnotationWindowController.shared.present(image: image)
                    }
                }
            }),
            // Fullscreen Screen Capture
            (HotKeyDefinition.defaultFullscreenCapture, {
                Task { @MainActor in
                    CaptureOverlayController.shared.captureFullscreen { image in
                        guard let image = image else { return }
                        NSLog("[Zenith] Fullscreen captured: \(image.width)x\(image.height)")
                        AnnotationWindowController.shared.present(image: image)
                    }
                }
            }),
            // Screen OCR & Barcode Recognition
            (HotKeyDefinition.defaultOCR, {
                Task { @MainActor in
                    ScreenOCRCoordinator.shared.startAreaOCR()
                }
            }),
            // Snippet menu
            (HotKeyDefinition.defaultSnippetsMenu, {
                Task { @MainActor in
                    SnippetPanelController.shared.toggle()
                }
            }),
            // Screen recording: start choosing, or stop the running recording
            (HotKeyDefinition.defaultRecordScreen, {
                Task { @MainActor in
                    ScreenRecordingCoordinator.shared.toggle()
                }
            }),
            // Scrolling capture: start, or finish the running one
            (HotKeyDefinition.defaultScrollingCapture, {
                Task { @MainActor in
                    ScrollingCaptureCoordinator.shared.toggle()
                }
            })
        ])

        // A key combination another app holds cannot be registered. Say so instead of leaving a dead shortcut.
        if !failed.isEmpty {
            let names = failed.map { "\($0.keyEquivalent) (\($0.name))" }.joined(separator: ", ")
            NSLog("[Zenith] Shortcuts not registered: \(names)")
            Task { @MainActor in
                ToastHUDController.shared.show(
                    message: "Shortcut \(failed[0].keyEquivalent) is taken by another app. Change it in Settings → Shortcuts.",
                    icon: "exclamationmark.triangle.fill"
                )
            }
        }
    }
}
