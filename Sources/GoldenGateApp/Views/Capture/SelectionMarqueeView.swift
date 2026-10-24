import AppKit
import SwiftUI
import GoldenGateCore

/// Fullscreen transparent overlay panel at `.screenSaver` level.
public final class CaptureOverlayPanel: NSPanel {
    public init(contentRect: NSRect, screen: NSScreen? = nil) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        if screen != nil {
            self.setFrame(contentRect, display: false)
        }

        self.level = .screenSaver
        self.isFloatingPanel = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false

        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    override public func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            CaptureOverlayController.shared.cancelCapture()
            return
        }
        if event.modifierFlags.contains(.command) && (event.keyCode == 12 || event.charactersIgnoringModifiers?.lowercased() == "q") {
            CaptureOverlayController.shared.cancelCapture()
            NSApp.terminate(nil)
            return
        }
        if event.modifierFlags.contains(.command) && (event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w") {
            CaptureOverlayController.shared.cancelCapture()
            return
        }
        super.keyDown(with: event)
    }
}

/// Custom AppKit view performing 40% dimming, inverted cutout, marquee stroke, dimension badge, and loupe.
public final class SelectionMarqueeView: NSView {
    public var currentSelectionRect: CGRect? {
        didSet {
            updateBadge()
            needsDisplay = true
        }
    }

    public var cursorLocation: CGPoint? {
        didSet {
            updateLoupePosition()
        }
    }

    public var loupeData: (grid: [[PixelColor]], centerColor: PixelColor, zoom: LoupeZoomFactor)? {
        didSet {
            updateLoupeContent()
        }
    }

    private var badgeHostingView: NSHostingView<DimensionBadgeView>?
    private var loupeHostingView: NSHostingView<LoupeMagnifierView>?
    private let badgeSize = CGSize(width: 220, height: 28)
    private let loupeSize = CGSize(width: 140, height: 170)

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override public var isFlipped: Bool {
        false // Standard AppKit Cartesian coordinates (bottom-left origin)
    }

    // MARK: - Drawing (Dimming Mask & Clear Cutout)

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw 40% black dimming mask over entire view
        NSColor.black.withAlphaComponent(0.40).setFill()
        bounds.fill()

        // 2. Punch transparent cutout if there is an active selection intersecting this screen
        guard let globalRect = currentSelectionRect else { return }
        let screenFrame = window?.screen?.frame ?? bounds

        guard let intersected = MarqueeGeometry.intersectScreen(rect: globalRect, screenFrame: screenFrame) else {
            return
        }

        let localRect = MarqueeGeometry.toLocalCoordinates(globalRect: intersected, screenOrigin: screenFrame.origin)

        // Clear selection area (100% transparent cutout)
        context.saveGState()
        context.clear(localRect)
        context.restoreGState()

        // 3. Stroke crisp 1.5pt white border
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(localRect)

        // 4. Draw 4 corner handles
        let handleSize: CGFloat = 6.0
        let half = handleSize / 2.0
        let corners = [
            CGPoint(x: localRect.minX, y: localRect.minY),
            CGPoint(x: localRect.maxX, y: localRect.minY),
            CGPoint(x: localRect.minX, y: localRect.maxY),
            CGPoint(x: localRect.maxX, y: localRect.maxY)
        ]

        context.setFillColor(NSColor.white.cgColor)
        for corner in corners {
            let handleRect = CGRect(x: corner.x - half, y: corner.y - half, width: handleSize, height: handleSize)
            let path = CGPath(roundedRect: handleRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }

    // MARK: - Dimension Badge Management

    private func updateBadge() {
        guard let globalRect = currentSelectionRect else {
            badgeHostingView?.removeFromSuperview()
            badgeHostingView = nil
            return
        }

        let screenFrame = window?.screen?.frame ?? bounds
        guard let intersected = MarqueeGeometry.intersectScreen(rect: globalRect, screenFrame: screenFrame),
              intersected.width >= 4, intersected.height >= 4 else {
            badgeHostingView?.removeFromSuperview()
            badgeHostingView = nil
            return
        }

        let localRect = MarqueeGeometry.toLocalCoordinates(globalRect: intersected, screenOrigin: screenFrame.origin)
        let scale = window?.screen?.backingScaleFactor ?? 2.0
        let (pts, pxs, _) = MarqueeGeometry.formatDimensionText(rect: intersected, scaleFactor: scale)

        let badgeView = DimensionBadgeView(pointsText: pts, pixelsText: pxs)
        if badgeHostingView == nil {
            let hosting = NSHostingView(rootView: badgeView)
            addSubview(hosting)
            badgeHostingView = hosting
        } else {
            badgeHostingView?.rootView = badgeView
        }

        let pos = MarqueeGeometry.calculateBadgePosition(
            selectionRect: localRect,
            badgeSize: badgeSize,
            screenBounds: bounds
        )
        badgeHostingView?.frame = CGRect(origin: pos, size: badgeSize)
    }

    // MARK: - Loupe Management

    private func updateLoupeContent() {
        autoreleasepool {
            guard let data = loupeData else {
                loupeHostingView?.removeFromSuperview()
                loupeHostingView = nil
                return
            }

            let magnifier = LoupeMagnifierView(
                grid: data.grid,
                centerColor: data.centerColor,
                zoomFactor: data.zoom
            )

            if loupeHostingView == nil {
                let hosting = NSHostingView(rootView: magnifier)
                addSubview(hosting)
                loupeHostingView = hosting
            } else {
                loupeHostingView?.rootView = magnifier
            }
            updateLoupePosition()
        }
    }

    private func updateLoupePosition() {
        guard let cursor = cursorLocation, loupeHostingView != nil else { return }
        let screenFrame = window?.screen?.frame ?? bounds

        guard screenFrame.contains(cursor) else {
            loupeHostingView?.isHidden = true
            return
        }
        loupeHostingView?.isHidden = false

        let localX = cursor.x - screenFrame.origin.x
        let localY = cursor.y - screenFrame.origin.y

        // Offset loupe to bottom-right of cursor by default
        var loupeX = localX + 20
        var loupeY = localY - loupeSize.height - 20

        // Flip to left if overflowing right edge
        if loupeX + loupeSize.width > bounds.maxX - 10 {
            loupeX = localX - loupeSize.width - 20
        }
        // Flip to top if overflowing bottom edge
        if loupeY < bounds.minY + 10 {
            loupeY = localY + 20
        }

        loupeHostingView?.frame = CGRect(
            x: max(10, min(loupeX, bounds.maxX - loupeSize.width - 10)),
            y: max(10, min(loupeY, bounds.maxY - loupeSize.height - 10)),
            width: loupeSize.width,
            height: loupeSize.height
        )
    }

    // MARK: - Mouse Event Handling

    override public func mouseDown(with event: NSEvent) {
        CaptureOverlayController.shared.handleMouseDown(event: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        CaptureOverlayController.shared.handleMouseDragged(event: event)
    }

    override public func mouseUp(with event: NSEvent) {
        CaptureOverlayController.shared.handleMouseUp(event: event)
    }

    override public func mouseMoved(with event: NSEvent) {
        CaptureOverlayController.shared.handleMouseMoved(event: event)
    }

    override public func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            CaptureOverlayController.shared.cancelCapture()
            return
        }
        super.keyDown(with: event)
    }
}
