import Foundation

/// Sends the latest of a stream of values, never every one: what a slider drag needs when each send takes a tenth of a
/// second and a display stores each one it is given.
///
/// `submit` only keeps the newest value. A drain on `queue` takes it, performs it, and goes round again only if a newer
/// value arrived meanwhile, no sooner than `minInterval` after the last one started. A value submitted as final (the
/// drag ended) does not wait for that interval: it goes out as soon as the one in flight is done.
final class CoalescedWriter<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let minInterval: TimeInterval
    private let perform: @Sendable (Value) -> Void

    private let lock = NSLock()
    private var pending: Value?
    private var isDraining = false
    private var scheduled: DispatchWorkItem?
    private var lastStart: DispatchTime?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(queue: DispatchQueue, minInterval: TimeInterval, perform: @escaping @Sendable (Value) -> Void) {
        self.queue = queue
        self.minInterval = minInterval
        self.perform = perform
    }

    func submit(_ value: Value, isFinal: Bool = false) {
        lock.lock()
        pending = value
        // A drain already running picks the new value up when it finishes; one waiting out its interval is brought
        // forward for a final value.
        guard !isDraining else {
            lock.unlock()
            return
        }
        if scheduled != nil, !isFinal {
            lock.unlock()
            return
        }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drain() }
        scheduled = work
        let deadline = isFinal ? DispatchTime.now() : nextDeadlineLocked()
        lock.unlock()
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    /// Returns once nothing is pending or in flight.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending == nil, !isDraining, scheduled == nil {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func nextDeadlineLocked() -> DispatchTime {
        guard let lastStart else { return .now() }
        return max(.now(), lastStart + minInterval)
    }

    private func drain() {
        lock.lock()
        scheduled = nil
        isDraining = true
        let value = pending
        pending = nil
        lastStart = .now()
        lock.unlock()

        if let value { perform(value) }

        lock.lock()
        isDraining = false
        if pending != nil {
            let work = DispatchWorkItem { [weak self] in self?.drain() }
            scheduled = work
            let deadline = nextDeadlineLocked()
            lock.unlock()
            queue.asyncAfter(deadline: deadline, execute: work)
        } else {
            let waiters = idleWaiters
            idleWaiters = []
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }
}
