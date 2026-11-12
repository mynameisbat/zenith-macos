import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// A level the island shows as a bar when it changes.
public enum IslandLevelKind: String, Sendable, Equatable {
    case volume
    case brightness

    /// The symbol for a level between 0 and 1.
    public func icon(level: Double, isMuted: Bool) -> String {
        switch self {
        case .volume:
            if isMuted || level <= 0 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    public var title: String {
        switch self {
        case .volume: return String(localized: "Volume")
        case .brightness: return String(localized: "Brightness")
        }
    }
}

/// The keyboard's special keys as macOS reports them in a system-defined event (subtype 8).
public enum HardwareKey: Int, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    public static let eventSubtype: Int16 = 8

    /// The key in a system-defined event and whether it went down, or nil for anything else.
    public static func parse(subtype: Int16, data1: Int) -> (key: HardwareKey, isDown: Bool)? {
        guard subtype == eventSubtype, let key = HardwareKey(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
        return (key, ((data1 & 0xFF00) >> 8) == 0x0A)
    }
}

/// Reads a display's brightness through the private DisplayServices framework (the public IOKit call does not work
/// on Apple silicon). Returns nil for a display that has none to report, such as most external monitors.
public enum SystemBrightness {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private static let getBrightness: GetBrightness? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    public static func read(display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    /// The built-in display, which is the one the brightness keys change.
    public static func readBuiltIn() -> Double? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        guard let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        return read(display: builtIn)
    }
}

/// Follows the default output device's volume and mute with CoreAudio listeners. Nothing is polled.
@MainActor
final class SystemVolumeObserver {
    private var deviceID: AudioDeviceID = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var levelListener: AudioObjectPropertyListenerBlock?
    private var onChange: ((_ level: Double, _ isMuted: Bool) -> Void)?
    private var last: (level: Double, isMuted: Bool)?

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start(onChange: @escaping (_ level: Double, _ isMuted: Bool) -> Void) {
        guard deviceListener == nil else { return }
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.deviceChanged() }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, listener)
        attach()
    }

    func stop() {
        detach()
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, deviceListener)
        }
        deviceListener = nil
        onChange = nil
    }

    /// Another output (AirPods, a monitor) has its own level: follow it, without announcing the difference.
    private func deviceChanged() {
        detach()
        attach()
    }

    private func attach() {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &device) == noErr,
              device != 0 else { return }
        deviceID = device
        last = read()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.levelChanged() }
        }
        levelListener = listener
        AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, listener)
        AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, listener)
    }

    private func detach() {
        if deviceID != 0, let levelListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, .main, levelListener)
            AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, .main, levelListener)
        }
        levelListener = nil
        deviceID = 0
    }

    private func levelChanged() {
        guard let now = read() else { return }
        // One key press arrives as several notifications with the same values.
        if let last, abs(last.level - now.level) < 0.001, last.isMuted == now.isMuted { return }
        last = now
        onChange?(now.level, now.isMuted)
    }

    private func read() -> (level: Double, isMuted: Bool)? {
        guard deviceID != 0 else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volume) == noErr, volume.isFinite else {
            return nil
        }
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            _ = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &mute)
        }
        return (Double(min(max(volume, 0), 1)), mute != 0)
    }
}

/// Shows volume and brightness changes on the island.
///
/// Volume comes from CoreAudio, so the Control Center slider counts as well as the keys. macOS has no notification
/// for brightness that an app may use, so that one follows the brightness keys and then reads the display.
@MainActor
public final class IslandLevelHUDService {
    public static let shared = IslandLevelHUDService()

    private let island: ZenithIslandState
    private let brightnessReader: @MainActor () -> Double?
    private let volumeObserver = SystemVolumeObserver()
    private var keyMonitor: Any?
    private var brightnessRead: Task<Void, Never>?

    public init(
        island: ZenithIslandState = .shared,
        brightnessReader: @escaping @MainActor () -> Double? = { SystemBrightness.readBuiltIn() }
    ) {
        self.island = island
        self.brightnessReader = brightnessReader
    }

    public func start() {
        volumeObserver.start { [weak self] level, isMuted in
            self?.volumeChanged(level: level, isMuted: isMuted)
        }
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            let subtype = event.subtype.rawValue
            let data1 = event.data1
            Task { @MainActor [weak self] in
                self?.hardwareKeyEvent(subtype: subtype, data1: data1)
            }
        }
    }

    public func stop() {
        volumeObserver.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        brightnessRead?.cancel()
        brightnessRead = nil
    }

    func volumeChanged(level: Double, isMuted: Bool) {
        island.showLevel(.volume, level: level, isMuted: isMuted)
    }

    func hardwareKeyEvent(subtype: Int16, data1: Int) {
        guard let (key, isDown) = HardwareKey.parse(subtype: subtype, data1: data1), isDown,
              key == .brightnessUp || key == .brightnessDown else { return }
        // The display has not moved yet when the key event arrives.
        brightnessRead?.cancel()
        brightnessRead = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, !Task.isCancelled else { return }
            self.showBrightness()
        }
    }

    func showBrightness() {
        guard let level = brightnessReader() else { return }
        island.showLevel(.brightness, level: level)
    }

    /// Waits for a brightness reading in flight. For tests.
    func waitForBrightnessRead() async {
        await brightnessRead?.value
    }
}
