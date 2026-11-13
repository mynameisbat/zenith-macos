import Foundation

// MARK: - Tools

/// The coding agents whose local logs Zenith can read.
public enum AIAgentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case antigravity

    public var id: String { rawValue }

    /// Product names: not translated.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// A generic symbol, not the product's logo.
    public var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "terminal"
        case .antigravity: return "atom"
        }
    }
}

// MARK: - Tokens

/// Token counts as a tool's log records them. `cacheRead` and `cacheWrite` are input tokens served from, or written
/// to, the prompt cache; `input` is the rest of the input.
public struct AIAgentTokenUsage: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = AIAgentTokenUsage()

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var isZero: Bool { total == 0 }

    public static func + (lhs: AIAgentTokenUsage, rhs: AIAgentTokenUsage) -> AIAgentTokenUsage {
        AIAgentTokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func += (lhs: inout AIAgentTokenUsage, rhs: AIAgentTokenUsage) {
        lhs = lhs + rhs
    }

    /// What was added between two running totals, field by field. A field that went down (a log that was cut short
    /// and started again) adds nothing rather than a negative.
    public func added(since earlier: AIAgentTokenUsage) -> AIAgentTokenUsage {
        AIAgentTokenUsage(
            input: max(0, input - earlier.input),
            output: max(0, output - earlier.output),
            cacheRead: max(0, cacheRead - earlier.cacheRead),
            cacheWrite: max(0, cacheWrite - earlier.cacheWrite)
        )
    }

    /// "980", "12K", "1.2M", "3.4B", with the user's decimal separator.
    public static func compact(_ count: Int, locale: Locale = .current) -> String {
        let value = Double(max(0, count))
        let (scaled, suffix): (Double, String) = {
            switch value {
            case ..<1_000: return (value, "")
            case ..<1_000_000: return (value / 1_000, "K")
            case ..<1_000_000_000: return (value / 1_000_000, "M")
            default: return (value / 1_000_000_000, "B")
            }
        }()
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        // One decimal below 10 ("1.2M"), none above ("45M"), and never on plain counts.
        formatter.maximumFractionDigits = (suffix.isEmpty || scaled >= 10) ? 0 : 1
        formatter.roundingMode = .down
        let number = formatter.string(from: NSNumber(value: scaled)) ?? String(Int(scaled))
        return number + suffix
    }
}

// MARK: - Plan limits

/// One plan limit as the tool's own log reported it (Codex writes these; nothing is ever estimated).
public struct AIAgentRateLimit: Sendable, Equatable {
    /// How long the window is, in minutes (300 for the five-hour limit, 10 080 for the weekly one).
    public let windowMinutes: Int?
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(windowMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// "5h", "Weekly", "2h": short enough for the island.
    public var shortLabel: String {
        guard let minutes = windowMinutes, minutes > 0 else { return String(localized: "Limit") }
        if abs(minutes - 10_080) <= 60 { return String(localized: "Weekly") }
        if minutes >= 1_440, minutes % 1_440 <= 60 || 1_440 - minutes % 1_440 <= 60 {
            let days = Int((Double(minutes) / 1_440).rounded())
            return String(localized: "\(days)d")
        }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours >= 1 ? String(localized: "\(hours)h") : String(localized: "\(minutes) min")
    }

    /// "42%".
    public var percentText: String {
        "\(Int(min(max(usedPercent, 0), 100).rounded()))%"
    }

    /// "resets 15:00", "resets Mon 09:00", or nil when the log did not say.
    public func resetDescription(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(resetsAt, inSameDayAs: now) || resetsAt.timeIntervalSince(now) < 12 * 3_600 {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        }
        return String(localized: "resets \(formatter.string(from: resetsAt))")
    }
}

// MARK: - Parsed log lines

/// What a parser keeps from one log line. Prompt and response text never get this far: the parsers read only ids,
/// times, folder paths, model names, token counts, limits and whether a turn is going on.
public struct AIAgentLogRecord: Sendable, Equatable {
    /// Whether the line shows the agent at work, or the end of its turn.
    public enum Turn: Sendable, Equatable {
        case active
        case ended
    }

    public var timestamp: Date?
    public var sessionID: String?
    public var projectPath: String?
    public var model: String?
    /// Tokens this line adds (Claude Code reports each reply's usage).
    public var usage: AIAgentTokenUsage?
    /// The session's running total so far (Codex reports totals; the ledger takes the difference).
    public var cumulativeUsage: AIAgentTokenUsage?
    public var rateLimits: [AIAgentRateLimit]?
    public var turn: Turn?
    /// Identifies the reply `usage` belongs to: a reply written over several lines is counted once.
    public var usageKey: String?

    public init(
        timestamp: Date? = nil,
        sessionID: String? = nil,
        projectPath: String? = nil,
        model: String? = nil,
        usage: AIAgentTokenUsage? = nil,
        cumulativeUsage: AIAgentTokenUsage? = nil,
        rateLimits: [AIAgentRateLimit]? = nil,
        turn: Turn? = nil,
        usageKey: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.model = model
        self.usage = usage
        self.cumulativeUsage = cumulativeUsage
        self.rateLimits = rateLimits
        self.turn = turn
        self.usageKey = usageKey
    }
}

/// Turns one line of a tool's log into a record. Unknown fields and record types are ignored; a line that is not
/// valid JSON returns `.malformed`, so the source can tell a changed format from an odd line.
public protocol AIAgentLineParsing: Sendable {
    func parse(line: Data) -> AIAgentLineResult
}

public enum AIAgentLineResult: Sendable, Equatable {
    case record(AIAgentLogRecord)
    /// Valid JSON that carries nothing Zenith shows (titles, file snapshots, …).
    case ignored
    case malformed
}

// MARK: - What the island shows

/// One session's state, which `AIAgentActivityTracker` turns into "finished" notices.
public struct AIAgentSessionActivity: Sendable, Equatable {
    public let kind: AIAgentKind
    public let sessionID: String
    public let projectName: String?
    public let isWorking: Bool
    /// When the current (or last) stretch of work began.
    public let workingSince: Date?
    /// When the agent last ended its turn by itself; nil while working or when the log never said.
    public let endedAt: Date?

    public init(kind: AIAgentKind, sessionID: String, projectName: String?, isWorking: Bool, workingSince: Date?, endedAt: Date?) {
        self.kind = kind
        self.sessionID = sessionID
        self.projectName = projectName
        self.isWorking = isWorking
        self.workingSince = workingSince
        self.endedAt = endedAt
    }
}

/// One tool, as the island shows it. Every field is optional because each tool records different things: a value
/// the tool's files do not hold stays nil and is not shown.
public struct AIAgentSnapshot: Sendable, Equatable, Identifiable {
    public enum Availability: Sendable, Equatable {
        /// Found on this Mac and read.
        case available
        case notInstalled
        /// Its files could not be read the way Zenith expects (the format changed): this tool is left out until
        /// the feature is switched off and on again.
        case unreadable
    }

    public let kind: AIAgentKind
    public var availability: Availability
    public var isWorking: Bool
    /// The folder name of the working (or most recent) session's project, never a full path.
    public var projectName: String?
    public var model: String?
    public var workingSince: Date?
    public var lastActivity: Date?
    public var todayUsage: AIAgentTokenUsage?
    public var sessionUsage: AIAgentTokenUsage?
    public var rateLimits: [AIAgentRateLimit]
    /// How many sessions were active today.
    public var sessionsToday: Int

    public var id: AIAgentKind { kind }

    public init(
        kind: AIAgentKind,
        availability: Availability = .available,
        isWorking: Bool = false,
        projectName: String? = nil,
        model: String? = nil,
        workingSince: Date? = nil,
        lastActivity: Date? = nil,
        todayUsage: AIAgentTokenUsage? = nil,
        sessionUsage: AIAgentTokenUsage? = nil,
        rateLimits: [AIAgentRateLimit] = [],
        sessionsToday: Int = 0
    ) {
        self.kind = kind
        self.availability = availability
        self.isWorking = isWorking
        self.projectName = projectName
        self.model = model
        self.workingSince = workingSince
        self.lastActivity = lastActivity
        self.todayUsage = todayUsage
        self.sessionUsage = sessionUsage
        self.rateLimits = rateLimits
        self.sessionsToday = sessionsToday
    }

    /// Worth a card on the island: installed, readable and used today (or working now).
    public func isShown(now: Date, calendar: Calendar = .current) -> Bool {
        guard availability == .available else { return false }
        if isWorking { return true }
        guard let lastActivity else { return false }
        return calendar.isDate(lastActivity, inSameDayAs: now)
    }

    /// "Working · zenith-macos", "Idle · zenith-macos", "Idle".
    public var statusText: String {
        let state = isWorking ? String(localized: "Working") : String(localized: "Idle")
        guard let projectName, !projectName.isEmpty else { return state }
        return "\(state) · \(projectName)"
    }

    /// "Today 4.5M · Session 1.2M", only the parts the log recorded; nil when it recorded none.
    public var usageText: String? {
        var parts: [String] = []
        if let todayUsage, !todayUsage.isZero {
            parts.append(String(localized: "Today \(AIAgentTokenUsage.compact(todayUsage.total))"))
        }
        if let sessionUsage, !sessionUsage.isZero {
            parts.append(String(localized: "Session \(AIAgentTokenUsage.compact(sessionUsage.total))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "5h 42% · Weekly 12%", or nil without limits.
    public var limitsText: String? {
        guard !rateLimits.isEmpty else { return nil }
        return rateLimits.map { "\($0.shortLabel) \($0.percentText)" }.joined(separator: " · ")
    }

    /// Everything known, for VoiceOver and the tooltip: token parts, the model and each limit with its reset.
    public func detailText(now: Date) -> String {
        var lines: [String] = [statusText]
        if let model { lines.append(String(localized: "Model: \(model)")) }
        if let todayUsage, !todayUsage.isZero {
            lines.append(String(localized: "Today: \(Self.breakdown(todayUsage))"))
        }
        if let sessionUsage, !sessionUsage.isZero {
            lines.append(String(localized: "This session: \(Self.breakdown(sessionUsage))"))
        }
        for limit in rateLimits {
            if let reset = limit.resetDescription(now: now) {
                lines.append(String(localized: "\(limit.shortLabel) limit: \(limit.percentText) used, \(reset)"))
            } else {
                lines.append(String(localized: "\(limit.shortLabel) limit: \(limit.percentText) used"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "1.2M in, 45K out, 30M cache read, 2M cache write", leaving out what is zero.
    static func breakdown(_ usage: AIAgentTokenUsage) -> String {
        var parts: [String] = []
        if usage.input > 0 { parts.append(String(localized: "\(AIAgentTokenUsage.compact(usage.input)) in")) }
        if usage.output > 0 { parts.append(String(localized: "\(AIAgentTokenUsage.compact(usage.output)) out")) }
        if usage.cacheRead > 0 { parts.append(String(localized: "\(AIAgentTokenUsage.compact(usage.cacheRead)) cache read")) }
        if usage.cacheWrite > 0 { parts.append(String(localized: "\(AIAgentTokenUsage.compact(usage.cacheWrite)) cache write")) }
        return parts.joined(separator: ", ")
    }
}

/// A long piece of work that just ended.
public struct AIAgentNotice: Sendable, Equatable {
    public let kind: AIAgentKind
    public let projectName: String?
    public let duration: TimeInterval

    public init(kind: AIAgentKind, projectName: String?, duration: TimeInterval) {
        self.kind = kind
        self.projectName = projectName
        self.duration = duration
    }

    /// "Claude Code finished".
    public var title: String {
        String(localized: "\(kind.displayName) finished")
    }

    /// "zenith-macos · 12 min", "1 h 5 min".
    public var subtitle: String {
        let minutes = max(1, Int((duration / 60).rounded()))
        let length: String
        if minutes < 60 {
            length = String(localized: "\(minutes) min")
        } else {
            let hours = minutes / 60
            let rest = minutes % 60
            length = rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
        }
        guard let projectName, !projectName.isEmpty else { return length }
        return "\(projectName) · \(length)"
    }
}
