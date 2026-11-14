#if DEBUG
import Foundation

/// Records what the recorder asked for, without touching the screen or the microphone.
public final class MockScreenRecordingBackend: ScreenRecordingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordingRequest] = []
    private var _stopCount = 0
    private var _cancelCount = 0
    private var _onUnexpectedStop: (@Sendable (Error) -> Void)?

    public var startError: Error?
    public var stopError: Error?
    public var duration: TimeInterval = 4

    public init() {}

    public var requests: [RecordingRequest] { lock.withLock { _requests } }
    public var stopCount: Int { lock.withLock { _stopCount } }
    public var cancelCount: Int { lock.withLock { _cancelCount } }

    public var onUnexpectedStop: (@Sendable (Error) -> Void)? {
        get { lock.withLock { _onUnexpectedStop } }
        set { lock.withLock { _onUnexpectedStop = newValue } }
    }

    public func start(_ request: RecordingRequest) async throws {
        lock.withLock { _requests.append(request) }
        if let startError { throw startError }
    }

    public func stop() async throws -> RecordingResult {
        let url: URL? = lock.withLock {
            _stopCount += 1
            return _requests.last?.outputURL
        }
        if let stopError { throw stopError }
        guard let url else { throw ScreenRecordingError.notRecording }
        return RecordingResult(url: url, duration: duration)
    }

    public func cancel() async {
        lock.withLock { _cancelCount += 1 }
    }

    /// Pretends the stream ended by itself (the recorded window closed).
    public func simulateUnexpectedStop() {
        onUnexpectedStop?(ScreenRecordingError.streamFailed("window closed"))
    }
}

/// A microphone permission with a fixed answer that counts the prompts.
public final class MockMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var access: MicrophoneAccess
    private let grantsWhenAsked: Bool
    private var _requestCount = 0

    public init(access: MicrophoneAccess, grantsWhenAsked: Bool = true) {
        self.access = access
        self.grantsWhenAsked = grantsWhenAsked
    }

    public var requestCount: Int { lock.withLock { _requestCount } }

    public func currentAccess() -> MicrophoneAccess { lock.withLock { access } }

    public func requestAccess() async -> Bool {
        lock.withLock {
            _requestCount += 1
            access = grantsWhenAsked ? .granted : .denied
            return grantsWhenAsked
        }
    }
}
#endif
