import AppKit
import SwiftUI
import ZenithCore

/// Runs a screen recording from the shortcut or the menu: choose what to record, set the options, count down,
/// record with a stop button in the menu bar, then show the file with Trim and Export as GIF.
@MainActor
final class ScreenRecordingCoordinator {
    static let shared = ScreenRecordingCoordinator()

    private let recorder: ScreenRecorder
    private let settings: ScreenRecordingSettings
    private let stopItem = RecordingStopStatusItem()
    private let clickRings = ClickHighlightOverlay()
    private var optionsPanel: NSPanel?
    private var countdownPanel: NSPanel?
    private var outlinePanel: NSPanel?
    private var countdownScreen: NSScreen?
    private var countdownCenter: CGPoint?

    init(recorder: ScreenRecorder = .shared, settings: ScreenRecordingSettings = .shared) {
        self.recorder = recorder
        self.settings = settings
        recorder.onStateChange = { [weak self] state in self?.handle(state) }
        stopItem.onStop = { [weak self] in self?.stop() }
    }

    var isActive: Bool { recorder.state.isBusy || optionsPanel != nil }

    /// The shortcut and the menu item: start choosing, or stop the recording that is running.
    func toggle() {
        if recorder.state.isBusy {
            stop()
        } else if optionsPanel != nil {
            closeOptions()
        } else {
            begin()
        }
    }

    func begin() {
        guard !isActive else { return }
        CaptureOverlayController.shared.startSelection(purpose: .recording) { [weak self] selection in
            guard let self, let selection else { return }
            self.showOptions(for: selection)
        }
    }

    func stop() {
        Task { await recorder.stop() }
    }

    // MARK: - Options

    private func showOptions(for selection: CaptureSelection) {
        closeOptions()
        let bar = RecordingOptionsBar(
            settings: settings,
            onRecord: { [weak self] in self?.record(selection) },
            onCancel: { [weak self] in self?.closeOptions() }
        )
        let host = NSHostingView(rootView: bar)
        let size = host.fittingSize
        let panel = RecordingKeyPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameOrigin(Self.optionsOrigin(for: selection, size: size))
        if case .region(let rect, _) = selection {
            showOutline(around: rect)
        }
        optionsPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeOptions() {
        optionsPanel?.orderOut(nil)
        optionsPanel?.close()
        optionsPanel = nil
        if !recorder.state.isBusy { hideOutline() }
    }

    /// Below the area when there is room, else above it, else inside the bottom of the screen.
    private static func optionsOrigin(for selection: CaptureSelection, size: CGSize) -> CGPoint {
        let screen: NSScreen
        let area: CGRect
        switch selection {
        case .region(let rect, let s):
            screen = s
            area = rect
        case .window(let info, let s):
            screen = s
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            area = CGRect(x: info.bounds.minX, y: primaryHeight - info.bounds.maxY, width: info.bounds.width, height: info.bounds.height)
        case .display(let s):
            screen = s
            area = s.visibleFrame
        }
        let visible = screen.visibleFrame
        var x = area.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = area.minY - size.height - 14
        if y < visible.minY + 8 {
            y = area.maxY + 14
            if y + size.height > visible.maxY - 8 {
                y = visible.minY + 40
            }
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Recording

    private func record(_ selection: CaptureSelection) {
        closeOptions()
        if case .region(let rect, _) = selection { showOutline(around: rect) }
        let screen: NSScreen
        switch selection {
        case .region(_, let s), .window(_, let s), .display(let s): screen = s
        }
        countdownScreen = screen
        if case .region(let rect, _) = selection {
            countdownCenter = CGPoint(x: rect.midX, y: rect.midY)
        } else {
            countdownCenter = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        let settings = self.settings
        Task {
            await recorder.start(
                countdown: settings.countdown ? 3 : 0,
                systemAudio: settings.systemAudio,
                microphone: settings.microphone
            ) { plan in
                self.makeRequest(for: selection, audio: plan)
            }
            if let notice = recorder.audioNotice, recorder.state.isRecording {
                ToastHUDController.shared.show(verbatim: notice.message, icon: "mic.slash.fill")
            }
        }
    }

    private func makeRequest(for selection: CaptureSelection, audio: RecordingAudioPlan) -> RecordingRequest? {
        let folder = settings.saveFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            ToastHUDController.shared.show(verbatim: String(localized: "Zenith cannot save recordings in that folder."), icon: "exclamationmark.triangle.fill", subtitle: error.localizedDescription)
            return nil
        }
        let url = RecordingFileNamer.uniqueURL(in: folder, fileName: RecordingFileNamer.fileName(date: Date(), format: settings.format))

        let target: RecordingTarget
        let pointSize: CGSize
        let screen: NSScreen
        switch selection {
        case .region(let rect, let s):
            screen = s
            let primaryHeight = NSScreen.screens.first?.frame.height ?? s.frame.height
            let local = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(
                rect: rect.integral, displayFrame: s.frame, primaryScreenHeight: primaryHeight
            )
            target = .region(displayID: Self.displayID(of: s), rect: local)
            pointSize = local.size
        case .window(let info, let s):
            screen = s
            target = .window(windowID: info.windowID)
            pointSize = info.bounds.size
        case .display(let s):
            screen = s
            target = .display(displayID: Self.displayID(of: s))
            pointSize = s.frame.size
        }

        var included: [CGWindowID] = []
        if settings.highlightsClicks, case .window = target {
            // Window recordings use macOS 15's own click marks (the rings are separate windows).
        } else if settings.highlightsClicks {
            included = clickRings.show(on: [screen])
        }

        return RecordingRequest(
            target: target,
            frameRate: settings.frameRate,
            codec: settings.codec,
            format: settings.format,
            showsCursor: settings.showsCursor,
            highlightsClicks: settings.highlightsClicks,
            audio: audio,
            outputURL: url,
            pixelScale: screen.backingScaleFactor,
            pointSize: pointSize,
            includedOwnWindowIDs: included
        )
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }

    // MARK: - State

    private func handle(_ state: ScreenRecorderState) {
        switch state {
        case .countingDown(let n):
            showCountdown(n)
        case .preparing:
            hideCountdown()
        case .recording(let startedAt):
            hideCountdown()
            stopItem.show(startedAt: startedAt)
        case .stopping:
            stopItem.showSaving()
        case .finished(let result):
            tearDown()
            ToastHUDController.shared.show(message: "Recording Saved", icon: "record.circle")
            RecordingResultWindowController.shared.present(result, gifOptions: settings.gifOptions)
            recorder.acknowledgeResult()
        case .failed(let message):
            tearDown()
            ToastHUDController.shared.show(verbatim: String(localized: "Recording failed"), icon: "exclamationmark.triangle.fill", subtitle: message)
            recorder.acknowledgeResult()
        case .idle:
            tearDown()
        }
    }

    private func tearDown() {
        hideCountdown()
        hideOutline()
        clickRings.hide()
        stopItem.hide()
    }

    private func showCountdown(_ number: Int) {
        let host = NSHostingView(rootView: RecordingCountdownView(number: number))
        let size = CGSize(width: 150, height: 150)
        if countdownPanel == nil {
            let center = countdownCenter ?? CGPoint(x: (NSScreen.main?.frame.midX ?? 0), y: (NSScreen.main?.frame.midY ?? 0))
            let panel = makeOverlayPanel(frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            countdownPanel = panel
        }
        countdownPanel?.contentView = host
        countdownPanel?.orderFrontRegardless()
        AccessibilityAnnouncer.announce(String(number))
    }

    private func hideCountdown() {
        countdownPanel?.orderOut(nil)
        countdownPanel?.close()
        countdownPanel = nil
    }

    private func showOutline(around rect: CGRect) {
        hideOutline()
        let panel = makeAreaOutline(around: rect)
        panel.orderFrontRegardless()
        outlinePanel = panel
    }

    private func hideOutline() {
        outlinePanel?.orderOut(nil)
        outlinePanel?.close()
        outlinePanel = nil
    }
}
