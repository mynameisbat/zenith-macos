import Foundation

/// Adds up one tool's parsed records: tokens per day and per session, the model, the plan limits, and whether each
/// session's turn is going on. A plain value type with no clock of its own: every question takes `now`.
public struct AIAgentUsageLedger: Sendable {
    /// A turn whose log has been quiet this long is taken as over (the process was killed, or the user walked
    /// away from a question), so the island never says "Working" forever.
    public static let defaultStaleAfter: TimeInterval = 10 * 60

    struct Session: Sendable {
        var id: String
        var projectPath: String?
        var model: String?
        var firstActivity: Date?
        var lastActivity: Date?
        var turnOpen = false
        var turnStartedAt: Date?
        var lastEndedAt: Date?
        var usage = AIAgentTokenUsage.zero
        /// The running total last reported, for tools that report totals.
        var lastCumulative: AIAgentTokenUsage?
        /// Tokens per local day (keyed by the day's start).
        var usageByDay: [Date: AIAgentTokenUsage] = [:]
    }

    public let kind: AIAgentKind
    public var staleAfter: TimeInterval
    public var calendar: Calendar
    private(set) var sessions: [String: Session] = [:]
    private(set) var rateLimits: [AIAgentRateLimit] = []
    private var rateLimitsObservedAt: Date?
    /// Recently counted reply ids. A reply's lines are written one after another, so a short memory is enough.
    private var recentUsageKeys: [String] = []
    private var recentUsageKeySet: Set<String> = []
    private static let usageKeyMemory = 256

    public init(kind: AIAgentKind, staleAfter: TimeInterval = AIAgentUsageLedger.defaultStaleAfter, calendar: Calendar = .current) {
        self.kind = kind
        self.staleAfter = staleAfter
        self.calendar = calendar
    }

    /// Adds one record. `fallbackSessionID` names the session when the line itself does not (the file it came from).
    public mutating func apply(_ record: AIAgentLogRecord, fallbackSessionID: String, fallbackTimestamp: Date? = nil) {
        let id = record.sessionID ?? fallbackSessionID
        var session = sessions[id] ?? Session(id: id)
        let time = record.timestamp ?? fallbackTimestamp

        if let path = record.projectPath { session.projectPath = path }
        if let model = record.model { session.model = model }
        if let time {
            if session.firstActivity == nil || time < session.firstActivity! { session.firstActivity = time }
            if session.lastActivity == nil || time > session.lastActivity! { session.lastActivity = time }
        }

        if let usage = record.usage, !usage.isZero, !isDuplicate(record.usageKey) {
            add(usage, to: &session, at: time)
        }
        if let total = record.cumulativeUsage {
            let added = total.added(since: session.lastCumulative ?? .zero)
            session.lastCumulative = total
            if !added.isZero { add(added, to: &session, at: time) }
        }
        if let limits = record.rateLimits, !limits.isEmpty {
            // Lines are read in order, but two files can interleave: keep the newest report.
            if rateLimitsObservedAt == nil || time == nil || time! >= rateLimitsObservedAt! {
                rateLimits = limits
                rateLimitsObservedAt = time ?? rateLimitsObservedAt
            }
        }

        switch record.turn {
        case .active?:
            if !session.turnOpen {
                session.turnOpen = true
                session.turnStartedAt = time
            }
        case .ended?:
            session.turnOpen = false
            if let time { session.lastEndedAt = time }
        case nil:
            break
        }
        sessions[id] = session
    }

    private mutating func add(_ usage: AIAgentTokenUsage, to session: inout Session, at time: Date?) {
        session.usage += usage
        if let time {
            session.usageByDay[calendar.startOfDay(for: time), default: .zero] += usage
        }
    }

    private mutating func isDuplicate(_ key: String?) -> Bool {
        guard let key else { return false }
        if recentUsageKeySet.contains(key) { return true }
        recentUsageKeys.append(key)
        recentUsageKeySet.insert(key)
        if recentUsageKeys.count > Self.usageKeyMemory {
            recentUsageKeySet.remove(recentUsageKeys.removeFirst())
        }
        return false
    }

    /// Forgets sessions with nothing since before yesterday, so a long-running app does not keep every session.
    public mutating func prune(now: Date) {
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(-86_400)
        sessions = sessions.filter { ($0.value.lastActivity ?? .distantPast) >= cutoff }
    }

    /// Whether a session is at work at `now`. `override` is what the tool itself says, when it says anything.
    func isWorking(_ session: Session, now: Date, override: Bool?) -> Bool {
        if let override { return override }
        guard session.turnOpen, let last = session.lastActivity else { return false }
        return now.timeIntervalSince(last) < staleAfter
    }

    /// Per-session state for the "finished" notices.
    public func activities(now: Date, workingOverrides: [String: Bool] = [:]) -> [AIAgentSessionActivity] {
        sessions.values.map { session in
            let working = isWorking(session, now: now, override: workingOverrides[session.id])
            return AIAgentSessionActivity(
                kind: kind,
                sessionID: session.id,
                projectName: Self.folderName(session.projectPath),
                isWorking: working,
                workingSince: session.turnStartedAt ?? (working ? session.lastActivity : nil),
                endedAt: session.turnOpen ? nil : session.lastEndedAt
            )
        }
    }

    /// The tool as the island shows it: today's tokens across sessions, and the working session's (else the most
    /// recent one's) project, model and tokens.
    public func snapshot(now: Date, workingOverrides: [String: Bool] = [:], tracksTokens: Bool = true) -> AIAgentSnapshot {
        let today = calendar.startOfDay(for: now)
        let all = Array(sessions.values)
        let working = all.filter { isWorking($0, now: now, override: workingOverrides[$0.id]) }
        let byRecency: (Session, Session) -> Bool = { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        let current = working.max(by: byRecency) ?? all.max(by: byRecency)

        var todayUsage = AIAgentTokenUsage.zero
        var sessionsToday = 0
        for session in all {
            if let usage = session.usageByDay[today] { todayUsage += usage }
            if let last = session.lastActivity, calendar.isDate(last, inSameDayAs: now) { sessionsToday += 1 }
        }

        return AIAgentSnapshot(
            kind: kind,
            isWorking: !working.isEmpty,
            projectName: Self.folderName(current?.projectPath),
            model: current?.model ?? all.filter { $0.model != nil }.max(by: byRecency)?.model,
            workingSince: current.flatMap { session in
                working.isEmpty ? nil : (session.turnStartedAt ?? session.lastActivity)
            },
            lastActivity: all.compactMap(\.lastActivity).max(),
            todayUsage: tracksTokens ? todayUsage : nil,
            sessionUsage: tracksTokens ? current?.usage : nil,
            rateLimits: rateLimits,
            sessionsToday: sessionsToday
        )
    }

    /// The last path component only: the island never shows where a project lives.
    static func folderName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name: String
        if let url = URL(string: path), url.scheme == "file" {
            name = url.lastPathComponent
        } else {
            name = (path as NSString).lastPathComponent
        }
        return name.isEmpty || name == "/" ? nil : name
    }
}
