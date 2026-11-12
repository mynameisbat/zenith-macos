import Foundation

/// A Now Playing feed driven by the test: `deliver` plays the part of the adapter, and `sentKeys` records the
/// playback commands the service handed over.
public final class MockNowPlayingSource: NowPlayingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onMessage: (@Sendable (NowPlayingAdapterMessage) -> Void)?
    private var _sentKeys: [MediaKey] = []
    private var _seeks: [TimeInterval] = []
    private var _acceptsCommands = true
    private var _isStarted = false

    public init() {}

    public var sentKeys: [MediaKey] { lock.withLock { _sentKeys } }
    public var seeks: [TimeInterval] { lock.withLock { _seeks } }
    public var isStarted: Bool { lock.withLock { _isStarted } }

    /// False stands in for a watcher that is gone: the command cannot be handed over.
    public var acceptsCommands: Bool {
        get { lock.withLock { _acceptsCommands } }
        set { lock.withLock { _acceptsCommands = newValue } }
    }

    public func start(onMessage: @escaping @Sendable (NowPlayingAdapterMessage) -> Void) {
        lock.withLock {
            self.onMessage = onMessage
            _isStarted = true
        }
    }

    public func stop() {
        lock.withLock {
            onMessage = nil
            _isStarted = false
        }
    }

    @discardableResult
    public func send(_ key: MediaKey) -> Bool {
        lock.withLock {
            guard _acceptsCommands else { return false }
            _sentKeys.append(key)
            return true
        }
    }

    @discardableResult
    public func seek(to position: TimeInterval) -> Bool {
        lock.withLock {
            guard _acceptsCommands else { return false }
            _seeks.append(position)
            return true
        }
    }

    public func deliver(_ message: NowPlayingAdapterMessage) {
        let handler = lock.withLock { onMessage }
        handler?(message)
    }
}
