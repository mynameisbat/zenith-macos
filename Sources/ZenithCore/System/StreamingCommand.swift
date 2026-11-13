import Foundation
import Darwin

/// Lets whoever started a streaming command stop it. Thread-safe; cancelling twice does nothing more.
public final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let pending: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { handler = nil }
            return handler
        }
        pending?()
    }

    /// Runs `handler` on cancellation, or at once if that already happened.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            self.handler = handler
            return false
        }
        if runNow { handler() }
    }
}

/// Runs an executable, hands its output (standard output and error, interleaved as written) to `onOutput` while it
/// runs, and returns the result once it exits, or `nil` when it could not be launched. `cancellation` stops it.
/// The streaming counterpart of `SystemCommandRunner`; tests pass a fake.
public typealias StreamingCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ cancellation: CommandCancellation,
    _ onOutput: @escaping @Sendable (String) -> Void
) async -> SystemCommandResult?

public enum StreamingCommand {
    /// How long a cancelled command gets after SIGTERM before its process group is killed.
    static let killGracePeriod: TimeInterval = 5

    /// Runs a real process in its own process group, so cancelling also stops what it started (brew's curl, an
    /// installer). Standard input is `/dev/null`: nothing can sit waiting for an answer that never comes.
    /// The blocking work happens on dedicated threads, never on the cooperative pool.
    public static let processRunner: StreamingCommandRunner = { executable, arguments, cancellation, onOutput in
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: runBlocking(executable, arguments, cancellation, onOutput))
            }
            thread.name = "Zenith streaming command"
            thread.start()
        }
    }

    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _status: Int32?
        var status: Int32? {
            get { lock.withLock { _status } }
            set { lock.withLock { _status = newValue } }
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        _ cancellation: CommandCancellation,
        _ onOutput: @escaping @Sendable (String) -> Void
    ) -> SystemCommandResult? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (so the whole tree can be signalled), only fds 0–2 inherited, default signal handling
        // (Zenith ignores SIGPIPE; a child should not inherit that), nothing blocked.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            NSLog("[StreamingCommand] Could not start \(executable): \(String(cString: strerror(spawned)))")
            return nil
        }

        let exit = ExitBox()
        let exited = DispatchSemaphore(value: 0)
        let processGroup = pid
        cancellation.onCancel {
            guard exit.status == nil else { return }
            kill(-processGroup, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) {
                if exit.status == nil { kill(-processGroup, SIGKILL) }
            }
        }

        let waiter = Thread {
            var status: Int32 = 0
            while waitpid(processGroup, &status, 0) == -1 && errno == EINTR {}
            let signal = status & 0x7F
            exit.status = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
            exited.signal()
        }
        waiter.start()

        // Read until every writer has closed the pipe. A process the command left behind could keep it open for good,
        // so once the command itself has exited, reading stops after a short grace period.
        var collected = Data()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var exitedAt: Date?
        while true {
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready > 0 {
                let count = read(readEnd, &buffer, buffer.count)
                if count > 0 {
                    pending.append(contentsOf: buffer[0..<count])
                    if let chunk = takeCompleteText(&pending) {
                        collected.append(Data(chunk.utf8))
                        onOutput(chunk)
                    }
                    continue
                }
                if count == 0 { break }
                if errno == EINTR || errno == EAGAIN { continue }
                break
            } else if ready < 0 && errno != EINTR {
                break
            }
            if exit.status != nil {
                if exitedAt == nil { exitedAt = Date() }
                if let exitedAt, Date().timeIntervalSince(exitedAt) > 2 { break }
            }
        }
        close(readEnd)
        if !pending.isEmpty {
            let rest = String(decoding: pending, as: UTF8.self)
            collected.append(Data(rest.utf8))
            onOutput(rest)
        }
        exited.wait()

        return SystemCommandResult(status: exit.status ?? -1, output: String(decoding: collected, as: UTF8.self))
    }

    /// Takes the bytes up to the last line break (or everything once a lot has piled up without one) and decodes
    /// them, leaving a partial line, and any partial UTF-8 character, for the next read.
    static func takeCompleteText(_ pending: inout Data) -> String? {
        let newline: UInt8 = 0x0A, carriageReturn: UInt8 = 0x0D
        var cut: Data.Index?
        if let index = pending.lastIndex(where: { $0 == newline || $0 == carriageReturn }) {
            cut = pending.index(after: index)
        } else if pending.count >= 4_096 {
            // Back up to the start of a UTF-8 character.
            var index = pending.endIndex
            while index > pending.startIndex, (pending[pending.index(before: index)] & 0xC0) == 0x80 {
                index = pending.index(before: index)
            }
            if index > pending.startIndex { index = pending.index(before: index) }
            cut = index > pending.startIndex ? index : pending.endIndex
        }
        guard let cut else { return nil }
        let chunk = pending[pending.startIndex..<cut]
        pending = Data(pending[cut...])
        return String(decoding: chunk, as: UTF8.self)
    }
}
