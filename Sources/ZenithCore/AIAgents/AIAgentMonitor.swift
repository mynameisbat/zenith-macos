import Foundation
import Combine

/// Watches the coding agents' local logs and puts what they hold on the island: whether one is working, today's and
/// the session's tokens, the model and plan limits, and a notice when a long piece of work ends.
///
/// All reading happens on one background queue, only after FSEvents reports a change (plus one look a minute while
/// an agent is working, to notice one that stopped writing). Nothing is uploaded, and no prompt or reply text is
/// read: see the parsers.
@MainActor
public final class AIAgentMonitor: ObservableObject {
    public static let shared = AIAgentMonitor()

    /// Every tool that is switched on, installed or not.
    @Published public private(set) var snapshots: [AIAgentSnapshot] = []
    @Published public private(set) var isRunning = false

    /// Called with a long piece of work that just ended (the app shows it on the island or as a toast).
    public var onNotice: ((AIAgentNotice) -> Void)?
    public var notifiesWhenFinished = true
    public var longTaskThreshold: TimeInterval {
        get { tracker.threshold }
        set { tracker.threshold = newValue }
    }
    /// While an agent is working, look again this often even if nothing is written.
    public var recheckInterval: TimeInterval = 60

    private let worker = Worker()
    private let sourceFactory: (AIAgentKind) -> AIAgentSource
    private let watcherFactory: () -> AIAgentFileWatching
    private let now: @Sendable () -> Date
    private weak var island: ZenithIslandState?
    private var tracker = AIAgentActivityTracker()
    private var recheckTask: Task<Void, Never>?
    private var generation = 0
    private(set) var enabledKinds: [AIAgentKind] = []

    public init(
        sourceFactory: @escaping (AIAgentKind) -> AIAgentSource = AIAgentMonitor.liveSource,
        watcherFactory: @escaping () -> AIAgentFileWatching = { FSEventsFileWatcher() },
        now: @escaping @Sendable () -> Date = { Date() },
        island: ZenithIslandState? = .shared
    ) {
        self.sourceFactory = sourceFactory
        self.watcherFactory = watcherFactory
        self.now = now
        self.island = island
    }

    /// The real files in the user's home folder.
    nonisolated public static func liveSource(_ kind: AIAgentKind) -> AIAgentSource {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch kind {
        case .claudeCode: return JSONLinesAgentSource.claudeCode(home: home)
        case .codex: return JSONLinesAgentSource.codex(home: home)
        case .antigravity: return AntigravitySource(home: home)
        }
    }

    // MARK: - Start and stop

    /// Starts watching `kinds` (in the order of `AIAgentKind.allCases`), or changes the set while running.
    public func start(kinds: Set<AIAgentKind>) {
        let ordered = AIAgentKind.allCases.filter { kinds.contains($0) }
        guard !ordered.isEmpty else {
            stop()
            return
        }
        if isRunning, ordered == enabledKinds { return }
        for kind in enabledKinds where !ordered.contains(kind) { tracker.reset(kind: kind) }
        enabledKinds = ordered
        generation += 1
        isRunning = true
        island?.showsAIAgentsTab = true

        // Made here, then used only on the worker's queue.
        let handoff = Worker.Handoff(sources: ordered.map(sourceFactory), watcher: watcherFactory())
        let generation = generation
        let worker = worker
        let deliver: @Sendable (Worker.Pass) -> Void = { [weak self] pass in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(pass) }
            }
        }
        worker.queue.async { [worker] in
            worker.configure(sources: handoff.sources, watcher: handoff.watcher, generation: generation)
            worker.deliver = deliver
            worker.startWatching { [weak worker] changed in
                worker?.scheduleProcess(changed: changed)
            }
            worker.scheduleProcess(changed: nil)
        }
    }

    public func stop() {
        guard isRunning || !snapshots.isEmpty else { return }
        generation += 1
        isRunning = false
        for kind in enabledKinds { tracker.reset(kind: kind) }
        enabledKinds = []
        recheckTask?.cancel()
        recheckTask = nil
        let worker = worker
        worker.queue.async { worker.tearDown() }
        snapshots = []
        island?.aiAgents = []
        island?.showsAIAgentsTab = false
    }

    /// Looks at every file again (and watches folders that appeared since, e.g. a tool installed meanwhile).
    public func refresh() {
        guard isRunning else { return }
        let worker = worker
        worker.queue.async { [worker] in
            worker.startWatching { [weak worker] changed in worker?.scheduleProcess(changed: changed) }
            worker.scheduleProcess(changed: nil)
        }
    }

    /// Re-applies the clock to what is known, without reading anything (e.g. when the AI tab appears after midnight).
    public func recomputeNow() {
        guard isRunning else { return }
        let worker = worker
        worker.queue.async { worker.scheduleProcess(changed: []) }
    }

    /// Shows made-up `snapshots` without reading any file, for `--render-screenshots`. `stop()` clears them.
    public func pin(_ snapshots: [AIAgentSnapshot], now date: Date = Date()) {
        stop()
        self.snapshots = snapshots
        island?.aiAgents = snapshots.filter { $0.isShown(now: date) }
        island?.showsAIAgentsTab = true
    }

    // MARK: - Results

    private func apply(_ pass: Worker.Pass) {
        guard pass.generation == generation, isRunning else { return }
        snapshots = pass.snapshots
        let date = now()
        island?.aiAgents = pass.snapshots.filter { $0.isShown(now: date) }

        for (kind, activities) in pass.settledActivities {
            let notices = tracker.update(kind: kind, activities: activities, now: date)
            if notifiesWhenFinished {
                for notice in notices { onNotice?(notice) }
            }
        }
        scheduleRecheck(anyWorking: pass.snapshots.contains { $0.isWorking })
    }

    private func scheduleRecheck(anyWorking: Bool) {
        recheckTask?.cancel()
        recheckTask = nil
        guard anyWorking, recheckInterval > 0 else { return }
        let nanos = UInt64(recheckInterval * 1_000_000_000)
        recheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            self.recomputeNow()
        }
    }

    // MARK: - Tests

    /// Runs passes on the calling thread until every source has read all it has, then applies the result.
    /// For tests: production reads on the worker queue.
    func processSynchronously(changedPaths: [String]?) {
        var changed = changedPaths
        var pass: Worker.Pass?
        worker.queue.sync {
            repeat {
                pass = worker.runPass(changed: changed, now: now())
                changed = []
            } while pass?.hasMoreWork == true
        }
        if let pass { apply(pass) }
    }

    /// Simulates the watcher reporting `paths` and processes them on the calling thread. For tests.
    func simulateChange(_ paths: [String]?) {
        processSynchronously(changedPaths: paths)
    }

    /// Starts without the background queue's first pass, for tests that drive passes by hand.
    func startForTesting(kinds: Set<AIAgentKind>) {
        let ordered = AIAgentKind.allCases.filter { kinds.contains($0) }
        enabledKinds = ordered
        generation += 1
        isRunning = true
        island?.showsAIAgentsTab = true
        let sources = ordered.map(sourceFactory)
        let generation = generation
        worker.queue.sync {
            worker.configure(sources: sources, watcher: nil, generation: generation)
        }
    }

    // MARK: - Worker

    /// Everything that touches the disk. Used only on `queue`.
    final class Worker: @unchecked Sendable {
        struct Handoff: @unchecked Sendable {
            let sources: [AIAgentSource]
            let watcher: AIAgentFileWatching?
        }

        struct Pass: Sendable {
            let generation: Int
            let snapshots: [AIAgentSnapshot]
            /// Sessions of tools whose files are fully read (history still being read says nothing).
            let settledActivities: [(AIAgentKind, [AIAgentSessionActivity])]
            let hasMoreWork: Bool
        }

        let queue = DispatchQueue(label: "app.zenith.ai-agents", qos: .utility)
        var deliver: (@Sendable (Pass) -> Void)?
        private var sources: [AIAgentSource] = []
        private var unreadable: Set<AIAgentKind> = []
        private var watcher: AIAgentFileWatching?
        private var watchedPaths: [String] = []
        private var generation = 0
        private var isScheduled = false
        private var queuedChanges: [String]? = []

        func configure(sources: [AIAgentSource], watcher: AIAgentFileWatching?, generation: Int) {
            self.watcher?.stop()
            self.sources = sources
            self.watcher = watcher
            self.watchedPaths = []
            self.unreadable = []
            self.generation = generation
            self.queuedChanges = []
            self.isScheduled = false
        }

        func tearDown() {
            watcher?.stop()
            watcher = nil
            sources = []
            watchedPaths = []
            generation += 1
        }

        func startWatching(onChange: @escaping @Sendable ([String]?) -> Void) {
            let paths = Array(Set(sources.flatMap { $0.watchedPaths() })).sorted()
            guard paths != watchedPaths else { return }
            watchedPaths = paths
            watcher?.start(paths: paths, queue: queue, onChange: onChange)
        }

        /// Collects changes and runs one pass for all of them; FSEvents already coalesces, this joins what arrives
        /// while a pass is running.
        func scheduleProcess(changed: [String]?) {
            if let changed, queuedChanges != nil {
                queuedChanges?.append(contentsOf: changed)
            } else {
                queuedChanges = nil
            }
            guard !isScheduled else { return }
            isScheduled = true
            queue.async { [self] in
                isScheduled = false
                let changes = queuedChanges
                queuedChanges = []
                guard !sources.isEmpty else { return }
                let pass = runPass(changed: changes.map { Array(Set($0)) }, now: Date())
                deliver?(pass)
                if pass.hasMoreWork { scheduleProcess(changed: []) }
            }
        }

        func runPass(changed: [String]?, now: Date) -> Pass {
            var snapshots: [AIAgentSnapshot] = []
            var settled: [(AIAgentKind, [AIAgentSessionActivity])] = []
            var hasMore = false
            for source in sources {
                let kind = source.kind
                if unreadable.contains(kind) {
                    snapshots.append(AIAgentSnapshot(kind: kind, availability: .unreadable))
                    continue
                }
                guard source.isInstalled() else {
                    snapshots.append(AIAgentSnapshot(kind: kind, availability: .notInstalled))
                    continue
                }
                do {
                    let result = try source.update(changedPaths: changed, now: now)
                    snapshots.append(result.snapshot)
                    if result.hasMoreWork {
                        hasMore = true
                    } else {
                        settled.append((kind, result.activities))
                    }
                } catch {
                    // Only this tool stops; the others carry on.
                    unreadable.insert(kind)
                    snapshots.append(AIAgentSnapshot(kind: kind, availability: .unreadable))
                }
            }
            return Pass(generation: generation, snapshots: snapshots, settledActivities: settled, hasMoreWork: hasMore)
        }
    }
}
