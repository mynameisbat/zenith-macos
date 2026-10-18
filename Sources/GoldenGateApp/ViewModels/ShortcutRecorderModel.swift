import AppKit
import Foundation
import Combine
import GoldenGateCore

/// Model managing interactive hotkey recording and NSEvent monitor lifecycle.
@MainActor
public final class ShortcutRecorderModel: ObservableObject {
    @Published public var isRecording: Bool = false
    private var monitor: Any?

    public init() {}

    public func startRecording(id: String, title: String, onUpdate: @escaping (HotKeyDefinition) -> Bool) {
        guard !isRecording else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        }
    }

    public func stopRecording() {
        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }
        isRecording = false
    }

    isolated deinit {
        stopRecording()
    }
}
