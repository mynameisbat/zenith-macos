import Foundation

/// Decides when to say "finished": a session that was working, then ended its turn by itself after working at least
/// `threshold`. A session that only went quiet (stale), work that ended long ago, and anything seen in the first
/// look at a tool (history read at start-up) say nothing.
public struct AIAgentActivityTracker: Sendable {
    public var threshold: TimeInterval
    /// An end older than this when Zenith learns of it is history, not news.
    public var recency: TimeInterval

    private var workingSince: [String: Date] = [:]
    private var primedKinds: Set<AIAgentKind> = []

    public init(threshold: TimeInterval = 120, recency: TimeInterval = 5 * 60) {
        self.threshold = threshold
        self.recency = recency
    }

    /// Takes one tool's sessions as they are now and returns the notices to show.
    public mutating func update(kind: AIAgentKind, activities: [AIAgentSessionActivity], now: Date) -> [AIAgentNotice] {
        let isPrimed = primedKinds.contains(kind)
        primedKinds.insert(kind)
        var notices: [AIAgentNotice] = []
        var seen: Set<String> = []

        for activity in activities where activity.kind == kind {
            let key = Self.key(kind, activity.sessionID)
            seen.insert(key)
            if activity.isWorking {
                let since = activity.workingSince ?? now
                if let known = workingSince[key] {
                    workingSince[key] = min(known, since)
                } else {
                    workingSince[key] = since
                }
                continue
            }
            guard let startedAt = workingSince.removeValue(forKey: key) else { continue }
            guard isPrimed, let endedAt = activity.endedAt else { continue }
            let start = activity.workingSince.map { min($0, startedAt) } ?? startedAt
            // The end must belong to this stretch of work and be recent.
            guard endedAt >= start, now.timeIntervalSince(endedAt) <= recency else { continue }
            let duration = endedAt.timeIntervalSince(start)
            guard duration >= threshold else { continue }
            notices.append(AIAgentNotice(kind: kind, projectName: activity.projectName, duration: duration))
        }

        // Sessions that dropped out of the list (pruned) are forgotten without a notice.
        let prefix = kind.rawValue + "|"
        for key in workingSince.keys where key.hasPrefix(prefix) && !seen.contains(key) {
            workingSince[key] = nil
        }
        return notices
    }

    /// Forgets a tool, e.g. when it is switched off; its next update is a first look again.
    public mutating func reset(kind: AIAgentKind) {
        primedKinds.remove(kind)
        let prefix = kind.rawValue + "|"
        workingSince = workingSince.filter { !$0.key.hasPrefix(prefix) }
    }

    private static func key(_ kind: AIAgentKind, _ session: String) -> String {
        kind.rawValue + "|" + session
    }
}
