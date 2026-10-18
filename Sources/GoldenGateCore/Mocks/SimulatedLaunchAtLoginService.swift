#if DEBUG
import Foundation

/// Headless test mock for LaunchAtLoginServiceProtocol enabling deterministic unit testing.
public final class SimulatedLaunchAtLoginService: LaunchAtLoginServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LaunchAtLoginStatus

    public var shouldThrow: Bool = false
    public var shouldThrowOnEnable: LaunchAtLoginError?
    public var shouldThrowOnDisable: LaunchAtLoginError?
    public private(set) var enableCallCount: Int = 0
    public private(set) var disableCallCount: Int = 0

    public init(initialStatus: LaunchAtLoginStatus = .notRegistered) {
        self._status = initialStatus
    }

    public convenience init(initialState: Bool) {
        self.init(initialStatus: initialState ? .enabled : .notRegistered)
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _status == .enabled
    }

    public var status: LaunchAtLoginStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public func setStatus(_ newStatus: LaunchAtLoginStatus) {
        lock.lock()
        defer { lock.unlock() }
        _status = newStatus
    }

    public func enable() throws {
        lock.lock()
        defer { lock.unlock() }
        enableCallCount += 1
        if shouldThrow {
            throw LaunchAtLoginError.registrationFailed("Simulated registration failure")
        }
        if let error = shouldThrowOnEnable {
            throw error
        }
        _status = .enabled
    }

    public func disable() throws {
        lock.lock()
        defer { lock.unlock() }
        disableCallCount += 1
        if shouldThrow {
            throw LaunchAtLoginError.registrationFailed("Simulated unregistration failure")
        }
        if let error = shouldThrowOnDisable {
            throw error
        }
        _status = .notRegistered
    }

    public func resetCallCounts() {
        lock.lock()
        defer { lock.unlock() }
        enableCallCount = 0
        disableCallCount = 0
    }
}
#endif
