import Foundation
import SQLite3

/// One row of Antigravity's conversation index, reduced to what Zenith uses. Titles and previews are in the same
/// table and are never selected.
public struct AntigravityConversationRow: Sendable, Equatable {
    public let id: String
    public let lastModified: Date?
    public let lastUserInput: Date?
    public let workspaceURIs: [String]
    /// `CASCADE_RUN_STATUS_IDLE` when idle; anything else is taken as running.
    public let status: String
    public let notFullyIdle: Bool
    public let killed: Bool
    /// 0 for a conversation the user started, more for one an agent started.
    public let nestingDepth: Int

    public init(
        id: String,
        lastModified: Date?,
        lastUserInput: Date? = nil,
        workspaceURIs: [String] = [],
        status: String,
        notFullyIdle: Bool = false,
        killed: Bool = false,
        nestingDepth: Int = 0
    ) {
        self.id = id
        self.lastModified = lastModified
        self.lastUserInput = lastUserInput
        self.workspaceURIs = workspaceURIs
        self.status = status
        self.notFullyIdle = notFullyIdle
        self.killed = killed
        self.nestingDepth = nestingDepth
    }

    public var isRunningStatus: Bool {
        let upper = status.uppercased()
        if notFullyIdle { return true }
        return !upper.isEmpty && !upper.hasSuffix("_IDLE") && upper != "IDLE"
    }
}

public protocol AntigravitySummaryReading: AnyObject {
    var databasePath: String { get }
    func recentConversations(limit: Int) throws -> [AntigravityConversationRow]
}

/// Reads `conversation_summaries` in `~/.gemini/antigravity-cli/conversation_summaries.db`, read-only.
public final class SQLiteAntigravitySummaryReader: AntigravitySummaryReading {
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    private static let fullQuery = """
        SELECT conversation_id, last_modified_time, last_user_input_time, workspace_uris, status,
               not_fully_idle, killed, nesting_depth
        FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT ?
        """
    /// The columns Zenith cannot do without, for a database that has dropped the others.
    private static let minimalQuery = """
        SELECT conversation_id, last_modified_time, status FROM conversation_summaries
        ORDER BY last_modified_time DESC LIMIT ?
        """

    public func recentConversations(limit: Int) throws -> [AntigravityConversationRow] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        let path = databasePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databasePath
        do {
            // Read-only; never creates the file or a journal.
            return try query(uri: "file:\(path)?mode=ro", limit: limit)
        } catch AIAgentSourceError.temporarilyUnavailable {
            // Where the database cannot be locked for reading, read it as a snapshot. A torn read fails as
            // temporary too, and the next change tries again.
            return try query(uri: "file:\(path)?immutable=1", limit: limit)
        }
    }

    private func query(uri: String, limit: Int) throws -> [AntigravityConversationRow] {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(db) }
        guard code == SQLITE_OK, let db else { throw AIAgentSourceError.temporarilyUnavailable }
        sqlite3_busy_timeout(db, 200)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var full = true
        if sqlite3_prepare_v2(db, Self.fullQuery, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            full = false
            if sqlite3_prepare_v2(db, Self.minimalQuery, -1, &statement, nil) != SQLITE_OK {
                // Only a database that is there but lacks the table or columns is a changed format.
                let error = sqlite3_errcode(db)
                if error == SQLITE_ERROR {
                    throw AIAgentSourceError.unreadableDatabase(String(cString: sqlite3_errmsg(db)))
                }
                throw AIAgentSourceError.temporarilyUnavailable
            }
        }
        sqlite3_bind_int(statement, 1, Int32(clamping: limit))

        var rows: [AntigravityConversationRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let id = Self.text(statement, 0) {
                if full {
                    rows.append(AntigravityConversationRow(
                        id: id,
                        lastModified: Self.date(Self.text(statement, 1)),
                        lastUserInput: Self.date(Self.text(statement, 2)),
                        workspaceURIs: Self.uris(Self.text(statement, 3)),
                        status: Self.text(statement, 4) ?? "",
                        notFullyIdle: sqlite3_column_int(statement, 5) != 0,
                        killed: sqlite3_column_int(statement, 6) != 0,
                        nestingDepth: Int(sqlite3_column_int(statement, 7))
                    ))
                } else {
                    rows.append(AntigravityConversationRow(
                        id: id, lastModified: Self.date(Self.text(statement, 1)), status: Self.text(statement, 2) ?? ""
                    ))
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw AIAgentSourceError.temporarilyUnavailable }
        return rows
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    /// `["file:///Users/me/project"]`.
    static func uris(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }

    /// "2026-11-12 23:18:23.440837+00:00", with or without the fraction; or an ISO 8601 / epoch value.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let date = AIAgentJSON.date(text) { return date }
        text = text.replacingOccurrences(of: " ", with: "T")
        // ISO8601DateFormatter takes at most three fraction digits.
        if let dot = text.firstIndex(of: ".") {
            let fractionStart = text.index(after: dot)
            let zoneStart = text[fractionStart...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? text.endIndex
            let digits = text[fractionStart..<zoneStart].prefix(3)
            text = String(text[..<fractionStart]) + digits + String(text[zoneStart...])
        }
        return AIAgentJSON.date(text)
    }
}

/// Antigravity (the `agy` CLI and its agent). Its conversation index says which conversation is running and in
/// which folder; token counts sit inside undocumented protobuf blobs, so none are shown. The model is the one picked
/// in its settings.
public final class AntigravitySource: AIAgentSource {
    public let kind = AIAgentKind.antigravity
    private let dataDirectory: URL
    private let installMarkers: [URL]
    private let reader: AntigravitySummaryReading
    private let calendar: Calendar
    /// A conversation marked running whose index has not changed for this long is taken as stuck, not working.
    public let staleAfter: TimeInterval
    private var cachedRows: [AntigravityConversationRow] = []
    private var model: String?
    private var hasRead = false

    public init(
        home: URL,
        reader: AntigravitySummaryReading? = nil,
        staleAfter: TimeInterval = 30 * 60,
        calendar: Calendar = .current
    ) {
        let data = home.appendingPathComponent(".gemini/antigravity-cli")
        self.dataDirectory = data
        self.installMarkers = [
            data,
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/Applications/Antigravity.app")
        ]
        self.reader = reader ?? SQLiteAntigravitySummaryReader(
            databasePath: data.appendingPathComponent("conversation_summaries.db").path
        )
        self.staleAfter = staleAfter
        self.calendar = calendar
    }

    public func isInstalled() -> Bool {
        installMarkers.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func watchedPaths() -> [String] {
        FileManager.default.fileExists(atPath: dataDirectory.path) ? [dataDirectory.path] : []
    }

    public func update(changedPaths: [String]?, now: Date) throws -> AIAgentSourceResult {
        let databaseName = (reader.databasePath as NSString).lastPathComponent
        let touchesIndex = changedPaths?.contains { ($0 as NSString).lastPathComponent.hasPrefix(databaseName) } ?? true
        let touchesSettings = changedPaths?.contains { $0.hasSuffix("/settings.json") } ?? true
        if !hasRead || touchesIndex {
            do {
                cachedRows = try reader.recentConversations(limit: 50)
            } catch AIAgentSourceError.temporarilyUnavailable {
                // Locked or mid-write: keep what was read last time.
            }
        }
        if !hasRead || touchesSettings {
            model = readModel()
        }
        hasRead = true
        return result(now: now)
    }

    /// `"model": "…"` in `settings.json`; nothing else in that file is read.
    private func readModel() -> String? {
        let url = dataDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url), data.count < 256 * 1_024,
              let object = AIAgentJSON.object(data) else { return nil }
        return AIAgentJSON.string(object["model"])
    }

    func isWorking(_ row: AntigravityConversationRow, now: Date) -> Bool {
        guard !row.killed, row.isRunningStatus, let modified = row.lastModified else { return false }
        return now.timeIntervalSince(modified) < staleAfter
    }

    private func result(now: Date) -> AIAgentSourceResult {
        let activities = cachedRows.map { row -> AIAgentSessionActivity in
            let working = isWorking(row, now: now)
            return AIAgentSessionActivity(
                kind: kind,
                sessionID: row.id,
                projectName: AIAgentUsageLedger.folderName(row.workspaceURIs.first),
                isWorking: working,
                workingSince: row.lastUserInput ?? row.lastModified,
                endedAt: (!working && !row.isRunningStatus) ? row.lastModified : nil
            )
        }
        let working = cachedRows.filter { isWorking($0, now: now) }
        let current = working.first(where: { $0.nestingDepth == 0 }) ?? working.first
            ?? cachedRows.first(where: { $0.nestingDepth == 0 }) ?? cachedRows.first
        let snapshot = AIAgentSnapshot(
            kind: kind,
            isWorking: !working.isEmpty,
            projectName: AIAgentUsageLedger.folderName(current?.workspaceURIs.first),
            model: model,
            workingSince: working.isEmpty ? nil : (current?.lastUserInput ?? current?.lastModified),
            lastActivity: cachedRows.compactMap(\.lastModified).max(),
            todayUsage: nil,
            sessionUsage: nil,
            rateLimits: [],
            sessionsToday: cachedRows.filter { row in
                row.nestingDepth == 0 && row.lastModified.map { calendar.isDate($0, inSameDayAs: now) } == true
            }.count
        )
        return AIAgentSourceResult(snapshot: snapshot, activities: activities, hasMoreWork: false)
    }
}
