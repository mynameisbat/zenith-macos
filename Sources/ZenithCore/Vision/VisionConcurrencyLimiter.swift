import Foundation

/// An actor-based concurrency limiter that restricts parallel Vision framework inferences.
///
/// Under burst capture conditions (e.g., hotkey spam or multi-display snapshots), running unthrottled
/// Vision neural network tasks can saturate the Apple Neural Engine and GPU, causing thermal throttling
/// and high memory watermarks. `VisionConcurrencyLimiter` caps active concurrent executions to a safe limit.
public actor VisionConcurrencyLimiter {
    /// Maximum concurrent operations permitted.
    public let maxConcurrentTasks: Int

    /// Current number of actively running tasks.
    private var activeCount: Int = 0

    /// Thread-safe waiter queue managing continuations.
    private let waiterQueue = LimiterQueue()

    /// Compatibility property for max concurrency limit.
    public var maxConcurrent: Int {
        maxConcurrentTasks
    }

    /// Initializes a new concurrency limiter with the specified maximum concurrent task count.
    /// - Parameter maxConcurrentTasks: The maximum number of simultaneous Vision tasks (default: 2).
    public init(maxConcurrentTasks: Int = 2) {
        self.maxConcurrentTasks = max(1, maxConcurrentTasks)
    }

    /// The number of currently executing tasks holding permits.
    public var activeTaskCount: Int {
        activeCount
    }

    /// The number of tasks suspended and waiting for an execution permit.
    public var waitingTaskCount: Int {
        waiterQueue.count
    }

    /// Acquires a concurrency permit, suspending cooperatively if the concurrency ceiling has been reached.
    ///
    /// If the enclosing task is cancelled before or while waiting, throws `CancellationError`
    /// without consuming or leaking a permit.
    public func acquire() async throws {
        try Task.checkCancellation()

        if activeCount < maxConcurrentTasks {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        let queue = self.waiterQueue

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.enqueue(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            queue.cancel(id: waiterID)
        }
    }

    /// Releases a concurrency permit, transferring it directly to the next waiting task if one exists.
    public func release() {
        if waiterQueue.resumeNext() {
            // Permit transferred directly to the resumed waiter; activeCount remains unchanged.
            return
        }

        activeCount = max(0, activeCount - 1)
    }

    /// Executes the given operation within an acquired concurrency permit.
    /// - Parameter operation: The asynchronous throwing closure to execute.
    /// - Returns: The result of the operation.
    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}

// MARK: - LimiterQueue

private final class LimiterQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiters[id] = continuation
            order.append(id)
        }
    }

    func resumeNext() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while !order.isEmpty {
            let nextID = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: nextID) {
                continuation.resume()
                return true
            }
        }
        return false
    }

    func cancel(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation = waiters.removeValue(forKey: id) {
            order.removeAll { $0 == id }
            continuation.resume(throwing: CancellationError())
        }
    }
}
