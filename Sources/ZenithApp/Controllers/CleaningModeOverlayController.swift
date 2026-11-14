import AppKit
import SwiftUI
import ZenithCore

/// Starts Cleaning Mode from the hub, the global shortcut or Settings, and explains what went wrong when it cannot.
/// The blocking itself is `CleaningModeController` (Core); this wires it to the windows, alerts and shortcut.
@MainActor
public final class CleaningModeCoordinator {
    public static let shared = CleaningModeCoordinator()

    private let controller: CleaningModeController
    private let settings: CleaningModeSettings
    private var isConfigured = false

    public init(controller: CleaningModeController = .shared, settings: CleaningModeSettings = .shared) {
        self.controller = controller
        self.settings = settings
    }

    /// Called once at launch: gives the controller its windows and registers the shortcut if it is on.
    public func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        controller.presenter = CleaningModeOverlayController.shared
        controller.onEnd = { reason in
            // The app is going away; nobody would see a notice.
            guard reason != .appQuit else { return }
            ToastHUDController.shared.show(verbatim: CleaningModeController.endMessage(for: reason), icon: "keyboard")
        }
        _ = applyHotKeySetting()
    }

    public func start() {
        switch controller.start() {
        case .started, .alreadyActive:
            break
        case .needsAccessibility:
            explainAccessibility()
        case .tapUnavailable:
            ToastHUDController.shared.show(
                message: "Cleaning Mode could not start: macOS did not let Zenith block the keyboard and trackpad.",
                icon: "exclamationmark.triangle.fill"
            )
        }
    }

    /// Registers or removes the global shortcut to match the setting.
    /// - Returns: `false` when the shortcut is on but the system refused it (another app holds the keys); the setting
    ///   is switched back off then.
    @discardableResult
    public func applyHotKeySetting() -> Bool {
        let id = HotKeyDefinition.cleaningModeId
        guard settings.hotKeyEnabled else {
            HotKeyManager.shared.unregisterHotKey(id: id)
            return true
        }
        guard !HotKeyManager.shared.isRegistered(id: id) else { return true }
        let failed = HotKeyConfigurator.shared.registerAll([
            (HotKeyDefinition.defaultCleaningMode, {
                Task { @MainActor in CleaningModeCoordinator.shared.start() }
            })
        ])
        guard failed.isEmpty else {
            settings.hotKeyEnabled = false
            ToastHUDController.shared.show(
                message: "Shortcut \(failed[0].menuStyleKeyEquivalent) is taken by another app.",
                icon: "exclamationmark.triangle.fill"
            )
            return false
        }
        return true
    }

    /// Nothing was blocked: say why, and offer the Permissions page.
    private func explainAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Cleaning Mode needs Accessibility")
        alert.informativeText = String(localized: "To block the keyboard and trackpad, macOS must allow Zenith in Privacy & Security → Accessibility. Nothing is blocked until then.")
        alert.addButton(withTitle: String(localized: "Open Permissions"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsViewModel.request(.permissions)
        SettingsWindowController.shared.configureDefaultContent()
        SettingsWindowController.shared.show()
    }
}

// MARK: - Full-screen windows

/// A borderless window that takes the keyboard while Cleaning Mode is on, so keys the event tap cannot see (Secure
/// Keyboard Entry in another app hides them from taps) still land here and do nothing.
final class CleaningModeOverlayWindow: NSWindow {
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func flagsChanged(with event: NSEvent) {
        onModifiersChanged?(event.modifierFlags)
    }
    override func scrollWheel(with event: NSEvent) {}
}

/// One window per display, above everything (the shielding level), for as long as Cleaning Mode is on.
@MainActor
public final class CleaningModeOverlayController: CleaningModePresenting {
    public static let shared = CleaningModeOverlayController()

    private var windows: [CleaningModeOverlayWindow] = []
    private var appearance: CleaningModeAppearance = .black
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    private var hidCursor = false

    public init() {}

    public func present(appearance: CleaningModeAppearance) {
        self.appearance = appearance
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        buildWindows()
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        if appearance == .black, !hidCursor {
            NSCursor.hide()
            hidCursor = true
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildWindows() }
        }
    }

    public func dismiss() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        closeWindows()
        if hidCursor {
            NSCursor.unhide()
            hidCursor = false
        }
        previousApp?.activate()
        previousApp = nil
    }

    private func closeWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func buildWindows() {
        closeWindows()
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = CleaningModeOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = level
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = appearance == .black
            window.backgroundColor = appearance == .black ? .black : .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.onModifiersChanged = { flags in
                // Normally the tap sees these first; this covers keys hidden from it by secure input.
                MainActor.assumeIsolated {
                    _ = CleaningModeController.shared.handle(.modifiersChanged(Self.modifiers(from: flags)))
                }
            }
            window.contentView = NSHostingView(rootView: CleaningModeOverlayView(
                controller: .shared,
                appearance: appearance,
                showsDetails: index == 0
            ))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        windows.first?.makeKey()
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> CleaningModeModifiers {
        var result: CleaningModeModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// What a Cleaning Mode window shows: on black, dim grey text so smudges stay visible; dimmed, a small card.
struct CleaningModeOverlayView: View {
    @ObservedObject var controller: CleaningModeController
    let appearance: CleaningModeAppearance
    /// The main display gets the explanation; the others only the countdown.
    let showsDetails: Bool

    var body: some View {
        ZStack {
            (appearance == .black ? Color.black : Color.black.opacity(0.6))
                .ignoresSafeArea()
            if appearance == .black {
                content(textOpacity: 0.45)
            } else {
                content(textOpacity: 0.95)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func content(textOpacity: Double) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: showsDetails ? 30 : 22, weight: .light))
            Text("Cleaning Mode")
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: CleaningModeSettings.countdownText(controller.remainingSeconds))
                .font(.system(size: showsDetails ? 54 : 36, weight: .light, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel(Text(verbatim: CleaningModeSettings.durationText(controller.remainingSeconds)))
            if showsDetails {
                Text("The keyboard and trackpad are blocked. They work again when the time is up.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                Text("To stop early, hold \(CleaningModeExitGesture.keysText) for 2 seconds.")
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            if controller.exitHoldProgress > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: controller.exitHoldProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 180)
                    Text("Keep holding…")
                        .font(.system(size: 12))
                }
            }
        }
        .foregroundStyle(Color.white.opacity(textOpacity))
        .frame(maxWidth: 420)
    }
}
