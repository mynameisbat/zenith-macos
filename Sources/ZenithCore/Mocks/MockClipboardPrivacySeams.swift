#if DEBUG
import Foundation

/// A frontmost app that tests set by hand.
public final class MockFrontmostApplicationProvider: FrontmostApplicationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _bundleIdentifier: String?

    public init(bundleIdentifier: String? = nil) {
        self._bundleIdentifier = bundleIdentifier
    }

    public var bundleIdentifier: String? {
        get { lock.withLock { _bundleIdentifier } }
        set { lock.withLock { _bundleIdentifier = newValue } }
    }

    public func frontmostBundleIdentifier() -> String? {
        bundleIdentifier
    }
}

/// A scheduler whose clock only moves when a test calls `advance(by:)`.
@MainActor
public final class ManualClipboardScheduler: ClipboardScheduling {
    private final class Entry: ClipboardScheduledTask {
        let fireAt: TimeInterval
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false

        init(fireAt: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    public private(set) var now: TimeInterval = 0
    private var entries: [Entry] = []

    public init() {}

    /// Actions scheduled and not yet run or cancelled.
    public var pendingCount: Int {
        entries.filter { !$0.isCancelled }.count
    }

    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ClipboardScheduledTask {
        let entry = Entry(fireAt: now + seconds, action: action)
        entries.append(entry)
        return entry
    }

    /// Moves the clock forward and runs, in order, everything that is due.
    public func advance(by seconds: TimeInterval) {
        now += seconds
        while let next = entries.filter({ !$0.isCancelled && $0.fireAt <= now }).min(by: { $0.fireAt < $1.fireAt }) {
            entries.removeAll { $0 === next }
            next.action()
        }
        entries.removeAll { $0.isCancelled }
    }
}

/// A lock/sleep source that tests trigger themselves.
@MainActor
public final class MockSessionLockEventSource: SessionLockEventSource {
    private var handler: (@MainActor @Sendable () -> Void)?
    public private(set) var isStarted = false

    public init() {}

    public func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        isStarted = true
    }

    public func stop() {
        handler = nil
        isStarted = false
    }

    /// Acts as if the screen locked or the Mac is going to sleep.
    public func trigger() {
        handler?()
    }
}
#endif
