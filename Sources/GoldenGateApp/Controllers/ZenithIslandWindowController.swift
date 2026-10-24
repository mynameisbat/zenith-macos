import AppKit
import SwiftUI
import Combine
import ObjectiveC
import GoldenGateCore

/// Specialized non-activating floating panel positioned at the top of the screen for Zenith Island.
public final class ZenithIslandPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isFloatingPanel = true
        self.level = .mainMenu + 1
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = true
        self.animationBehavior = .none
    }
}

/// Drag-and-drop & mouse tracking container hosting the SwiftUI ZenithDynamicIslandView.
public final class ZenithIslandHostingView: NSHostingView<ZenithDynamicIslandView> {
    private var trackingArea: NSTrackingArea?

    public required init(rootView: ZenithDynamicIslandView) {
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.layer?.masksToBounds = false
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.contentsGravity = .top
        self.layerContentsPlacement = .top
        registerForDraggedTypes([.fileURL, .string, .tiff, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static var hasConfiguredFrameHitTest = false

    public static func enableFrameHitTestPassthrough(for frameView: NSView) {
        guard !hasConfiguredFrameHitTest else { return }
        hasConfiguredFrameHitTest = true
        let cls: AnyClass = type(of: frameView)
        guard let origMethod = class_getInstanceMethod(cls, #selector(NSView.hitTest(_:))) else { return }
        typealias HitTestIMP = @convention(c) (NSView, Selector, NSPoint) -> NSView?
        let origIMP = method_getImplementation(origMethod)
        let typedOrig = unsafeBitCast(origIMP, to: HitTestIMP.self)
        let newBlock: @convention(block) (NSView, NSPoint) -> NSView? = { (targetView: NSView, point: NSPoint) in
            guard targetView.window is ZenithIslandPanel, let cv = targetView.window?.contentView else {
                return typedOrig(targetView, #selector(NSView.hitTest(_:)), point)
            }
            return cv.hitTest(point)
        }
        method_setImplementation(origMethod, imp_implementationWithBlock(newBlock))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview != nil ? convert(point, from: superview) : point
        // Clicks should NEVER be intercepted or swallowed when the island is idle or displaying a transient alert.
        // Transient alerts and idle indicators are purely visual HUDs and must pass 100% of mouse clicks
        // directly through to underlying applications (Safari tabs, Finder, window titlebars, etc.).
        // Only allow hit testing when the island is actively expanded, has no active alert, AND is hovered (or drop targeted),
        // and strictly within the visible bounds.
        guard ZenithIslandState.shared.isExpanded,
              ZenithIslandState.shared.activeAlert == nil,
              ZenithIslandState.shared.isHovered || ZenithIslandState.shared.isDropTargeted,
              bounds.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    private var idleHitRect: NSRect {
        let geom = ZenithIslandWindowController.shared.currentGeometry
        let idleW = geom.idleWidth
        let idleH = geom.hasNotch ? (geom.idleHeight + 6) : max(geom.idleHeight, 22)
        let x = (bounds.width - idleW) / 2
        let y = isFlipped ? 0 : (bounds.height - idleH)
        return NSRect(x: x, y: y, width: idleW, height: idleH)
    }

    private var alertHitRect: NSRect {
        let geom = ZenithIslandWindowController.shared.currentGeometry
        let alertW = geom.alertWidth
        let alertH = geom.effectiveAlertHeight
        let x = (bounds.width - alertW) / 2
        let y = isFlipped ? 0 : (bounds.height - alertH)
        return NSRect(x: x, y: y, width: alertW, height: alertH)
    }

    /// Hit target for cursor hover detection. Transient alerts must never expand the drop shelf on hover.
    private var currentHoverHitRect: NSRect {
        if ZenithIslandState.shared.isExpanded || ZenithIslandState.shared.isDropTargeted {
            return bounds
        } else {
            return idleHitRect
        }
    }

    /// Hit target for drag-and-drop operations, allowing files dragged onto the notch or alert capsule to stage.
    private var currentDragHitRect: NSRect {
        if ZenithIslandState.shared.isExpanded || ZenithIslandState.shared.isDropTargeted {
            return bounds
        } else if ZenithIslandState.shared.activeAlert != nil {
            return alertHitRect
        } else {
            return idleHitRect
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        checkHover(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        checkHover(with: event)
    }

    private func checkHover(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let activeRect = currentHoverHitRect
        if activeRect.contains(localPoint) {
            if !ZenithIslandState.shared.isHovered {
                ZenithIslandState.shared.onMouseEnter()
            }
        } else {
            if ZenithIslandState.shared.isHovered && !ZenithIslandState.shared.isDropTargeted && !ZenithIslandState.shared.isDraggingOut {
                ZenithIslandState.shared.onMouseLeave()
            }
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !ZenithIslandState.shared.isDropTargeted && !ZenithIslandState.shared.isDraggingOut {
            ZenithIslandState.shared.onMouseLeave()
        }
    }

    // MARK: - Drag and Drop Support (Drop Shelf)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let localPoint = convert(sender.draggingLocation, from: nil)
        let activeRect = currentDragHitRect
        guard activeRect.contains(localPoint) else { return [] }
        ZenithIslandState.shared.isDropTargeted = true
        ZenithIslandState.shared.onMouseEnter()
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let localPoint = convert(sender.draggingLocation, from: nil)
        let activeRect = currentDragHitRect
        if activeRect.contains(localPoint) {
            if !ZenithIslandState.shared.isDropTargeted {
                ZenithIslandState.shared.isDropTargeted = true
                ZenithIslandState.shared.onMouseEnter()
            }
            return .copy
        } else {
            if ZenithIslandState.shared.isDropTargeted {
                ZenithIslandState.shared.isDropTargeted = false
                ZenithIslandState.shared.onMouseLeave()
            }
            return []
        }
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        ZenithIslandState.shared.isDropTargeted = false
        ZenithIslandState.shared.onMouseLeave()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ZenithIslandState.shared.isDropTargeted = false
        let pasteboard = sender.draggingPasteboard

        var addedCount = 0

        // 1. Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls {
                ZenithIslandState.shared.addItem(
                    name: url.lastPathComponent,
                    fileURL: url
                )
                addedCount += 1
            }
        }
        // 2. Check for plain strings/links
        else if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = string.count > 30 ? String(string.prefix(27)) + "..." : string
            ZenithIslandState.shared.addItem(
                name: preview,
                textContent: string
            )
            addedCount += 1
        }

        if addedCount > 0 {
            ToastHUDController.shared.show(
                message: "Added to Drop Shelf (\(addedCount))",
                icon: "tray.and.arrow.down.fill"
            )
            return true
        }

        return false
    }
}

/// Orchestrates the Zenith Dynamic Island lifecycle, frame updates, and screen changes.
@MainActor
public final class ZenithIslandWindowController: NSObject {
    public static let shared = ZenithIslandWindowController()

    public enum DisplayMode: Equatable {
        case idle
        case alert
        case expanded
    }

    private var panel: ZenithIslandPanel?
    private(set) public var geometry: ZenithIslandGeometry
    public var currentGeometry: ZenithIslandGeometry { geometry }
    private(set) public var currentMode: DisplayMode = .idle

    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    override private init() {
        self.geometry = ZenithIslandGeometry()
        super.init()
    }

    /// Sets up and displays the Dynamic Island panel at the top edge of the primary display.
    public func setup() {
        guard panel == nil else { return }

        self.geometry = ZenithIslandGeometry()
        let initialFrame = geometry.expandedFrame

        let islandPanel = ZenithIslandPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let islandView = ZenithDynamicIslandView(geometry: geometry)

        let hosted = ZenithIslandHostingView(rootView: islandView)
        hosted.autoresizingMask = [.width, .height]
        islandPanel.contentView = hosted
        islandPanel.setFrame(initialFrame, display: false)
        islandPanel.orderFrontRegardless()

        if let frameView = islandPanel.contentView?.superview {
            ZenithIslandHostingView.enableFrameHitTestPassthrough(for: frameView)
        }

        self.panel = islandPanel
        self.currentMode = .idle

        // Observe island state expansion, alerts, and drop shelf interactions
        Publishers.CombineLatest3(
            ZenithIslandState.shared.$isExpanded,
            ZenithIslandState.shared.$activeAlert,
            ZenithIslandState.shared.$isDropTargeted
        )
        .removeDuplicates { prev, curr in
            prev.0 == curr.0 && prev.1 == curr.1 && prev.2 == curr.2
        }
        .sink { [weak self] isExpanded, activeAlert, isDropTargeted in
            self?.handleStateChange(
                isExpanded: isExpanded,
                hasActiveAlert: activeAlert != nil,
                isDropTargeted: isDropTargeted
            )
        }
        .store(in: &cancellables)

        // Observe screen configuration changes (e.g., monitor plug/unplug, resolution change)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // System-wide mouse movement monitors:
        // Automatically make the window completely transparent to mouse clicks (ignoresMouseEvents = true)
        // whenever the cursor is outside the visible island. This completely eliminates any dead zones,
        // allowing 100% of mouse clicks to pass directly through to nearby menu bar icons and windows underneath.
        self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
            }
        }

        self.localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved(screenPoint: NSEvent.mouseLocation)
            return event
        }

        handleMouseMoved(screenPoint: NSEvent.mouseLocation)
    }

    /// Evaluates cursor position to toggle mouse click passthrough.
    public func handleMouseMoved(screenPoint: NSPoint) {
        guard let panel = panel else { return }
        let state = ZenithIslandState.shared

        // Determine current interactive bounds in screen coordinates
        let activeScreenRect: CGRect
        if state.isExpanded || state.isDropTargeted {
            activeScreenRect = geometry.expandedFrame
        } else if state.activeAlert != nil {
            activeScreenRect = geometry.alertFrame
        } else {
            activeScreenRect = geometry.idleFrame
        }

        let isInside = activeScreenRect.contains(screenPoint)

        if isInside {
            // Inside active island area: enable mouse interaction
            if panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = false
            }
            if !state.isHovered && !state.isDraggingOut {
                state.onMouseEnter()
            }
        } else {
            // Outside: immediately pass 100% of clicks through to menubar icons & underlying windows
            if !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
            if state.isHovered && !state.isDropTargeted && !state.isDraggingOut {
                state.onMouseLeave()
            }
        }
    }

    private func handleStateChange(isExpanded: Bool, hasActiveAlert: Bool, isDropTargeted: Bool) {
        let targetMode: DisplayMode
        if hasActiveAlert {
            targetMode = .alert
        } else if isExpanded || isDropTargeted {
            targetMode = .expanded
        } else {
            targetMode = .idle
        }

        updateDisplayMode(to: targetMode)
    }

    public func frame(for mode: DisplayMode) -> CGRect {
        switch mode {
        case .idle:
            return geometry.idleFrame
        case .alert:
            return geometry.alertFrame
        case .expanded:
            return geometry.expandedFrame
        }
    }

    private func updateDisplayMode(to newMode: DisplayMode) {
        guard let panel = panel else { return }

        collapseTask?.cancel()
        collapseTask = nil
        currentMode = newMode

        // Ensure canvas frame is permanently centered symmetrically around geom.notchRect.midX.
        // Maintaining a stable canvas frame prevents window origin jumps that cause left-skewed distortion on hover.
        let targetFrame = geometry.expandedFrame
        if !panel.frame.equalTo(targetFrame) {
            panel.setFrame(targetFrame, display: false)
        }
        if newMode == .idle {
            let mouseLoc = NSEvent.mouseLocation
            if !geometry.idleFrame.contains(mouseLoc) {
                panel.ignoresMouseEvents = true
            }
        }
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        self.geometry = ZenithIslandGeometry()
        if let panel = panel {
            let targetFrame = geometry.expandedFrame
            panel.setFrame(targetFrame, display: false)
            if let hosted = panel.contentView as? ZenithIslandHostingView {
                hosted.rootView = ZenithDynamicIslandView(geometry: self.geometry)
            }
        }
    }

    /// Teardown dynamic island panel when quitting.
    public func teardown() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        collapseTask?.cancel()
        collapseTask = nil
        cancellables.removeAll()
        panel?.close()
        panel = nil
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
