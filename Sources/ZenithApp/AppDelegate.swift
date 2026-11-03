import AppKit
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

        // 4. Setup persistent Menu Bar status item & dropdown menu (F42, F43)
        wireMenuBarActions()
        MenuBarController.shared.setup()

        // 5. Start background clipboard monitoring (F01)
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
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NSLog("[Zenith] Application will terminate. Releasing resources.")
        if SystemProxyManager.shared.hasPendingRestore {
            _ = SystemProxyManager.shared.disableProxySynchronously()
        }
        LocalProxyServer.shared.stop()
        ZenithIslandWindowController.shared.teardown()
        ClipboardStore.shared.stopMonitoring()
        MenuBarController.shared.teardown()
        HotKeyManager.shared.unregisterAll()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        let hotKeyManager = HotKeyManager.shared

        // ⌘⇧V - Toggle Clipboard History
        hotKeyManager.registerHotKey(HotKeyDefinition.defaultClipboard) {
            Task { @MainActor in
                ClipboardPanelController.shared.toggle()
            }
        }

        // ⌘⇧2 - Area Screen Capture
        hotKeyManager.registerHotKey(HotKeyDefinition.defaultAreaCapture) {
            Task { @MainActor in
                CaptureOverlayController.shared.startAreaCapture { image in
                    guard let image = image else { return }
                    NSLog("[Zenith] Area captured: \(image.width)x\(image.height)")
                    AnnotationWindowController.shared.present(image: image)
                }
            }
        }

        // ⌘⇧1 - Fullscreen Screen Capture
        hotKeyManager.registerHotKey(HotKeyDefinition.defaultFullscreenCapture) {
            Task { @MainActor in
                CaptureOverlayController.shared.captureFullscreen { image in
                    guard let image = image else { return }
                    NSLog("[Zenith] Fullscreen captured: \(image.width)x\(image.height)")
                    AnnotationWindowController.shared.present(image: image)
                }
            }
        }

        // ⌘⇧3 - Screen OCR & Barcode Recognition
        let ocrDefinition = HotKeyDefinition(
            id: "capture.ocr",
            name: "Screen OCR",
            keyCode: 20, // kVK_ANSI_3
            carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue,
            keyEquivalent: "⌘⇧3"
        )
        hotKeyManager.registerHotKey(ocrDefinition) {
            Task { @MainActor in
                ScreenOCRCoordinator.shared.startAreaOCR()
            }
        }
    }
}
