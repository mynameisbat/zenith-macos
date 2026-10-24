import AppKit
import Foundation

/// Specialized NSWindow for Settings that ensures keyboard dismissal (⌘W, Esc),
/// key/main window status in accessory applications, and robust event handling.
public final class SettingsWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public func dismissWindow() {
        if let controller = delegate as? SettingsWindowController {
            controller.dismiss()
        } else {
            orderOut(nil)
        }
    }

    public override func sendEvent(_ event: NSEvent) {
        // Intercept keyboard dismissal before any first responder / text field consumes it
        if event.type == .keyDown {
            // Escape key (keyCode 53) ALWAYS dismisses
            if event.keyCode == 53 {
                dismissWindow()
                return
            }
            // ⌘W ALWAYS dismisses
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased(),
               chars == "w" {
                dismissWindow()
                return
            }
        }

        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            let loc = event.locationInWindow
            var isCloseHit = false

            // 1. Direct hit-testing against the standard close button geometry with generous halo
            if let closeBtn = standardWindowButton(.closeButton) {
                let closeRectInWindow = closeBtn.convert(closeBtn.bounds, to: nil)
                let hitTarget = closeRectInWindow.insetBy(dx: -10, dy: -10)
                if hitTarget.contains(loc) {
                    isCloseHit = true
                }
            }

            // 2. Generous fallback bounding box covering the top-left traffic light zone
            if !isCloseHit && loc.x >= 0 && loc.x <= 60 && loc.y >= (frame.height - 44) && loc.y <= frame.height {
                isCloseHit = true
            }

            if isCloseHit {
                dismissWindow()
                return
            }
        }
        super.sendEvent(event)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w") {
            dismissWindow()
            return
        }
        super.keyDown(with: event)
    }

    public override func performClose(_ sender: Any?) {
        dismissWindow()
    }

    public override func close() {
        dismissWindow()
        super.close()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "w" {
            dismissWindow()
            return true
        }
        if event.keyCode == 53 { // Escape
            dismissWindow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        dismissWindow()
    }
}

/// Dedicated AppKit window controller managing the Preferences / Settings window (Feature F45).
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    public static let defaultWidth: CGFloat = 680
    public static let defaultHeight: CGFloat = 490

    public var viewControllerProvider: (@MainActor () -> NSViewController)?

    public override init(window: NSWindow? = nil) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Idempotently presents the Settings window, centering it and activating GoldenGate.
    public func show() {
        let win = window ?? createWindow()
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }

        // Re-assert geometry and wire traffic light buttons upon presentation
        let currentOrigin = win.frame.origin
        let targetFrame = NSRect(x: currentOrigin.x, y: currentOrigin.y, width: Self.defaultWidth, height: Self.defaultHeight)
        win.setFrame(targetFrame, display: true)

        if let closeBtn = win.standardWindowButton(.closeButton) {
            closeBtn.target = self
            closeBtn.action = #selector(handleCloseButtonAction)
            closeBtn.isEnabled = true
            closeBtn.isHidden = false
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Asynchronously reassert key status in case a dismissing popover or transient menu steals focus
        DispatchQueue.main.async { [weak win] in
            win?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Creates and configures the fixed 680x490 non-resizable settings window.
    @discardableResult
    public func createWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let frameRect = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        let contentRect = NSWindow.contentRect(forFrameRect: frameRect, styleMask: styleMask)

        let newWindow = SettingsWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Zenith Settings"
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isMovableByWindowBackground = true
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: Self.defaultWidth, height: Self.defaultHeight)
        newWindow.maxSize = NSSize(width: Self.defaultWidth, height: Self.defaultHeight)
        newWindow.delegate = self

        if let provider = viewControllerProvider {
            newWindow.contentViewController = provider()
        }

        // Re-assert geometry and center after contentViewController is installed
        newWindow.setFrame(frameRect, display: true)
        newWindow.center()

        // Wire traffic light close button directly
        if let closeBtn = newWindow.standardWindowButton(.closeButton) {
            closeBtn.target = self
            closeBtn.action = #selector(handleCloseButtonAction)
            closeBtn.isEnabled = true
            closeBtn.isHidden = false
        }

        self.window = newWindow
        return newWindow
    }

    // MARK: - Actions & NSWindowDelegate

    @objc public func handleCloseButtonAction() {
        dismiss()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return true
    }

    public func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    /// Programmatically orders out and dismisses the settings window.
    public func dismiss() {
        window?.orderOut(nil)
    }

    public override func close() {
        dismiss()
        super.close()
    }
}

