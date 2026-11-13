import Foundation
import Combine
import Darwin

/// Where a stop request for one process stands.
public enum PortStopState: Sendable, Hashable {
    /// SIGTERM was sent; waiting for the process to exit.
    case stopping
    /// It did not exit within the grace period; Force Quit is offered.
    case stillRunning
    /// SIGKILL was sent; waiting for it to disappear.
    case forceQuitting
    /// The signal could not be sent, or the process outlived even SIGKILL.
    case failed(String)
}

/// The result of `stop` / `forceQuit`.
public enum PortStopOutcome: Sendable, Hashable {
    case cancelled
    case refused(PortStopRefusal)
    case stopped
    case stillRunning
    case failed(String)
}

/// The port manager: the listening sockets of this user's processes, a search over them, and stopping the process
/// behind one. Shared by the Command Hub and Settings → Ports. It never polls: the views call `refresh()` when they
/// appear and when the user asks.
@MainActor
public final class PortManagerModel: ObservableObject {
    public static let shared = PortManagerModel()

    @Published public private(set) var ports: [ListeningPort] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var hasLoaded = false
    /// Set when `lsof` could not be run or failed; already in the user's language.
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var stopStates: [Int32: PortStopState] = [:]
    @Published public var searchText = ""
    @Published public var includesUDP = false {
        didSet { if includesUDP != oldValue { refresh() } }
    }

    private let runner: SystemCommandRunner
    private let control: ProcessControlling
    private let currentUID: UInt32
    private let ownPID: Int32
    private let sleep: @Sendable (Double) async -> Void
    /// How long a process gets to quit after SIGTERM before Force Quit is offered.
    public let gracePeriod: Double
    private static let pollInterval = 0.25
    private var refreshGeneration = 0
    /// Set by `pin(_:)`: the list is made up and must never be replaced by this Mac's real one.
    public private(set) var isPinned = false

    public init(
        runner: @escaping SystemCommandRunner = SystemCommand.processRunner,
        control: ProcessControlling = SystemProcessControl(),
        currentUID: UInt32 = getuid(),
        ownPID: Int32 = getpid(),
        gracePeriod: Double = 3,
        sleep: @escaping @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.runner = runner
        self.control = control
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.gracePeriod = gracePeriod
        self.sleep = sleep
    }

    // MARK: - Listing

    /// Reads the list again in the background.
    public func refresh() {
        Task { await refreshNow() }
    }

    /// Reads the list again and returns once it is shown.
    public func refreshNow() async {
        guard !isPinned else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let includeUDP = includesUDP
        let runner = self.runner
        let control = self.control
        let result = await Task.detached(priority: .userInitiated) {
            PortLister.list(includeUDP: includeUDP, runner: runner, control: control)
        }.value
        // A newer refresh (the UDP switch flipped meanwhile) wins.
        guard generation == refreshGeneration else { return }
        isRefreshing = false
        hasLoaded = true
        switch result {
        case .success(let list):
            ports = list
            errorMessage = nil
            // Forget the stop state of processes that are gone.
            let live = Set(list.map(\.pid))
            stopStates = stopStates.filter { live.contains($0.key) }
        case .failure(.couldNotRun):
            ports = []
            errorMessage = String(localized: "Zenith could not run lsof to list the ports.")
        case .failure(.failed(let message)):
            ports = []
            errorMessage = message
        }
    }

    /// The ports matching `searchText`.
    public var filteredPorts: [ListeningPort] {
        Self.filter(ports, query: searchText)
    }

    /// Matches a port number (a leading `:` is allowed, so ":3000" works), a PID, a process name or a user name.
    nonisolated public static func filter(_ ports: [ListeningPort], query: String) -> [ListeningPort] {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(":") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return ports }
        let isNumber = trimmed.allSatisfy(\.isNumber)
        return ports.filter { entry in
            if isNumber {
                return String(entry.port).hasPrefix(trimmed) || String(entry.pid) == trimmed
            }
            return entry.processName.lowercased().contains(trimmed)
                || (entry.user?.lowercased().contains(trimmed) ?? false)
                || entry.proto.rawValue.lowercased() == trimmed
        }
    }

    // MARK: - Safety

    /// Why the process behind `entry` must not be stopped, or `nil` when the Stop button may be offered.
    public func refusal(for entry: ListeningPort) -> PortStopRefusal? {
        PortProcessSafety.refusal(pid: entry.pid, identity: entry.identity, currentUID: currentUID, ownPID: ownPID)
    }

    /// What the confirmation says before SIGTERM.
    public func stopConfirmation(for entry: ListeningPort) -> (title: String, message: String, actionTitle: String) {
        let others = ports.filter { $0.pid == entry.pid && $0.id != entry.id }.count
        let message: String
        if others == 0 {
            message = String(localized: "Zenith will ask \(entry.processName) (PID \(String(entry.pid))) to quit, which closes port \(String(entry.port)). Anything in it that is not saved may be lost.")
        } else {
            message = String(localized: "Zenith will ask \(entry.processName) (PID \(String(entry.pid))) to quit, which closes port \(String(entry.port)) and the other ports it holds. Anything in it that is not saved may be lost.")
        }
        return (
            title: String(localized: "Stop \(entry.processName) on port \(String(entry.port))?"),
            message: message,
            actionTitle: String(localized: "Stop")
        )
    }

    /// What the confirmation says before SIGKILL.
    public func forceQuitConfirmation(for entry: ListeningPort) -> (title: String, message: String, actionTitle: String) {
        (
            title: String(localized: "Force quit \(entry.processName)?"),
            message: String(localized: "\(entry.processName) (PID \(String(entry.pid))) is still running on port \(String(entry.port)). Force quitting ends it at once, without letting it save anything."),
            actionTitle: String(localized: "Force Quit")
        )
    }

    // MARK: - Stopping

    /// Asks `confirm` first, then sends SIGTERM and waits up to `gracePeriod` for the process to exit. Nothing is
    /// sent when the user declines, a safety rule refuses, or the PID now names a different process.
    @discardableResult
    public func stop(_ entry: ListeningPort, confirm: @MainActor (String, String, String) -> Bool) async -> PortStopOutcome {
        if let refusal = refusal(for: entry) { return .refused(refusal) }
        let text = stopConfirmation(for: entry)
        guard confirm(text.title, text.message, text.actionTitle) else { return .cancelled }
        return await signalAndWait(entry, signal: SIGTERM, state: .stopping, timeout: gracePeriod)
    }

    /// Offered after `stop` left the process running: asks `confirm`, then sends SIGKILL.
    @discardableResult
    public func forceQuit(_ entry: ListeningPort, confirm: @MainActor (String, String, String) -> Bool) async -> PortStopOutcome {
        if let refusal = refusal(for: entry) { return .refused(refusal) }
        let text = forceQuitConfirmation(for: entry)
        guard confirm(text.title, text.message, text.actionTitle) else { return .cancelled }
        let outcome = await signalAndWait(entry, signal: SIGKILL, state: .forceQuitting, timeout: 1)
        if outcome == .stillRunning {
            let message = String(localized: "\(entry.processName) did not quit.")
            stopStates[entry.pid] = .failed(message)
            return .failed(message)
        }
        return outcome
    }

    private func signalAndWait(_ entry: ListeningPort, signal: Int32, state: PortStopState, timeout: Double) async -> PortStopOutcome {
        // Read the process again: if the PID was reused, or it changed hands, do not touch it.
        guard let listed = entry.identity else { return .refused(.unknownProcess) }
        guard let current = control.identity(of: entry.pid), !current.isZombie else {
            stopStates[entry.pid] = nil
            await refreshNow()
            return .stopped
        }
        guard current.isSameProcess(as: listed) else { return .refused(.processChanged) }
        if let refusal = PortProcessSafety.refusal(pid: entry.pid, identity: current, currentUID: currentUID, ownPID: ownPID) {
            return .refused(refusal)
        }

        let error = control.send(signal, to: entry.pid)
        if error == ESRCH {
            stopStates[entry.pid] = nil
            await refreshNow()
            return .stopped
        }
        if error != 0 {
            let message = String(localized: "Could not stop \(entry.processName): \(String(cString: strerror(error)))")
            stopStates[entry.pid] = .failed(message)
            return .failed(message)
        }

        stopStates[entry.pid] = state
        var waited = 0.0
        while waited < timeout {
            await sleep(Self.pollInterval)
            waited += Self.pollInterval
            if !isStillRunning(entry.pid, as: listed) {
                stopStates[entry.pid] = nil
                await refreshNow()
                return .stopped
            }
        }
        stopStates[entry.pid] = .stillRunning
        return .stillRunning
    }

    private func isStillRunning(_ pid: Int32, as listed: ProcessIdentity) -> Bool {
        guard let now = control.identity(of: pid), !now.isZombie else { return false }
        return now.isSameProcess(as: listed)
    }

    /// For `--render-screenshots`: show these made-up ports from now on and never read the machine, so a published
    /// picture never lists this Mac's processes.
    public func pin(_ ports: [ListeningPort]) {
        isPinned = true
        refreshGeneration += 1
        self.ports = ports
        hasLoaded = true
        isRefreshing = false
        errorMessage = nil
    }
}
