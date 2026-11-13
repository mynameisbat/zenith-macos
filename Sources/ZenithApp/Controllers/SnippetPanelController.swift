import AppKit
import SwiftUI
import ZenithCore

/// A borderless floating panel that can take keyboard focus without becoming the main window.
private final class SnippetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == [.command], event.keyCode == KeyboardNavigationEngine.KeyCodes.keyW {
            SnippetPanelController.shared.hide()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The snippet menu (⌃⌥S by default): search the snippets, Return inserts the chosen one where the user was typing.
@MainActor
public final class SnippetPanelController: NSObject, NSWindowDelegate {
    public static let shared = SnippetPanelController()
    public static let panelSize = CGSize(width: 420, height: 360)

    private var panel: SnippetPanel?
    private let model = SnippetPickerModel()
    private var keyMonitor: Any?
    private var previousApplication: NSRunningApplication?

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
        let panel = self.panel ?? makePanel()
        model.reset()
        let frame = PanelPositioner.calculateFrame(
            mouseLocation: NSEvent.mouseLocation,
            panelSize: Self.panelSize,
            mode: .nearMouse
        )
        panel.setFrame(frame, display: true)
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hide() {
        uninstallKeyMonitor()
        panel?.orderOut(nil)
    }

    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> SnippetPanel {
        let panel = SnippetPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        panel.delegate = self
        let view = SnippetPickerView(
            model: model,
            onInsert: { [weak self] snippet in self?.insert(snippet) },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Hides the menu, brings back the app the user was typing in, and inserts the snippet there.
    func insert(_ snippet: Snippet) {
        let target = previousApplication
        previousApplication = nil
        hide()
        if let target, !target.isTerminated {
            target.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let service = SnippetExpansionService.shared
            if service.insertFromMenu(snippet) == .notTrusted {
                // Without Accessibility nothing can be typed: leave the text on the clipboard instead.
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(service.expand(snippet).text, forType: .string)
                _ = SystemPermissions.requestAccessibilityPermission()
                ToastHUDController.shared.show(
                    message: "Snippet copied. Grant Accessibility permission to insert it for you",
                    icon: "lock.shield"
                )
            }
        }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch Int(event.keyCode) {
            case 125: // down
                self.model.moveSelection(by: 1)
                return nil
            case 126: // up
                self.model.moveSelection(by: -1)
                return nil
            case 36, 76: // Return, Enter
                if let snippet = self.model.selected { self.insert(snippet) }
                return nil
            case 53: // Escape
                self.hide()
                return nil
            default:
                return event
            }
        }
    }

    private func uninstallKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
