import AppKit
import SwiftUI
import QuartzCore
import ZenithCore

// Small windows around a recording: the options bar shown after choosing what to record, the 3-2-1 countdown, the
// outline around a recorded area, the click rings, and the stop button in the menu bar. They are Zenith windows, so
// the recording leaves them out (the click rings are let back in on purpose).

/// A borderless panel that can take keys (Return records, Esc cancels).
final class RecordingKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Options bar

struct RecordingOptionsBar: View {
    @ObservedObject var settings: ScreenRecordingSettings
    let onRecord: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            optionToggle(isOn: $settings.systemAudio, symbol: "speaker.wave.2.fill", label: "System Audio")
            optionToggle(isOn: $settings.microphone, symbol: "mic.fill", label: "Microphone")
            optionToggle(isOn: $settings.showsCursor, symbol: "cursorarrow", label: "Show Pointer")
            optionToggle(isOn: $settings.highlightsClicks, symbol: "cursorarrow.click", label: "Highlight Clicks")
            optionToggle(isOn: $settings.countdown, symbol: "timer", label: "3-2-1 Countdown")

            Picker("Frame Rate", selection: $settings.frameRate) {
                Text(verbatim: "30").tag(RecordingFrameRate.fps30)
                Text(verbatim: "60").tag(RecordingFrameRate.fps60)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Frames per second")

            Divider().frame(height: 22)

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ZenithTheme.hairlineColor, lineWidth: 0.5))
        .fixedSize()
    }

    private func optionToggle(isOn: Binding<Bool>, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn.wrappedValue ? ZenithTheme.accent : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? Text("On") : Text("Off"))
    }
}

// MARK: - Countdown

struct RecordingCountdownView: View {
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: 76, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 150, height: 150)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .accessibilityLabel(Text("Recording starts in \(number)"))
    }
}

/// A click-through panel that floats above everything on every Space.
@MainActor
func makeOverlayPanel(frame: CGRect, level: NSWindow.Level = .screenSaver) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = level
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

// MARK: - Area outline

/// A dashed line just outside a recorded or scrolled area, so the user sees what is captured.
final class AreaOutlineView: NSView {
    var color: NSColor = .systemRed

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }
}

@MainActor
func makeAreaOutline(around rect: CGRect, color: NSColor = .systemRed) -> NSPanel {
    // 4 points outside the area, so the line itself is never inside the picture.
    let frame = rect.insetBy(dx: -4, dy: -4)
    let panel = makeOverlayPanel(frame: frame, level: .statusBar)
    let view = AreaOutlineView(frame: CGRect(origin: .zero, size: frame.size))
    view.color = color
    panel.contentView = view
    return panel
}

// MARK: - Click rings

/// Draws a fading ring where the user clicks, in transparent panels over the recorded screen. The recording lets
/// exactly these Zenith windows in.
@MainActor
final class ClickHighlightOverlay {
    private var panels: [NSPanel] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Shows the panels on `screens` and returns their window numbers.
    func show(on screens: [NSScreen]) -> [CGWindowID] {
        hide()
        for screen in screens {
            let panel = makeOverlayPanel(frame: screen.frame, level: .screenSaver)
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.ring(at: location) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.ring(at: NSEvent.mouseLocation)
            return event
        }
        return panels.map { CGWindowID(UInt32(max(0, $0.windowNumber))) }
    }

    func hide() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private func ring(at globalPoint: CGPoint) {
        guard let panel = panels.first(where: { $0.frame.contains(globalPoint) }), let layer = panel.contentView?.layer else { return }
        let local = CGPoint(x: globalPoint.x - panel.frame.minX, y: globalPoint.y - panel.frame.minY)
        let size: CGFloat = 44
        let shape = CAShapeLayer()
        shape.frame = CGRect(x: local.x - size / 2, y: local.y - size / 2, width: size, height: size)
        shape.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: size - 4, height: size - 4), transform: nil)
        shape.fillColor = NSColor.systemYellow.withAlphaComponent(0.28).cgColor
        shape.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        shape.lineWidth = 3
        layer.addSublayer(shape)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.15
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.opacity = 0
        shape.add(group, forKey: "click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shape.removeFromSuperlayer() }
    }
}

// MARK: - Stop button in the menu bar

/// A red stop button with the elapsed time, in the menu bar while recording. Clicking it stops.
@MainActor
final class RecordingStopStatusItem: NSObject {
    private var item: NSStatusItem?
    private var timer: Timer?
    private var startedAt: Date?
    var onStop: (() -> Void)?

    func show(startedAt: Date) {
        self.startedAt = startedAt
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            item.button?.contentTintColor = .systemRed
            item.button?.imagePosition = .imageLeading
            item.button?.toolTip = String(localized: "Stop Recording")
            item.button?.setAccessibilityLabel(String(localized: "Stop Recording"))
            self.item = item
        }
        update()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func showSaving() {
        timer?.invalidate()
        timer = nil
        item?.button?.title = " " + String(localized: "Saving…")
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        startedAt = nil
    }

    private func update() {
        guard let startedAt else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item?.button?.attributedTitle = NSAttributedString(
            string: " " + RecordingTimeFormatter.string(Date().timeIntervalSince(startedAt)),
            attributes: [.font: font]
        )
    }

    @objc private func clicked() {
        onStop?()
    }
}

/// "0:07", "12:34", "1:02:03".
enum RecordingTimeFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
