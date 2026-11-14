import Foundation

/// A command in the queue and how it ended.
public struct HomebrewJob: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case pending, running, succeeded
        case failed(HomebrewFailure)
    }

    public let id: UUID
    public let operation: HomebrewOperation
    public internal(set) var state: State

    public init(id: UUID = UUID(), operation: HomebrewOperation, state: State = .pending) {
        self.id = id
        self.operation = operation
        self.state = state
    }

    public var isFinished: Bool {
        switch state {
        case .pending, .running: return false
        case .succeeded, .failed: return true
        }
    }

    public var failure: HomebrewFailure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }
}

/// What a confirmation dialog says before Zenith removes or upgrades packages.
public struct HomebrewConfirmation: Sendable, Equatable {
    public let title: String
    public let message: String
    public let actionTitle: String
}

/// The Homebrew manager: finds `brew`, lists what is installed and outdated, searches, and runs install / uninstall /
/// upgrade / update one at a time, streaming the output into a log.
///
/// Reading (`info`, `outdated`, `search`) goes through `readRunner`; changing goes through `streamRunner` and the queue.
/// Both get `/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 … brew …`, never a shell. Tests pass fakes for both, so nothing
/// here ever runs the real brew in a test.
@MainActor
public final class HomebrewManagerModel: ObservableObject {
    public static let shared = HomebrewManagerModel()

    public enum Availability: Sendable, Equatable {
        case unknown
        case missing
        case available(brewPath: String)
    }

    @Published public private(set) var availability: Availability = .unknown
    @Published public private(set) var installed: [HomebrewPackage] = []
    @Published public private(set) var outdated: [HomebrewOutdatedPackage] = []
    @Published public private(set) var searchResults: [HomebrewPackage] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSearching = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var hasSearched = false
    @Published public private(set) var refreshError: String?
    @Published public private(set) var searchError: String?
    /// Pending, running, and the last few finished commands, oldest first.
    @Published public private(set) var jobs: [HomebrewJob] = []
    @Published public private(set) var log = HomebrewLog()
    /// What the search field holds (kept here so it survives switching Settings tabs).
    @Published public var searchQuery = ""

    private let locator: HomebrewLocator
    private let readRunner: SystemCommandRunner
    private let streamRunner: StreamingCommandRunner
    private let sizeOf: @Sendable (String) -> Int64?
    private let now: @Sendable () -> Date

    private var queueTask: Task<Void, Never>?
    private var runningCancellation: CommandCancellation?
    private var lastOutdatedCheck: Date?
    /// Finished jobs kept for the activity list.
    static let finishedJobsKept = 5
    /// Per kind; a search for "a" would otherwise ask `brew info` about thousands of names.
    static let searchResultLimit = 30

    public init(
        locator: HomebrewLocator = HomebrewLocator(),
        readRunner: @escaping SystemCommandRunner = SystemCommand.processRunner,
        streamRunner: @escaping StreamingCommandRunner = StreamingCommand.processRunner,
        sizeOf: @escaping @Sendable (String) -> Int64? = HomebrewManagerModel.allocatedSize(atPath:),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.readRunner = readRunner
        self.streamRunner = streamRunner
        self.sizeOf = sizeOf
        self.now = now
    }

    // MARK: Finding brew

    public var brewPath: String? {
        if case .available(let path) = availability { return path }
        return nil
    }

    /// Looks for brew again (after the user installed it, say).
    @discardableResult
    public func locate() -> String? {
        let path = locator.locate()
        availability = path.map { .available(brewPath: $0) } ?? .missing
        return path
    }

    // MARK: Reading

    public var outdatedFormulae: [HomebrewOutdatedPackage] { outdated.filter { $0.kind == .formula } }
    public var outdatedCasks: [HomebrewOutdatedPackage] { outdated.filter { $0.kind == .cask } }
    /// Pinned formulae are left alone by `brew upgrade`, so they are not offered.
    public var upgradable: [HomebrewOutdatedPackage] { outdated.filter { !$0.isPinned } }

    public func outdatedEntry(for package: HomebrewPackage) -> HomebrewOutdatedPackage? {
        outdated.first { $0.kind == package.kind && ($0.name == package.name || $0.name == package.displayName) }
    }

    /// Lists installed and outdated packages, then measures the installed ones in the background.
    public func refresh() async {
        guard let brew = brewPath ?? locate(), !isRefreshing else { return }
        isRefreshing = true
        refreshError = nil
        let prefix = HomebrewLocator.prefix(forBrewAt: brew)

        async let installedResult = read(brew: brew, ["info", "--json=v2", "--installed"])
        async let outdatedResult = read(brew: brew, ["outdated", "--json=v2"])
        let (info, outdatedOutput) = await (installedResult, outdatedResult)

        if let info, info.status == 0, let packages = try? HomebrewJSON.packages(from: Data(info.output.utf8), prefix: prefix) {
            // Sizes measured before are kept for packages whose version did not change.
            let sizes = Dictionary(installed.compactMap { package in package.bytes.map { ("\(package.id)@\(package.version)", $0) } }, uniquingKeysWith: { first, _ in first })
            installed = packages.sorted(by: Self.listOrder).map { package in
                var package = package
                package.bytes = sizes["\(package.id)@\(package.version)"]
                return package
            }
        } else {
            refreshError = Self.readFailureMessage(info)
        }
        if let outdatedOutput, outdatedOutput.status == 0, let entries = try? HomebrewJSON.outdated(from: Data(outdatedOutput.output.utf8)) {
            outdated = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastOutdatedCheck = now()
        } else if refreshError == nil {
            refreshError = Self.readFailureMessage(outdatedOutput)
        }
        hasLoaded = true
        isRefreshing = false
        await measureSizes()
    }

    /// Only `brew outdated` (fast), and only when the last check is older than `maxAge`: for the Command Hub.
    public func refreshOutdated(ifOlderThan maxAge: TimeInterval) async {
        if let last = lastOutdatedCheck, now().timeIntervalSince(last) < maxAge { return }
        guard let brew = brewPath ?? locate(), !isRefreshing else { return }
        lastOutdatedCheck = now()
        guard let result = await read(brew: brew, ["outdated", "--json=v2"]), result.status == 0,
              let entries = try? HomebrewJSON.outdated(from: Data(result.output.utf8)) else { return }
        outdated = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func measureSizes() async {
        let toMeasure = installed.filter { $0.bytes == nil }.compactMap { package in package.sizePath.map { (package.id, $0) } }
        guard !toMeasure.isEmpty else { return }
        let sizeOf = self.sizeOf
        let sizes = await Task.detached(priority: .utility) {
            Dictionary(toMeasure.compactMap { id, path in sizeOf(path).map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        }.value
        installed = installed.map { package in
            var package = package
            if package.bytes == nil { package.bytes = sizes[package.id] }
            return package
        }
    }

    /// Searches formulae and casks by name, then asks `brew info` for their description and version.
    public func search() async {
        guard let query = HomebrewCommand.normalizedQuery(searchQuery) else {
            searchResults = []
            hasSearched = false
            return
        }
        guard let brew = brewPath ?? locate(), !isSearching else { return }
        isSearching = true
        searchError = nil
        defer {
            isSearching = false
            hasSearched = true
        }

        async let formulaSearch = read(brew: brew, ["search", "--formula", query])
        async let caskSearch = read(brew: brew, ["search", "--cask", query])
        let (formulaOutput, caskOutput) = await (formulaSearch, caskSearch)
        if formulaOutput == nil && caskOutput == nil {
            searchError = HomebrewFailure.couldNotStart.message
            searchResults = []
            return
        }
        // brew exits 1 with "No formulae or casks found" when nothing matches; that is just an empty list.
        let formulaNames = Self.ranked(HomebrewJSON.searchNames(from: formulaOutput?.output ?? ""), for: query)
        let caskNames = Self.ranked(HomebrewJSON.searchNames(from: caskOutput?.output ?? ""), for: query)

        var results: [HomebrewPackage] = []
        for (kind, names) in [(HomebrewPackageKind.formula, formulaNames), (.cask, caskNames)] where !names.isEmpty {
            let chosen = Array(names.prefix(Self.searchResultLimit))
            let info = await read(brew: brew, ["info", "--json=v2", kind.flag] + chosen)
            let described = info.flatMap { $0.status == 0 ? try? HomebrewJSON.packages(from: Data($0.output.utf8)) : nil } ?? []
            let byName = Dictionary(described.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            results += chosen.map { name in
                byName[name] ?? HomebrewPackage(name: name, kind: kind, version: "", isInstalled: isInstalled(name, kind: kind))
            }
        }
        searchResults = results
    }

    public func isInstalled(_ name: String, kind: HomebrewPackageKind) -> Bool {
        installed.contains { $0.kind == kind && ($0.name == name || $0.displayName == name) }
    }

    /// Exact match first, then names starting with the query, then the rest, each alphabetically.
    static func ranked(_ names: [String], for query: String) -> [String] {
        let lower = query.lowercased()
        func rank(_ name: String) -> Int {
            let short = name.split(separator: "/").last.map(String.init)?.lowercased() ?? name.lowercased()
            if short == lower { return 0 }
            if short.hasPrefix(lower) { return 1 }
            return 2
        }
        return names.sorted { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            return left != right ? left < right : lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func listOrder(_ lhs: HomebrewPackage, _ rhs: HomebrewPackage) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static func readFailureMessage(_ result: SystemCommandResult?) -> String {
        guard let result else { return HomebrewFailure.couldNotStart.message }
        let detail = HomebrewFailure.errorLine(in: result.errorOutput.isEmpty ? result.output : result.errorOutput)
        return detail.isEmpty ? String(localized: "Homebrew did not answer as expected.") : detail
    }

    private func read(brew: String, _ arguments: [String]) async -> SystemCommandResult? {
        let invocation = HomebrewCommand.invocation(brew: brew, arguments: arguments)
        let runner = readRunner
        return await Task.detached(priority: .userInitiated) {
            runner(invocation.executable, invocation.arguments)
        }.value
    }

    // MARK: Changing (confirmed where it removes or changes many things)

    public func install(_ package: HomebrewPackage) {
        enqueue(.install(name: package.name, kind: package.kind))
    }

    public func upgrade(_ package: HomebrewOutdatedPackage) {
        enqueue(.upgrade(names: [package.name], kind: package.kind))
    }

    public func update() {
        enqueue(.update)
    }

    public func uninstallConfirmation(for package: HomebrewPackage) -> HomebrewConfirmation {
        HomebrewConfirmation(
            title: String(localized: "Uninstall \(package.displayName)?"),
            message: package.kind == .cask
                ? String(localized: "Homebrew removes the app \(package.displayName) (\(package.name)). Its settings and data in your Library stay.")
                : String(localized: "Homebrew removes \(package.name) \(package.version). Other packages that need it will stop working."),
            actionTitle: String(localized: "Uninstall")
        )
    }

    /// Uninstalls after `confirm` agrees; returns whether it was queued.
    @discardableResult
    public func uninstall(_ package: HomebrewPackage, confirm: @MainActor (HomebrewConfirmation) -> Bool) -> Bool {
        guard confirm(uninstallConfirmation(for: package)) else { return false }
        return enqueue(.uninstall(name: package.name, kind: package.kind))
    }

    public func upgradeAllConfirmation(limit: Int = 12) -> HomebrewConfirmation {
        let chosen = upgradable
        var lines = chosen.prefix(limit).map { "• \($0.name) \($0.installedVersion) → \($0.currentVersion)" }
        if chosen.count > limit { lines.append(String(localized: "…and \(chosen.count - limit) more")) }
        return HomebrewConfirmation(
            title: chosen.count == 1
                ? String(localized: "Upgrade 1 package?")
                : String(localized: "Upgrade \(chosen.count) packages?"),
            message: String(localized: "Homebrew upgrades these, one command at a time:\n\(lines.joined(separator: "\n"))"),
            actionTitle: String(localized: "Upgrade All")
        )
    }

    /// Upgrades exactly the outdated packages listed in the confirmation (formulae, then casks).
    @discardableResult
    public func upgradeAll(confirm: @MainActor (HomebrewConfirmation) -> Bool) -> Bool {
        let chosen = upgradable
        guard !chosen.isEmpty, confirm(upgradeAllConfirmation()) else { return false }
        var queued = false
        for kind in HomebrewPackageKind.allCases {
            let names = chosen.filter { $0.kind == kind }.map(\.name)
            if !names.isEmpty, enqueue(.upgrade(names: names, kind: kind)) { queued = true }
        }
        return queued
    }

    // MARK: The queue

    public var currentJob: HomebrewJob? { jobs.first { $0.state == .running } }
    public var pendingJobs: [HomebrewJob] { jobs.filter { $0.state == .pending } }
    public var isBusy: Bool { jobs.contains { !$0.isFinished } }

    /// Whether this exact command is already waiting or running (a second click should not queue it twice).
    public func isQueued(_ operation: HomebrewOperation) -> Bool {
        jobs.contains { !$0.isFinished && $0.operation == operation }
    }

    /// Adds a command to the queue and starts the queue if it is idle. Refused when brew is missing, a name is not
    /// valid, or the same command is already queued.
    @discardableResult
    public func enqueue(_ operation: HomebrewOperation) -> Bool {
        guard brewPath != nil, operation.hasValidNames, !isQueued(operation) else { return false }
        jobs.append(HomebrewJob(operation: operation))
        if queueTask == nil {
            queueTask = Task { [weak self] in
                await self?.drainQueue()
            }
        }
        return true
    }

    /// Stops the running command (its whole process group) or drops a pending one.
    public func cancel(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].state {
        case .running:
            runningCancellation?.cancel()
        case .pending:
            jobs.remove(at: index)
        case .succeeded, .failed:
            break
        }
    }

    public func clearLog() {
        log.clear()
    }

    /// Waits until the queue has nothing left to run (for tests, and for callers that need the final state).
    public func waitUntilIdle() async {
        while let task = queueTask {
            await task.value
        }
    }

    private func drainQueue() async {
        while let index = jobs.firstIndex(where: { $0.state == .pending }), let brew = brewPath {
            jobs[index].state = .running
            let job = jobs[index]
            let state = await run(job.operation, brew: brew)
            if let finished = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[finished].state = state
            }
            trimFinishedJobs()
            await refresh()
        }
        queueTask = nil
    }

    private func run(_ operation: HomebrewOperation, brew: String) async -> HomebrewJob.State {
        let cancellation = CommandCancellation()
        runningCancellation = cancellation
        defer { runningCancellation = nil }

        let invocation = HomebrewCommand.invocation(brew: brew, arguments: operation.arguments)
        log.appendCommandLine(HomebrewCommand.terminalCommand(brew: "brew", arguments: operation.arguments))

        var continuation: AsyncStream<String>.Continuation?
        let output = AsyncStream<String>(bufferingPolicy: .unbounded) { continuation = $0 }
        let sink = continuation
        let runner = streamRunner
        let process = Task.detached(priority: .userInitiated) { () -> SystemCommandResult? in
            let result = await runner(invocation.executable, invocation.arguments, cancellation) { chunk in
                sink?.yield(chunk)
            }
            sink?.finish()
            return result
        }
        for await chunk in output {
            log.append(chunk)
        }
        let result = await process.value

        let failure = HomebrewFailure.classify(
            status: result?.status,
            output: result?.output ?? "",
            wasCancelled: cancellation.isCancelled,
            operation: operation,
            brew: brew
        )
        if let failure {
            log.append("\(failure.message)\n")
            return .failed(failure)
        }
        return .succeeded
    }

    private func trimFinishedJobs() {
        let finished = jobs.filter(\.isFinished)
        guard finished.count > Self.finishedJobsKept else { return }
        let dropped = Set(finished.prefix(finished.count - Self.finishedJobsKept).map(\.id))
        jobs.removeAll { dropped.contains($0.id) }
    }

    // MARK: Sizes

    /// Disk space a folder or app takes, hidden files and package contents included.
    public nonisolated static func allocatedSize(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: path),
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
