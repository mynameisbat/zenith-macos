import AppKit
import GoldenGateCore

/// Main orchestrator managing full-screen capture overlays, marquee drag interaction, and loupe magnifier.
@MainActor
public final class CaptureOverlayController: NSObject {
    public static let shared = CaptureOverlayController()

    // Injected Services
    private let screenCaptureService: ScreenCaptureServiceProtocol
    private let soundService: SoundServiceProtocol?

    // UI Elements
    private var overlayPanels: [CaptureOverlayPanel] = []
    private var overlayViews: [SelectionMarqueeView] = []
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var isCrosshairCursorPushed: Bool = false

    // State
    private let marqueeEngine = MarqueeSelectionEngine()
    private var activeCompletion: ((CGImage?) -> Void)?
    private var cachedScreenImages: [CGDirectDisplayID: CGImage] = [:]
    private var cachedScreenImage: CGImage? {
        get { cachedScreenImages[CGMainDisplayID()] ?? cachedScreenImages.values.first }
        set {
            if let val = newValue {
                cachedScreenImages[CGMainDisplayID()] = val
            } else {
                cachedScreenImages.removeAll()
            }
        }
    }
    private var currentZoomFactor: LoupeZoomFactor = .zoom4x

    public var currentState: MarqueeState {
        marqueeEngine.state
    }

    public var isOverlayActive: Bool {
        !overlayPanels.isEmpty && currentState != .dismissed
    }

    public init(
        screenCaptureService: ScreenCaptureServiceProtocol = ScreenCaptureManager.live,
        soundService: SoundServiceProtocol? = AudioFeedbackManager.shared
    ) {
        self.screenCaptureService = screenCaptureService
        self.soundService = soundService
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Public Entry Points

    /// Starts interactive area capture overlay across all screens.
    public func startAreaCapture(completion: ((CGImage?) -> Void)? = nil) {
        guard !isOverlayActive else {
            completion?(nil)
            return
        }

        // Screen recording permission pre-check
        guard screenCaptureService.hasScreenRecordingPermission else {
            _ = SystemPermissions.requestScreenRecordingPermission()
            ToastHUDController.shared.show(message: "Permission Required: Screen Recording", icon: "lock.shield")
            completion?(nil)
            return
        }

        self.activeCompletion = completion
        marqueeEngine.reset()

        // Cache full-screen image for instantaneous loupe sampling across all screens (HIGH-20)
        refreshCachedScreenImages()

        buildOverlayPanels()
        installMonitors()
        if !isCrosshairCursorPushed {
            NSCursor.crosshair.push()
            isCrosshairCursorPushed = true
        }

        for panel in overlayPanels {
            panel.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)

        // Focus the panel under current cursor
        let mouseLoc = NSEvent.mouseLocation
        if let targetPanel = overlayPanels.first(where: { $0.frame.contains(mouseLoc) }) {
            targetPanel.makeKey()
        }
    }

    /// Captures the full main display immediately without opening overlay.
    public func captureFullscreen(completion: ((CGImage?) -> Void)? = nil) {
        guard screenCaptureService.hasScreenRecordingPermission else {
            _ = SystemPermissions.requestScreenRecordingPermission()
            ToastHUDController.shared.show(message: "Permission Required: Screen Recording", icon: "lock.shield")
            completion?(nil)
            return
        }

        Task {
            do {
                let image = try await screenCaptureService.captureMainDisplay()
                soundService?.playShutterSound()
                await MainActor.run {
                    completion?(image)
                }
            } catch {
                NSLog("[GoldenGateApp] Fullscreen capture error: \(error)")
                await MainActor.run {
                    completion?(nil)
                }
            }
        }
    }

    /// Immediately dismisses the overlay without capturing or playing sound.
    public func cancelCapture() {
        marqueeEngine.handleEscapeKey()
        teardownOverlays()
        let completion = activeCompletion
        activeCompletion = nil
        completion?(nil)
    }

    // MARK: - Panel Hierarchy Setup & Teardown

    private func buildOverlayPanels() {
        teardownOverlays()

        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let panel = CaptureOverlayPanel(contentRect: screen.frame, screen: screen)
            panel.setFrame(screen.frame, display: true)

            let marqueeView = SelectionMarqueeView(frame: NSRect(origin: .zero, size: screen.frame.size))
            marqueeView.autoresizingMask = [.width, .height]
            panel.contentView = marqueeView

            overlayPanels.append(panel)
            overlayViews.append(marqueeView)
        }
    }

    private func teardownOverlays() {
        removeMonitors()
        if isCrosshairCursorPushed {
            NSCursor.pop()
            isCrosshairCursorPushed = false
        }

        for panel in overlayPanels {
            panel.orderOut(nil)
            panel.close()
        }
        overlayPanels.removeAll()
        overlayViews.removeAll()
        cachedScreenImage = nil
    }

    private func installMonitors() {
        removeMonitors()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // Escape
                self.cancelCapture()
                return nil
            }
            if event.charactersIgnoringModifiers == "z" || event.charactersIgnoringModifiers == "Z" {
                // Toggle loupe zoom between 4x and 8x
                self.currentZoomFactor = (self.currentZoomFactor == .zoom4x) ? .zoom8x : .zoom4x
                self.updateLoupeData(cursor: NSEvent.mouseLocation)
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    @objc private func handleScreenParametersChanged() {
        if isOverlayActive {
            buildOverlayPanels()
            for panel in overlayPanels {
                panel.orderFrontRegardless()
            }
            refreshCachedScreenImages()
        }
    }

    // MARK: - Event Dispatch from Overlay Views

    public func handleMouseDown(event: NSEvent) {
        let globalLocation = NSEvent.mouseLocation
        marqueeEngine.beginDrag(at: globalLocation)
        broadcastSelectionRect(marqueeEngine.normalizedRect)
    }

    public func handleMouseDragged(event: NSEvent) {
        let globalLocation = NSEvent.mouseLocation
        marqueeEngine.updateDrag(to: globalLocation)
        broadcastSelectionRect(marqueeEngine.normalizedRect)
        broadcastCursorLocation(globalLocation)
        updateLoupeData(cursor: globalLocation)
    }

    public func handleMouseUp(event: NSEvent) {
        guard let finalRect = marqueeEngine.endDrag(minimumDimension: 4.0) else {
            // Drag was smaller than threshold; reset to idle
            broadcastSelectionRect(nil)
            return
        }

        // CRITICAL: Synchronously order out overlays BEFORE capture so overlay artifacts are never captured!
        for panel in overlayPanels {
            panel.orderOut(nil)
        }

        let completion = activeCompletion
        self.activeCompletion = nil
        teardownOverlays()

        Task {
            do {
                // 1. Identify target screen containing the selection
                let centerPoint = CGPoint(x: finalRect.midX, y: finalRect.midY)
                let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(centerPoint) })
                    ?? NSScreen.screens.first(where: { $0.frame.intersects(finalRect) })
                    ?? NSScreen.main
                    ?? NSScreen.screens.first

                // 2. Resolve display ID
                let displayID = resolveDisplayID(for: targetScreen)

                // 3. Determine primary display height and translate to display-local CoreGraphics coordinates
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
                let targetFrame = targetScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: primaryHeight)
                let localCGRect = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
                    rect: finalRect,
                    displayFrame: targetFrame,
                    primaryScreenHeight: primaryHeight
                )

                let captured = try await screenCaptureService.captureDisplayRegion(
                    localCGRect,
                    displayID: displayID
                )
                soundService?.playShutterSound()
                await MainActor.run {
                    completion?(captured)
                }
            } catch {
                NSLog("[GoldenGateApp] Area capture failed: \(error)")
                await MainActor.run {
                    completion?(nil)
                }
            }
        }
    }

    public func handleMouseMoved(event: NSEvent) {
        let globalLocation = NSEvent.mouseLocation
        broadcastCursorLocation(globalLocation)
        updateLoupeData(cursor: globalLocation)
    }

    // MARK: - Broadcast Helpers

    private func broadcastSelectionRect(_ rect: CGRect?) {
        for view in overlayViews {
            view.currentSelectionRect = rect
        }
    }

    private func broadcastCursorLocation(_ location: CGPoint) {
        for view in overlayViews {
            view.cursorLocation = location
        }
    }

    private func updateLoupeData(cursor: CGPoint) {
        autoreleasepool {
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
            guard let screen = targetScreen else { return }
            let displayID = resolveDisplayID(for: screen)

            guard let image = cachedScreenImages[displayID] ?? cachedScreenImages[CGMainDisplayID()] ?? cachedScreenImages.values.first else {
                return
            }

            let screenFrame = screen.frame
            let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : (CGFloat(image.width) / max(1, screenFrame.width))

            let pixelPoint = CoordinateTranslationService.cursorToPhysicalPixels(
                cursor: cursor,
                screenFrame: screenFrame,
                scale: scale
            )

            let grid = LoupePixelSampler.sampleGrid(in: image, center: pixelPoint, zoomFactor: currentZoomFactor)
            let half = currentZoomFactor.sourceGridDimension / 2
            let centerColor = (grid.indices.contains(half) && grid[half].indices.contains(half)) ? grid[half][half] : LoupePixelSampler.samplePixel(in: image, at: pixelPoint)

            for view in overlayViews {
                view.loupeData = (grid: grid, centerColor: centerColor, zoom: currentZoomFactor)
            }
        }
    }

    private func refreshCachedScreenImages() {
        Task {
            let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
            for screen in screens {
                let did = self.resolveDisplayID(for: screen)
                do {
                    let img = try await self.screenCaptureService.captureDisplay(displayID: did)
                    if self.isOverlayActive {
                        self.cachedScreenImages[did] = img
                    }
                } catch {
                    // Fallback to main display if per-display capture fails
                }
            }
            if self.cachedScreenImages.isEmpty {
                if let mainImg = try? await self.screenCaptureService.captureMainDisplay(), self.isOverlayActive {
                    self.cachedScreenImages[CGMainDisplayID()] = mainImg
                }
            }
        }
    }

    private func resolveDisplayID(for screen: NSScreen?) -> CGDirectDisplayID {
        guard let screen = screen else { return CGMainDisplayID() }
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(screenNumber.uint32Value)
        }
        return CGMainDisplayID()
    }
}
