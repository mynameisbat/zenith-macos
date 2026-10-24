import AppKit
import SwiftUI
import GoldenGateCore

/// Dedicated floating panel subclass tailored for auxiliary zero-stealing clipboard inspection.
final class ClipboardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .borderless,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        // Window level and floating behavior
        self.isFloatingPanel = true
        self.level = .floating

        // Multi-Space and Fullscreen compatibility
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        // Appearance & Transparency
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
    }

    /// Overridden to allow borderless panel to become key window for keyboard events and text entry.
    override var canBecomeKey: Bool {
        return true
    }

    /// Panels must NOT become main window to preserve underlying document's main state.
    override var canBecomeMain: Bool {
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
        if relevantModifiers == [.command] && (event.keyCode == 12 || event.charactersIgnoringModifiers?.lowercased() == "q") { // ⌘Q
            NSApp.terminate(nil)
            return true
        }
        if relevantModifiers == [.command] && (event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w") { // ⌘W
            ClipboardPanelController.shared.hide()
            return true
        }
        if relevantModifiers == [.command] && (event.keyCode == 43 || event.charactersIgnoringModifiers == ",") { // ⌘,
            ClipboardPanelController.shared.hide()
            SettingsWindowController.shared.configureDefaultContent()
            SettingsWindowController.shared.show()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Floating panel controller presenting clipboard history with frosted glass aesthetics.
@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate {
    public static let shared = ClipboardPanelController()

    // Dimensions
    public static let defaultWidth: CGFloat = 420
    public static let defaultHeight: CGFloat = 520
    public static let margin: CGFloat = 12

    // Internal state
    private var panel: ClipboardPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localKeyMonitor: Any?
    private var isAnimating: Bool = false
    private var currentViewModel: ClipboardHistoryViewModel?
    private var previousActiveApplication: NSRunningApplication?

    public var onDismiss: (() -> Void)?

    public override init() {
        super.init()
    }

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    public typealias PositioningMode = PanelPositioner.PositioningMode

    // MARK: - Setup & Configuration

    public func configure<Content: View>(rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight)
        let newPanel = ClipboardPanel(contentRect: initialRect)
        newPanel.delegate = self

        let hosted = NSHostingView(rootView: AnyView(rootView))
        hosted.autoresizingMask = [.width, .height]
        newPanel.contentView = hosted

        self.panel = newPanel
        self.hostingView = hosted
    }

    public func configureWithStore(_ store: ClipboardStore = .shared) {
        let viewModel = ClipboardHistoryViewModel(
            store: store,
            pasteboardService: PasteboardMonitor.shared,
            soundService: nil
        )
        self.currentViewModel = viewModel
        KeyboardNavigationEngine.shared.activeViewModel = viewModel

        viewModel.onActionCompleted = { [weak self] in
            self?.hideAndPaste()
        }
        viewModel.onDismiss = { [weak self] in
            self?.hide()
        }
        KeyboardNavigationEngine.shared.dismissHandler = { [weak self] in
            self?.hide()
        }

        let rootView = ClipboardHistoryView(viewModel: viewModel) { [weak self] in
            self?.hide()
        }
        configure(rootView: rootView)
    }

    // MARK: - Show / Hide / Toggle Actions

    public func show(positioningMode: PositioningMode = .nearMouse, store: ClipboardStore = .shared) {
        // Track the currently active application BEFORE GoldenGate steals key focus
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost = frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.previousActiveApplication = frontmost
        }

        if panel == nil {
            configureWithStore(store)
        } else if let vm = currentViewModel {
            if vm.store !== store {
                vm.attachStore(store)
            } else {
                vm.syncWithStore()
            }
        }

        guard let panel = panel else { return }
        guard !isAnimating else { return }

        // Compute positioning geometry
        let targetFrame = PanelPositioner.calculateFrame(
            mouseLocation: NSEvent.mouseLocation,
            panelSize: CGSize(width: Self.defaultWidth, height: Self.defaultHeight),
            mode: positioningMode
        )

        panel.setFrame(targetFrame, display: true)
        panel.alphaValue = 0.0

        // Install local key event monitor
        installKeyMonitor()

        // Bring to front and become key
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Smooth fade-in
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isAnimating = false
            }
        }
    }

    public func hide() {
        guard let panel = panel, panel.isVisible else { return }
        guard !isAnimating else { return }

        uninstallKeyMonitor()
        isAnimating = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self?.isAnimating = false
                self?.onDismiss?()
            }
        }
    }

    /// Hides the clipboard panel, reactivates the previous application, and automatically synthesizes a Command+V paste keystroke.
    public func hideAndPaste() {
        let targetApp = previousActiveApplication
        self.previousActiveApplication = nil

        uninstallKeyMonitor()
        if let panel = panel, panel.isVisible {
            panel.orderOut(nil)
            isAnimating = false
            onDismiss?()
        }

        // 1. Reactivate the application where the cursor was located
        if let targetApp = targetApp, !targetApp.isTerminated {
            targetApp.activate()
        }

        // 2. Schedule synthetic paste keystroke after focus transfers back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if SystemPermissions.checkAccessibilityPermission() {
                AutoPasteService.simulatePasteKeystroke()
            } else {
                _ = SystemPermissions.requestAccessibilityPermission()
                ToastHUDController.shared.show(
                    message: "Copied! Grant Accessibility permission to auto-paste",
                    icon: "lock.shield"
                )
            }
        }
    }

    public func toggle(positioningMode: PositioningMode = .nearMouse, store: ClipboardStore = .shared) {
        if isVisible {
            hide()
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost = frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousActiveApplication = frontmost
            }
            show(positioningMode: positioningMode, store: store)
        }
    }

    /// Convenience alias for toggling panel visibility with default parameters.
    public func togglePanel() {
        toggle()
    }

    // MARK: - NSWindowDelegate (Auto-Dismissal)

    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Key Event Monitor

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            if KeyboardNavigationEngine.shared.handleKeyEvent(event) {
                return nil // Event consumed! Suppress beep and propagation
            }
            return event
        }
    }

    private func uninstallKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}
