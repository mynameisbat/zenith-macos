#if DEBUG
import Foundation

/// A Cleaning Mode event tap that blocks nothing: tests push synthetic events through it.
@MainActor
public final class MockCleaningModeEventTap: CleaningModeEventTapping {
    public var failsToInstall = false
    public private(set) var installCount = 0
    public private(set) var removeCount = 0
    private var onEvent: (@MainActor (CleaningModeInputEvent) -> Bool)?
    private var onDisabled: (@MainActor (CleaningModeTapDisableReason) -> Void)?

    public init() {}

    public var isInstalled: Bool { onEvent != nil }

    public func install(
        onEvent: @escaping @MainActor (CleaningModeInputEvent) -> Bool,
        onDisabled: @escaping @MainActor (CleaningModeTapDisableReason) -> Void
    ) throws {
        if failsToInstall { throw CleaningModeError.tapUnavailable }
        installCount += 1
        self.onEvent = onEvent
        self.onDisabled = onDisabled
    }

    public func remove() {
        if onEvent != nil { removeCount += 1 }
        onEvent = nil
        onDisabled = nil
    }

    /// Delivers an event as the real tap would. Returns whether it was swallowed (`false` when no tap is installed:
    /// the event reaches the system).
    @discardableResult
    public func send(_ event: CleaningModeInputEvent) -> Bool {
        onEvent?(event) ?? false
    }

    /// Acts as macOS switching the tap off.
    public func simulateDisabled(_ reason: CleaningModeTapDisableReason) {
        onDisabled?(reason)
    }
}

/// A timer that only fires when a test calls `fire()`.
@MainActor
public final class ManualCleaningModeTicker: CleaningModeTicking {
    public private(set) var isRunning = false
    public private(set) var interval: TimeInterval?
    private var tick: (@MainActor () -> Void)?

    public init() {}

    public func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tick = tick
        isRunning = true
    }

    public func stop() {
        tick = nil
        isRunning = false
    }

    public func fire() {
        tick?()
    }
}

/// Records what the full-screen windows were asked to do.
@MainActor
public final class RecordingCleaningModePresenter: CleaningModePresenting {
    public private(set) var presented: [CleaningModeAppearance] = []
    public private(set) var dismissCount = 0
    public var isShowing: Bool { presented.count > dismissCount }

    public init() {}

    public func present(appearance: CleaningModeAppearance) {
        presented.append(appearance)
    }

    public func dismiss() {
        dismissCount += 1
    }
}
#endif
