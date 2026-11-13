import AppKit
import SwiftUI
import ZenithCore

/// Scrolling capture: the user drags over the content, Zenith scrolls it (or the user does) and joins the frames into
/// one tall picture, which opens in the annotation editor.
@MainActor
final class ScrollingCaptureCoordinator {
    static let shared = ScrollingCaptureCoordinator()

    private var session: ScrollingCaptureSession?
    private var hudPanel: NSPanel?
    private var outlinePanel: NSPanel?
    private var task: Task<Void, Never>?

    var isActive: Bool { session != nil }

    /// The shortcut and the menu item: start, or finish the capture that is running.
    func toggle() {
        if let session {
            session.finish()
        } else {
            begin()
        }
    }

    func begin() {
        guard session == nil else { return }
        CaptureOverlayController.shared.startSelection(purpose: .scrolling) { [weak self] selection in
            guard let self, case .region(let rect, let screen)? = selection else { return }
            self.start(rect: rect.integral, screen: screen)
        }
    }

    private func start(rect: CGRect, screen: NSScreen) {
        guard rect.width >= 40, rect.height >= 40 else {
            ToastHUDController.shared.show(message: "Choose a larger area for a scrolling capture.", icon: "arrow.up.and.down.text.horizontal")
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let local = CoordinateTranslationService.appKitToDisplayLocalCoreGraphics(rect: rect, displayFrame: screen.frame, primaryScreenHeight: primaryHeight)
        let poster = CGScrollEventPoster()
        let mode: ScrollingCaptureSession.Mode = poster.canPost ? .automatic : .manual
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)  // global CoreGraphics coordinates
        let session = ScrollingCaptureSession(
            mode: mode,
            grabber: ScreenRegionFrameGrabber(displayID: displayID, rect: local, scale: screen.backingScaleFactor),
            poster: poster,
            scrollPoint: center,
            areaHeightPoints: rect.height,
            pixelScale: screen.backingScaleFactor
        )
        self.session = session

        let outline = makeAreaOutline(around: rect, color: .systemBlue)
        outline.orderFrontRegardless()
        outlinePanel = outline
        showHUD(session: session, near: rect, on: screen)

        let pointerBefore = NSEvent.mouseLocation
        task = Task { [weak self] in
            let image = await session.run()
            guard let self else { return }
            if mode == .automatic {
                // The pointer was moved over the area to scroll it; put it back.
                CGWarpMouseCursorPosition(CGPoint(x: pointerBefore.x, y: primaryHeight - pointerBefore.y))
            }
            self.tearDown()
            if let image {
                AudioFeedbackManager.shared.playShutterSound()
                AnnotationWindowController.shared.present(image: image)
            } else if case .failed(let reason) = session.phase {
                ToastHUDController.shared.show(verbatim: String(localized: "Scrolling capture failed"), icon: "exclamationmark.triangle.fill", subtitle: reason)
            }
        }
    }

    private func showHUD(session: ScrollingCaptureSession, near rect: CGRect, on screen: NSScreen) {
        let view = ScrollingCaptureHUD(
            session: session,
            onDone: { session.finish() },
            onCancel: { session.cancel() },
            onOpenAccessibility: { SystemPermissions.openAccessibilitySettings() }
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = RecordingKeyPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Outside the area when possible: on macOS 13 the frames would otherwise include the panel.
        let visible = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 4 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY - 4 {
            if rect.maxX + 12 + size.width <= visible.maxX {
                origin = CGPoint(x: rect.maxX + 12, y: rect.midY - size.height / 2)
            } else if rect.minX - 12 - size.width >= visible.minX {
                origin = CGPoint(x: rect.minX - 12 - size.width, y: rect.midY - size.height / 2)
            } else {
                origin.y = visible.minY + 12
            }
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    private func tearDown() {
        hudPanel?.orderOut(nil)
        hudPanel?.close()
        hudPanel = nil
        outlinePanel?.orderOut(nil)
        outlinePanel?.close()
        outlinePanel = nil
        session = nil
        task = nil
    }
}

struct ScrollingCaptureHUD: View {
    @ObservedObject var session: ScrollingCaptureSession
    let onDone: () -> Void
    let onCancel: () -> Void
    let onOpenAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .foregroundStyle(ZenithTheme.accent)
                    .accessibilityHidden(true)
                Text(session.mode == .automatic ? "Scrolling Capture" : "Scroll the content slowly")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 12)
                Text("\(session.capturedHeight) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if session.mode == .manual {
                HStack(spacing: 6) {
                    Text("Allow Accessibility and Zenith scrolls for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: onOpenAccessibility)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if session.lostTrack {
                Text("Lost the place: scroll back a little, more slowly.")
                    .font(.caption)
                    .foregroundStyle(ZenithTheme.warning)
            } else if session.reachedLimit {
                Text("Reached the height limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ZenithTheme.hairlineColor, lineWidth: 0.5))
    }
}
