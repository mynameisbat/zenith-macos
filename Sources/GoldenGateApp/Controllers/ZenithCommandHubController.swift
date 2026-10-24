import AppKit
import SwiftUI
import GoldenGateCore

/// Manages the native macOS floating popover for the Zenith Command Hub.
@MainActor
public final class ZenithCommandHubController: NSObject, NSPopoverDelegate {
    public static let shared = ZenithCommandHubController()

    private var popover: NSPopover?
    private var eventMonitor: Any?

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
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover?.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the popover with optional immediate suppression of window animations.
    public func close(immediately: Bool = false) {
        removeEventMonitor()
        if immediately {
            popover?.animates = false
            popover?.performClose(nil)
            popover?.animates = true
        } else {
            popover?.performClose(nil)
        }
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

        let state = ZenithCommandHubState.shared

        // Escape: cancel a pending confirmation or Quick Look first, otherwise dismiss popover
        if relevantModifiers.isEmpty && event.keyCode == 53 {
            if state.pendingConfirmation != nil {
                state.cancelConfirmation()
            } else if state.quickLookItem != nil {
                state.quickLookItem = nil
            } else {
                close()
            }
            return true
        }

        // ↓ / ↑: move keyboard selection through actions and clips
        if relevantModifiers.isEmpty && (event.keyCode == 125 || event.keyCode == 126) {
            guard state.pendingConfirmation == nil else { return true }
            let entryCount = state.entries(in: ClipboardStore.shared.items).count
            state.moveSelection(by: event.keyCode == 125 ? 1 : -1, entryCount: entryCount)
            return true
        }

        // Command + Shift shortcuts (⌘⇧2, ⌘⇧1, ⌘⇧V)
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

            // ⌘1..⌘4: Quick select clip
            let numberKeyCodes: [UInt16] = [18, 19, 20, 21] // 1, 2, 3, 4
            if let index = numberKeyCodes.firstIndex(of: event.keyCode) {
                return selectClipAtIndex(index)
            }
            if let chars = event.charactersIgnoringModifiers,
               let first = chars.first,
               let digit = Int(String(first)),
               digit >= 1 && digit <= 4 {
                return selectClipAtIndex(digit - 1)
            }
        }

        return false
    }

    private func selectClipAtIndex(_ index: Int) -> Bool {
        let items = ZenithCommandHubState.shared.visibleClips(in: ClipboardStore.shared.items)

        guard index >= 0 && index < items.count else { return true }
        let item = items[index]
        ClipboardStore.shared.selectAndRestoreItem(item)
        ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
        close()
        return true
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        removeEventMonitor()
    }
}
