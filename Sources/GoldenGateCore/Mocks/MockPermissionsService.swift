#if DEBUG
import Foundation

/// Headless test mock for permissions checks, enabling deterministic testing of onboarding flows.
public final class MockPermissionsService: PermissionsServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var screenRecordingGranted: Bool
    public var accessibilityGranted: Bool
    public private(set) var requestScreenRecordingCallCount: Int = 0
    public private(set) var requestAccessibilityCallCount: Int = 0
    public private(set) var openScreenRecordingSettingsCallCount: Int = 0
    public private(set) var openAccessibilitySettingsCallCount: Int = 0

    public init(screenRecordingGranted: Bool = false, accessibilityGranted: Bool = false) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public func checkScreenRecordingPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return screenRecordingGranted
    }

    public func checkAccessibilityPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accessibilityGranted
    }

    public func requestScreenRecordingPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requestScreenRecordingCallCount += 1
        return screenRecordingGranted
    }

    public func requestAccessibilityPermission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requestAccessibilityCallCount += 1
        return accessibilityGranted
    }

    public func openScreenRecordingSettings() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openScreenRecordingSettingsCallCount += 1
        return true
    }

    public func openAccessibilitySettings() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openAccessibilitySettingsCallCount += 1
        return true
    }

    public func reset() {
        lock.lock()
        screenRecordingGranted = false
        accessibilityGranted = false
        requestScreenRecordingCallCount = 0
        requestAccessibilityCallCount = 0
        openScreenRecordingSettingsCallCount = 0
        openAccessibilitySettingsCallCount = 0
        lock.unlock()
    }
}
#endif
