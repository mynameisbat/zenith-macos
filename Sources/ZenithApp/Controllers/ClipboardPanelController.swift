import AppKit
import SwiftUI
import ZenithCore

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
        guard relevantModifiers == [.command] else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.keyCode {
        case KeyboardNavigationEngine.KeyCodes.keyQ:
            NSApp.terminate(nil)
            return true
        case KeyboardNavigationEngine.KeyCodes.keyW:
            ClipboardPanelController.shared.hide()
            return true
        case KeyboardNavigationEngine.KeyCodes.comma:
            ClipboardPanelController.shared.hide()
            SettingsWindowController.shared.configureDefaultContent()
            SettingsWindowController.shared.show()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Floating panel controller presenting the clipboard history as a Liquid Glass strip docked near the bottom of the screen.
@MainActor
public final class ClipboardPanelController: NSObject, NSWindowDelegate {
    public static let shared = ClipboardPanelController()

    // Dimensions: the strip asks for this much and is docked near the bottom of the screen the pointer is on.
    public static let defaultWidth: CGFloat = ClipboardHistoryView.panelSize.width
    public static let defaultHeight: CGFloat = ClipboardHistoryView.panelSize.height

    // Internal state
    private var panel: ClipboardPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var localKeyMonitor: Any?
    /// Turns a plain mouse wheel into sideways scrolling of the card row. Installed only while the panel shows.
    private var localScrollMonitor: Any?
    private var isAnimating: Bool = false
    private var currentViewModel: ClipboardHistoryViewModel?
    private var previousActiveApplication: NSRunningApplication?
    /// Bumped on every show: the view is rebuilt, so the search field takes focus and the row starts in order again.
    private var showGeneration = 0

    public var onDismiss: (() -> Void)?

    public override init() {
        super.init()
    }

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

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
            soundService: AudioFeedbackManager.shared
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

    /// A new root view for the same view model (see `showGeneration`).
    private func refreshRootView() {
        guard let viewModel = currentViewModel, let hosted = hostingView else { return }
        showGeneration += 1
        hosted.rootView = AnyView(
            ClipboardHistoryView(viewModel: viewModel) { [weak self] in self?.hide() }
                .id(showGeneration)
        )
    }

    // MARK: - Show / Hide / Toggle Actions

    public func show(store: ClipboardStore = .shared) {
        // Track the currently active application BEFORE Zenith steals key focus
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

        refreshRootView()

        // Docked near the bottom of the screen the pointer is on, above the Dock; it rises into place unless the
        // user asked for less motion.
        let targetFrame = PanelPositioner.dockedFrame(
            mouseLocation: NSEvent.mouseLocation,
            preferredSize: CGSize(width: Self.defaultWidth, height: Self.defaultHeight)
        )
        var startFrame = targetFrame
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startFrame.origin.y -= 14
        }

        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0.0

        // Install local key event monitor
        installKeyMonitor()
        installScrollMonitor()

        // Bring to front and become key
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Smooth fade-in
        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            panel.animator().setFrame(targetFrame, display: true)
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

    public func toggle(store: ClipboardStore = .shared) {
        if isVisible {
            hide()
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost = frontmost, frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousActiveApplication = frontmost
            }
            show(store: store)
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

    private func installScrollMonitor() {
        guard localScrollMonitor == nil else { return }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isVisible, self.scrollCardRow(with: event) else { return event }
            return nil
        }
    }

    /// Scrolls the card row for a vertical mouse-wheel event over it. False (event untouched) for anything else.
    private func scrollCardRow(with event: NSEvent) -> Bool {
        guard let panel = panel, event.window === panel, let root = panel.contentView,
              let change = ClipboardWheelScroll.offsetChange(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                hasPhase: event.phase != [] || event.momentumPhase != []
              ),
              let scrollView = Self.horizontalScrollView(in: root, at: event.locationInWindow),
              let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let x = ClipboardWheelScroll.clampedOffset(
            current: clip.bounds.origin.x, change: change,
            contentWidth: document.frame.width, visibleWidth: clip.bounds.width
        )
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// The scroll view under the pointer that has more content than room, sideways.
    private static func horizontalScrollView(in view: NSView, at windowPoint: NSPoint) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           scrollView.convert(scrollView.bounds, to: nil).contains(windowPoint),
           let document = scrollView.documentView, document.frame.width > scrollView.contentView.bounds.width {
            return scrollView
        }
        for subview in view.subviews {
            if let found = horizontalScrollView(in: subview, at: windowPoint) { return found }
        }
        return nil
    }

    private func uninstallScrollMonitor() {
        if let monitor = localScrollMonitor {
            NSEvent.removeMonitor(monitor)
            localScrollMonitor = nil
        }
    }

    private func uninstallKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        uninstallScrollMonitor()
    }
}
