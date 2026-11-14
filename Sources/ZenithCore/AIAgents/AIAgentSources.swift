import Foundation

/// One tool's local files. Every call comes from the monitor's own serial queue, never from two threads at once.
public protocol AIAgentSource: AnyObject {
    var kind: AIAgentKind { get }
    /// Whether the tool is on this Mac at all.
    func isInstalled() -> Bool
    /// Existing folders whose changes matter.
    func watchedPaths() -> [String]
    /// Reads what changed and returns the tool's state at `now`. `changedPaths` nil means look at everything (the
    /// first time, or after the watcher lost track); an empty list means nothing changed on disk, only time passed.
    /// Throws when the files are no longer in a format this parser understands.
    func update(changedPaths: [String]?, now: Date) throws -> AIAgentSourceResult
}

public struct AIAgentSourceResult: Sendable {
    public var snapshot: AIAgentSnapshot
    public var activities: [AIAgentSessionActivity]
    /// More bytes are waiting than one pass may read: call again.
    public var hasMoreWork: Bool

    public init(snapshot: AIAgentSnapshot, activities: [AIAgentSessionActivity], hasMoreWork: Bool) {
        self.snapshot = snapshot
        self.activities = activities
        self.hasMoreWork = hasMoreWork
    }
}

public enum AIAgentSourceError: Error, Equatable {
    /// Many lines in a row were not JSON: the tool changed its format (or the file is not a log).
    case unreadableFormat
    case unreadableDatabase(String)
    /// Locked, mid-write or not openable just now: try again on the next change. Never switches the tool off.
    case temporarilyUnavailable
}

// MARK: - Working status reported by the tool itself

/// What the tool says about its own sessions, when it says anything: session id → working.
public protocol AIAgentWorkingStatusProviding: AnyObject {
    func workingStatus() -> [String: Bool]
    var watchedPath: String? { get }
}

/// Claude Code keeps one small file per running process in `~/.claude/sessions/<pid>.json` with `pid`,
/// `sessionId` and `status` (`busy` / `idle`). A file whose process is gone is ignored. Only those three fields are
/// read.
public final class ClaudeCodeSessionRegistry: AIAgentWorkingStatusProviding {
    public let directory: URL
    private let isProcessAlive: (Int32) -> Bool

    public init(directory: URL, isProcessAlive: @escaping (Int32) -> Bool = ClaudeCodeSessionRegistry.processExists) {
        self.directory = directory
        self.isProcessAlive = isProcessAlive
    }

    public var watchedPath: String? { directory.path }

    /// Signal 0 checks that the process exists without sending anything.
    public static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func workingStatus() -> [String: Bool] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var result: [String: Bool] = [:]
        for name in names.prefix(200) where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count < 64 * 1_024,
                  let object = AIAgentJSON.object(data),
                  let sessionID = AIAgentJSON.string(object["sessionId"]),
                  let pid = AIAgentJSON.int(object["pid"]),
                  let status = object["status"] as? String else { continue }
            guard isProcessAlive(Int32(clamping: pid)) else { continue }
            switch status {
            case "busy": result[sessionID] = true
            case "idle": result[sessionID] = result[sessionID] ?? false
            default: continue
            }
        }
        return result
    }
}

// MARK: - JSON-lines logs (Claude Code, Codex)

/// A tool whose sessions are JSON-lines files under one or more folders.
public final class JSONLinesAgentSource: AIAgentSource {
    public enum SessionKey: Sendable {
        /// The id inside each line (Claude Code: a subagent's file adds to its parent session).
        case fromRecord
        /// One session per file (Codex names it once, in the first line).
        case perFile
    }

    public let kind: AIAgentKind
    public let roots: [URL]
    private let parser: AIAgentLineParsing
    private let sessionKey: SessionKey
    private let maxDepth: Int
    private let installMarkers: [URL]
    private let statusProvider: AIAgentWorkingStatusProviding?
    /// At most this many bytes are read per pass, so a day of logs is read over several short passes.
    public let maxBytesPerPass: Int
    /// After this many lines in a row that are not JSON, the format is taken to have changed.
    public static let malformedLineLimit = 50

    private var ledger: AIAgentUsageLedger
    private let tailer = AIAgentLogTailer()
    private var pendingFiles: [String] = []
    private var pendingSet: Set<String> = []
    private var consecutiveMalformed = 0
    private var hasScanned = false
    private var lastPrunedDay: Date?

    public init(
        kind: AIAgentKind,
        roots: [URL],
        parser: AIAgentLineParsing,
        sessionKey: SessionKey,
        maxDepth: Int,
        installMarkers: [URL] = [],
        statusProvider: AIAgentWorkingStatusProviding? = nil,
        maxBytesPerPass: Int = 4 * 1_024 * 1_024,
        staleAfter: TimeInterval = AIAgentUsageLedger.defaultStaleAfter,
        calendar: Calendar = .current
    ) {
        self.kind = kind
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.parser = parser
        self.sessionKey = sessionKey
        self.maxDepth = maxDepth
        self.installMarkers = installMarkers
        self.statusProvider = statusProvider
        self.maxBytesPerPass = maxBytesPerPass
        self.ledger = AIAgentUsageLedger(kind: kind, staleAfter: staleAfter, calendar: calendar)
    }

    public func isInstalled() -> Bool {
        let fileManager = FileManager.default
        return (roots + installMarkers).contains { fileManager.fileExists(atPath: $0.path) }
    }

    public func watchedPaths() -> [String] {
        let fileManager = FileManager.default
        var paths = roots.map(\.path).filter { fileManager.fileExists(atPath: $0) }
        if let status = statusProvider?.watchedPath, fileManager.fileExists(atPath: status) {
            paths.append(status)
        }
        return paths
    }

    public func update(changedPaths: [String]?, now: Date) throws -> AIAgentSourceResult {
        let since = ledger.calendar.startOfDay(for: now).addingTimeInterval(-12 * 3_600)
        if changedPaths == nil || !hasScanned {
            hasScanned = true
            for path in discoverLogs(modifiedSince: since) { enqueue(path) }
        }
        for path in changedPaths ?? [] {
            if path.hasSuffix(".jsonl") {
                if isUnderRoot(path) { enqueue(path) }
            } else if isUnderRoot(path) {
                // A folder changed as a whole (FSEvents could not name the files): look inside it.
                for log in discoverLogs(in: URL(fileURLWithPath: path), modifiedSince: since) { enqueue(log) }
            }
        }

        var budget = maxBytesPerPass
        var stillPending: [String] = []
        for path in pendingFiles {
            let (lines, more) = tailer.readNewLines(path: path, budget: &budget)
            let fileSession = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            for line in lines {
                switch parser.parse(line: line) {
                case .record(var record):
                    consecutiveMalformed = 0
                    if sessionKey == .perFile { record.sessionID = nil }
                    ledger.apply(record, fallbackSessionID: fileSession)
                case .ignored:
                    consecutiveMalformed = 0
                case .malformed:
                    consecutiveMalformed += 1
                    if consecutiveMalformed >= Self.malformedLineLimit {
                        throw AIAgentSourceError.unreadableFormat
                    }
                }
            }
            if more { stillPending.append(path) }
        }
        pendingFiles = stillPending
        pendingSet = Set(stillPending)

        let today = ledger.calendar.startOfDay(for: now)
        if lastPrunedDay != today {
            lastPrunedDay = today
            ledger.prune(now: now)
        }

        let overrides = statusProvider?.workingStatus() ?? [:]
        return AIAgentSourceResult(
            snapshot: ledger.snapshot(now: now, workingOverrides: overrides),
            activities: ledger.activities(now: now, workingOverrides: overrides),
            hasMoreWork: !pendingFiles.isEmpty
        )
    }

    private func enqueue(_ path: String) {
        guard !pendingSet.contains(path) else { return }
        pendingSet.insert(path)
        pendingFiles.append(path)
    }

    private func isUnderRoot(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { resolved == $0.path || resolved.hasPrefix($0.path + "/") }
    }

    /// Logs in every root changed since `date`, oldest first (so totals build up in order), at most 200.
    private func discoverLogs(modifiedSince date: Date) -> [String] {
        roots.flatMap { discoverLogs(in: $0, modifiedSince: date) }
    }

    private func discoverLogs(in folder: URL, modifiedSince date: Date) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return [] }
        let baseDepth = folder.standardizedFileURL.pathComponents.count
        var found: [(path: String, modified: Date)] = []
        for case let url as URL in enumerator {
            let depth = url.standardizedFileURL.pathComponents.count - baseDepth
            if depth >= maxDepth { enumerator.skipDescendants() }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= date else { continue }
            found.append((url.path, modified))
        }
        return found.sorted { $0.modified < $1.modified }.suffix(200).map(\.path)
    }
}

// MARK: - Factories

public extension JSONLinesAgentSource {
    /// Claude Code: `~/.claude/projects` (and `~/.config/claude/projects`, used by some versions), subagent logs one
    /// level further down, and the per-process status files in `~/.claude/sessions`.
    static func claudeCode(home: URL, isProcessAlive: @escaping (Int32) -> Bool = ClaudeCodeSessionRegistry.processExists) -> JSONLinesAgentSource {
        let claude = home.appendingPathComponent(".claude")
        return JSONLinesAgentSource(
            kind: .claudeCode,
            roots: [
                claude.appendingPathComponent("projects"),
                home.appendingPathComponent(".config/claude/projects")
            ],
            parser: ClaudeCodeLogParser(),
            sessionKey: .fromRecord,
            maxDepth: 4,
            installMarkers: [claude, home.appendingPathComponent(".local/bin/claude")],
            statusProvider: ClaudeCodeSessionRegistry(
                directory: claude.appendingPathComponent("sessions"), isProcessAlive: isProcessAlive
            )
        )
    }

    /// Codex CLI: `$CODEX_HOME/sessions` (default `~/.codex/sessions`), in `YYYY/MM/DD` folders.
    static func codex(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> JSONLinesAgentSource {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        return JSONLinesAgentSource(
            kind: .codex,
            roots: [codexHome.appendingPathComponent("sessions")],
            parser: CodexRolloutParser(),
            sessionKey: .perFile,
            maxDepth: 4,
            installMarkers: [codexHome]
        )
    }
}
