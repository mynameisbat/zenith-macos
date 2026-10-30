import AppKit
import Foundation
import Combine
import ZenithCore

/// Owns an `NSEvent` monitor and removes it when released, on the main thread.
///
/// This lets a main-actor class clean up without `isolated deinit`, which needs Swift 6.2; the README promises 6.0.
private final class EventMonitorToken: @unchecked Sendable {
    private var monitor: Any?

    init(_ monitor: Any?) {
        self.monitor = monitor
    }

    /// Removes the monitor now. Call on the main thread.
    @MainActor
    func remove() {
        guard let monitor else { return }
        self.monitor = nil
        NSEvent.removeMonitor(monitor)
    }

    deinit {
        // A deinit can run on any thread; monitors must be removed on the main one.
        guard let monitor else { return }
        nonisolated(unsafe) let leftover = monitor
        DispatchQueue.main.async { NSEvent.removeMonitor(leftover) }
    }
}

/// Model managing interactive hotkey recording and NSEvent monitor lifecycle.
@MainActor
public final class ShortcutRecorderModel: ObservableObject {
    @Published public var isRecording: Bool = false
    private var monitor: EventMonitorToken?

    public init() {}

    public func startRecording(id: String, title: String, onUpdate: @escaping (HotKeyDefinition) -> Bool) {
        guard !isRecording else { return }
        isRecording = true

        monitor = EventMonitorToken(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Escape (53) cancels recording
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            let flags = CarbonModifierFlags(nsModifierFlags: event.modifierFlags)
            // Require at least one command, option, or control modifier
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return nil
            }

            let formatted = HotKeyParser.format(keyCode: UInt32(event.keyCode), carbonModifiers: flags.rawValue)
            let newDef = HotKeyDefinition(
                id: id,
                name: title,
                keyCode: UInt32(event.keyCode),
                carbonModifiers: flags.rawValue,
                keyEquivalent: formatted
            )

            let success = onUpdate(newDef)
            if success {
                self.stopRecording()
            }
            return nil
        })
    }

    public func stopRecording() {
        monitor?.remove()
        monitor = nil
        isRecording = false
    }
}
