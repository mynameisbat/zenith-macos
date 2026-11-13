import Foundation

// The recorder's life: idle → (countdown) → preparing → recording → stopping → finished / failed. The transitions are
// a pure function so every path is tested; `ScreenRecorder` drives a backend through them.

public enum ScreenRecorderState: Equatable, Sendable {
    case idle
    /// The 3-2-1 before recording. The value is the number on screen.
    case countingDown(Int)
    /// Asking for permissions and starting the stream.
    case preparing
    case recording(startedAt: Date)
    case stopping
    case finished(RecordingResult)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .countingDown, .preparing, .recording, .stopping: return true
        case .idle, .finished, .failed: return false
        }
    }

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

public enum ScreenRecorderEvent: Equatable, Sendable {
    case start(countdown: Int)
    case countdownTick
    case cancel
    case backendStarted(Date)
    case backendFailed(String)
    case stop
    case backendFinished(RecordingResult)
}

public enum ScreenRecorderStateMachine {
    /// The state after `event`, or `nil` when the event does not apply in `state` (it is then ignored).
    public static func reduce(_ state: ScreenRecorderState, _ event: ScreenRecorderEvent) -> ScreenRecorderState? {
        switch (state, event) {
        case (.idle, .start(let n)), (.finished, .start(let n)), (.failed, .start(let n)):
            return n > 0 ? .countingDown(n) : .preparing
        case (.countingDown(let n), .countdownTick):
            return n > 1 ? .countingDown(n - 1) : .preparing
        case (.countingDown, .cancel), (.countingDown, .stop):
            return .idle
        case (.preparing, .backendStarted(let date)):
            return .recording(startedAt: date)
        case (.preparing, .backendFailed(let reason)), (.stopping, .backendFailed(let reason)), (.recording, .backendFailed(let reason)):
            return .failed(reason)
        case (.preparing, .cancel):
            return .idle
        case (.recording, .stop):
            return .stopping
        case (.recording, .cancel):
            return .stopping
        case (.stopping, .backendFinished(let result)):
            return .finished(result)
        default:
            return nil
        }
    }
}

// MARK: - Seams

/// Records the screen. The live one is `ScreenCaptureKitRecordingBackend`; tests use `MockScreenRecordingBackend`.
public protocol ScreenRecordingBackend: AnyObject, Sendable {
    func start(_ request: RecordingRequest) async throws
    /// Ends the recording and finishes the file.
    func stop() async throws -> RecordingResult
    /// Ends the recording and removes the unfinished file.
    func cancel() async
    /// Called when the stream ends by itself (the window closed, the display went away). Set before `start`.
    var onUnexpectedStop: (@Sendable (Error) -> Void)? { get set }
}

/// Reads and asks for the microphone permission.
public protocol MicrophoneAuthorizing: Sendable {
    func currentAccess() -> MicrophoneAccess
    /// Shows the system prompt. Never called when `currentAccess()` is `.unavailable`.
    func requestAccess() async -> Bool
}

// MARK: - Recorder

/// Runs one recording at a time and publishes its state for the stop control and the island.
@MainActor
public final class ScreenRecorder: ObservableObject {
    public static let shared = ScreenRecorder(backend: ScreenCaptureKitRecordingBackend(), microphone: AVMicrophoneAuthorizer())

    @Published public private(set) var state: ScreenRecorderState = .idle
    /// Set when a sound the user asked for could not be recorded.
    @Published public private(set) var audioNotice: RecordingAudioNotice?

    private let backend: ScreenRecordingBackend
    private let microphone: MicrophoneAuthorizing
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    /// Bumped by every start and cancel, so an old countdown that wakes up late does nothing.
    private var generation = 0

    /// Called on every state change (the coordinator shows the stop control, the countdown, the result).
    public var onStateChange: ((ScreenRecorderState) -> Void)?

    public init(
        backend: ScreenRecordingBackend,
        microphone: MicrophoneAuthorizing,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.microphone = microphone
        self.sleep = sleep
        self.now = now
        backend.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedStop(error) }
        }
    }

    /// Decides the sounds, asking for the microphone only when the user turned it on and macOS never asked.
    public func resolveAudio(systemAudio: Bool, microphone microphoneOn: Bool) async -> RecordingAudioPlan {
        var access = microphone.currentAccess()
        if RecordingAudioPlan.needsMicrophoneRequest(microphoneOn: microphoneOn, access: access) {
            access = await microphone.requestAccess() ? .granted : .denied
        }
        return RecordingAudioPlan.resolve(systemAudio: systemAudio, microphone: microphoneOn, access: access)
    }

    /// Counts down (if `countdown > 0`) and starts recording. `makeRequest` runs after the countdown, so the click
    /// rings and the file name are made at the moment recording starts.
    public func start(countdown: Int, systemAudio: Bool, microphone microphoneOn: Bool, makeRequest: @escaping (RecordingAudioPlan) -> RecordingRequest?) async {
        guard !state.isBusy else { return }
        generation += 1
        let myGeneration = generation
        audioNotice = nil

        let plan = await resolveAudio(systemAudio: systemAudio, microphone: microphoneOn)
        guard myGeneration == generation else { return }
        audioNotice = plan.notice

        apply(.start(countdown: max(0, countdown)))
        while case .countingDown = state {
            do { try await sleep(.seconds(1)) } catch { return }
            guard myGeneration == generation else { return }
            apply(.countdownTick)
        }
        guard state == .preparing, myGeneration == generation else { return }

        guard let request = makeRequest(plan) else {
            apply(.cancel)
            return
        }
        do {
            try await backend.start(request)
            guard myGeneration == generation else {
                await backend.cancel()
                return
            }
            apply(.backendStarted(now()))
        } catch {
            apply(.backendFailed(Self.describe(error)))
        }
    }

    /// Stops and finishes the file. During the countdown it simply cancels.
    public func stop() async {
        switch state {
        case .countingDown, .preparing:
            cancel()
        case .recording:
            apply(.stop)
            do {
                let result = try await backend.stop()
                apply(.backendFinished(result))
            } catch {
                apply(.backendFailed(Self.describe(error)))
            }
        default:
            break
        }
    }

    /// Abandons a countdown or a recording without keeping a file.
    public func cancel() {
        generation += 1
        switch state {
        case .countingDown, .preparing:
            apply(.cancel)
        case .recording:
            apply(.cancel)
            Task {
                await backend.cancel()
                self.state = .idle
                self.onStateChange?(.idle)
            }
        default:
            break
        }
    }

    /// Back to idle after the result was shown.
    public func acknowledgeResult() {
        switch state {
        case .finished, .failed:
            state = .idle
            onStateChange?(.idle)
        default:
            break
        }
    }

    private func handleUnexpectedStop(_ error: Error) {
        guard state.isRecording else { return }
        // The stream ended by itself (the window closed): keep what was recorded.
        Task { await stop() }
    }

    private func apply(_ event: ScreenRecorderEvent) {
        guard let next = ScreenRecorderStateMachine.reduce(state, event) else { return }
        state = next
        onStateChange?(next)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
