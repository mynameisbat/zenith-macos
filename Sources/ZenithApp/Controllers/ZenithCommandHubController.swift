import AppKit
import SwiftUI
import ZenithCore

/// Manages the native macOS floating popover for the Zenith Command Hub.
@MainActor
public final class ZenithCommandHubController: NSObject, NSPopoverDelegate {
    public static let shared = ZenithCommandHubController()

    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var telemetryTimer: Timer?

    public var isVisible: Bool {
        popover?.isShown ?? false
    }

    public override init() {
        super.init()
    }

    /// Toggles the Command Hub popover anchored to the status bar button.
    public func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    /// Shows the popover anchored to the given button.
    public func show(relativeTo button: NSStatusBarButton) {
        ZenithCommandHubState.shared.reset()
        if popover == nil {
            let newPopover = NSPopover()
            newPopover.behavior = .transient
            newPopover.animates = true
            newPopover.delegate = self

            let hubView = ZenithCommandHubView(
                onAreaCapture: { [weak self] in
                    self?.close(immediately: true)
                    CaptureOverlayController.shared.startAreaCapture { image in
                        guard let image = image else { return }
                        AnnotationWindowController.shared.present(image: image)
                    }
                },
                onFullscreenCapture: { [weak self] in
                    self?.close(immediately: true)
                    CaptureOverlayController.shared.captureFullscreen { image in
                        guard let image = image else { return }
                        AnnotationWindowController.shared.present(image: image)
                    }
                },
                onScreenOCR: { [weak self] in
                    self?.close(immediately: true)
                    ScreenOCRCoordinator.shared.startAreaOCR()
                },
                onOpenClipboard: { [weak self] in
                    self?.close()
                    ClipboardPanelController.shared.show()
                },
                onOpenPreferences: { [weak self] in
                    self?.close()
                    SettingsWindowController.shared.configureDefaultContent()
                    SettingsWindowController.shared.show()
                },
                onQuit: {
                    AppDelegate.isExplicitQuit = true
                    NSApp.terminate(nil)
                },
                onClose: { [weak self] in
                    self?.close()
                }
            )

            let hostingController = NSHostingController(rootView: hubView)
            newPopover.contentViewController = hostingController
            self.popover = newPopover
        }

        installEventMonitor()
        startTelemetryPolling()
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover?.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the popover with optional immediate suppression of window animations.
    public func close(immediately: Bool = false) {
        stopTelemetryPolling()
        removeEventMonitor()
        if immediately {
            popover?.animates = false
            popover?.performClose(nil)
            popover?.animates = true
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Telemetry Polling Lifecycle (Zero Idle CPU)

    private func startTelemetryPolling() {
        stopTelemetryPolling()
        ZenithCommandHubState.shared.refreshHardwareSnapshot()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isVisible else {
                    self?.stopTelemetryPolling()
                    return
                }
                ZenithCommandHubState.shared.refreshHardwareSnapshot()
            }
        }
    }

    private func stopTelemetryPolling() {
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    // MARK: - Key Event Handling

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if self.handleKeyEvent(event) {
                return nil
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])

        // Escape: Dismiss popover
        if relevantModifiers.isEmpty && event.keyCode == 53 {
            close()
            return true
        }

        // Command + Shift shortcuts (⌘⇧2, ⌘⇧1, ⌘⇧V). Not ⌘⇧3: that is macOS's own screenshot shortcut, and Screen OCR
        // is a global shortcut (⌃⌥T by default) that works whether or not this popover is open.
        if relevantModifiers == [.command, .shift] {
            if event.keyCode == 19 || event.charactersIgnoringModifiers == "2" {
                // ⌘⇧2: Area capture
                close(immediately: true)
                CaptureOverlayController.shared.startAreaCapture { image in
                    guard let image = image else { return }
                    AnnotationWindowController.shared.present(image: image)
                }
                return true
            }
            if event.keyCode == 18 || event.charactersIgnoringModifiers == "1" {
                // ⌘⇧1: Screen capture
                close(immediately: true)
                CaptureOverlayController.shared.captureFullscreen { image in
                    guard let image = image else { return }
                    AnnotationWindowController.shared.present(image: image)
                }
                return true
            }
            if event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v" {
                // ⌘⇧V: Open clipboard
                close()
                ClipboardPanelController.shared.show()
                return true
            }
        }

        // Command shortcuts (⌘,, ⌘Q, ⌘1..⌘4)
        if relevantModifiers == [.command] {
            // ⌘,: Preferences
            if event.keyCode == 43 || event.charactersIgnoringModifiers == "," {
                close()
                SettingsWindowController.shared.configureDefaultContent()
                SettingsWindowController.shared.show()
                return true
            }

            // ⌘Q: Quit
            if event.keyCode == 12 || event.charactersIgnoringModifiers?.lowercased() == "q" {
                AppDelegate.isExplicitQuit = true
                NSApp.terminate(nil)
                return true
            }

            // ⌘1..⌘4: quit the app in that row (after a confirmation)
            let numberKeyCodes: [UInt16] = [18, 19, 20, 21] // 1, 2, 3, 4
            if let index = numberKeyCodes.firstIndex(of: event.keyCode) {
                return handleQuickActionAtIndex(index)
            }
            if let chars = event.charactersIgnoringModifiers,
               let first = chars.first,
               let digit = Int(String(first)),
               digit >= 1 && digit <= 4 {
                return handleQuickActionAtIndex(digit - 1)
            }
        }

        return false
    }

    private func handleQuickActionAtIndex(_ index: Int) -> Bool {
        let hogs = ZenithCommandHubState.shared.filteredTopHogs
        guard index >= 0 && index < hogs.count else {
            return false
        }
        let hog = hogs[index]
        // Asks first, like the button does.
        let quitIt = ZenithCommandHubState.shared.terminate(hog) { title, message, action in
            DestructiveConfirmation.confirm(verbatimTitle: title, message: message, destructiveTitle: action)
        }
        if quitIt {
            ToastHUDController.shared.show(message: "Asked \(hog.name) to quit", icon: "xmark.circle.fill")
        }
        return true
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        stopTelemetryPolling()
        removeEventMonitor()
    }
}
