import Foundation
import AppKit

// MARK: - Seams

/// Something scheduled that can be called off.
public protocol ClipboardScheduledTask: AnyObject {
    func cancel()
}

/// Runs an action later on the main actor. The app uses `MainQueueClipboardScheduler`; tests use
/// `ManualClipboardScheduler` and move time forward themselves.
@MainActor
public protocol ClipboardScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ClipboardScheduledTask
}

/// Reports that the screen locked or the Mac is going to sleep. The app uses `SystemSessionLockObserver`; tests use
/// `MockSessionLockEventSource` and trigger it themselves.
@MainActor
public protocol SessionLockEventSource: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// `DispatchQueue.main.asyncAfter`, cancellable.
@MainActor
public final class MainQueueClipboardScheduler: ClipboardScheduling {
    private final class Task: ClipboardScheduledTask {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    public init() {}

    public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ClipboardScheduledTask {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Task(item: item)
    }
}

/// `com.apple.screenIsLocked` (distributed notification) and `NSWorkspace.willSleepNotification`.
@MainActor
public final class SystemSessionLockObserver: SessionLockEventSource {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init() {}

    public func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let fire: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { handler() }
        }
        let distributed = DistributedNotificationCenter.default()
        tokens.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: fire
        )))
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: fire
        )))
    }

    public func stop() {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
        tokens.removeAll()
    }
}

// MARK: - Auto-clear

/// Empties the system clipboard a while after a copy, and when the screen locks or the Mac sleeps, as
/// `ClipboardPrivacySettings` says. It never clears something copied after the copy it was waiting on: the
/// pasteboard's change count must still be the one it saw. The history is left as it is.
@MainActor
public final class ClipboardAutoClearController {
    public static let shared = ClipboardAutoClearController(
        settings: .shared,
        pasteboard: PasteboardMonitor.shared,
        scheduler: MainQueueClipboardScheduler(),
        lockEvents: SystemSessionLockObserver()
    )

    private let settings: ClipboardPrivacySettings
    private let pasteboard: PasteboardServiceProtocol
    private let scheduler: ClipboardScheduling
    private let lockEvents: SessionLockEventSource

    private var pending: ClipboardScheduledTask?
    /// The change count the pending clear waits on.
    public private(set) var pendingChangeCount: Int?
    /// The change count right after Zenith last emptied the clipboard.
    public private(set) var lastClearedChangeCount: Int?
    private var isStarted = false

    public init(
        settings: ClipboardPrivacySettings,
        pasteboard: PasteboardServiceProtocol,
        scheduler: ClipboardScheduling,
        lockEvents: SessionLockEventSource
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.scheduler = scheduler
        self.lockEvents = lockEvents
    }

    /// Starts listening for lock and sleep, and for new copies on `monitor`.
    public func start(observing monitor: PasteboardMonitor? = nil) {
        monitor?.changeObserver = { [weak self] count in
            self?.noteChange(changeCount: count)
        }
        guard !isStarted else { return }
        isStarted = true
        lockEvents.start { [weak self] in
            self?.handleLockOrSleep()
        }
    }

    public func stop(observing monitor: PasteboardMonitor? = nil) {
        monitor?.changeObserver = nil
        cancelPending()
        if isStarted {
            lockEvents.stop()
            isStarted = false
        }
    }

    /// The clipboard now holds something new (`changeCount`): wait the chosen time, then empty it if it still does.
    public func noteChange(changeCount: Int) {
        cancelPending()
        guard let delay = settings.autoClearDelay.seconds else { return }
        pendingChangeCount = changeCount
        pending = scheduler.schedule(after: delay) { [weak self] in
            self?.fire(expecting: changeCount)
        }
    }

    /// The screen locked or the Mac is going to sleep.
    public func handleLockOrSleep() {
        guard settings.clearOnLock else { return }
        cancelPending()
        // Already empty because of Zenith: clearing again would only bump the change count.
        if let cleared = lastClearedChangeCount, cleared == pasteboard.changeCount { return }
        clearNow()
    }

    private func fire(expecting changeCount: Int) {
        pending = nil
        pendingChangeCount = nil
        // Turned off meanwhile, or something else was copied (or the clipboard was emptied) since.
        guard settings.autoClearDelay != .never, pasteboard.changeCount == changeCount else { return }
        clearNow()
    }

    private func clearNow() {
        pasteboard.clear()
        lastClearedChangeCount = pasteboard.changeCount
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingChangeCount = nil
    }
}
