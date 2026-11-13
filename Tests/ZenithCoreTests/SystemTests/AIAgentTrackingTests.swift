import Testing
import Foundation
import SQLite3
@testable import ZenithCore

/// A clock the tests move by hand.
private final class AgentClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// Noon of the real current day in the local time zone: fixture files are written now, and a source picks up at
/// start-up only logs changed since shortly before today began.
private let localNoon: Date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func text(_ object: [String: Any]) -> String {
    String(decoding: line(object), as: UTF8.self)
}

// MARK: Hand-written Claude Code / Codex lines

private func claudeUser(session: String = "s1", cwd: String = "/Users/someone/code/demo-app", at date: Date) -> [String: Any] {
    [
        "type": "user", "sessionId": session, "cwd": cwd, "timestamp": iso(date), "uuid": UUID().uuidString,
        "message": ["role": "user", "content": "SECRET PROMPT TEXT"]
    ]
}

private func claudeReply(
    session: String = "s1", id: String, stop: String, at date: Date,
    input: Int = 10, output: Int = 20, cacheRead: Int = 300, cacheWrite: Int = 40,
    model: String = "claude-test-1", sidechain: Bool = false
) -> [String: Any] {
    [
        "type": "assistant", "sessionId": session, "cwd": "/Users/someone/code/demo-app", "timestamp": iso(date),
        "isSidechain": sidechain, "someFutureField": ["nested": true],
        "message": [
            "id": id, "model": model, "stop_reason": stop, "role": "assistant",
            "content": [["type": "text", "text": "SECRET REPLY TEXT"]],
            "usage": [
                "input_tokens": input, "output_tokens": output,
                "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
                "service_tier": "standard"
            ]
        ]
    ]
}

private func codexTokenCount(at date: Date, input: Int, cached: Int, output: Int, limits: [String: Any]? = nil) -> [String: Any] {
    var payload: [String: Any] = [
        "type": "token_count",
        "info": [
            "total_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                "reasoning_output_tokens": 5, "total_tokens": input + output
            ],
            "last_token_usage": ["input_tokens": 1, "output_tokens": 1]
        ]
    ]
    if let limits { payload["rate_limits"] = limits }
    return ["timestamp": iso(date), "type": "event_msg", "payload": payload]
}

/// A throwaway home folder with the tools' folders in it.
private final class TempHome {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-ai-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, lines: [String], newlineAtEnd: Bool = true) -> URL {
        let file = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + (newlineAtEnd ? "\n" : "")
        try! body.write(to: file, atomically: false, encoding: .utf8)
        return file
    }

    func append(_ file: URL, _ text: String) {
        let handle = try! FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8)!)
        try? handle.close()
    }
}

private func record(_ result: AIAgentLineResult) -> AIAgentLogRecord? {
    if case .record(let record) = result { return record }
    return nil
}

@Suite("AI agents: log parsers, ledger, working detection, notices and settings")
@MainActor
struct AIAgentTrackingTests {

    // MARK: Parsers

    @Test("AIA-01: A Claude Code reply gives tokens, model, reply id and turn state, never its text")
    func testClaudeReply() {
        let parser = ClaudeCodeLogParser()
        let working = record(parser.parse(line: line(claudeReply(id: "msg_1", stop: "tool_use", at: localNoon))))
        #expect(working?.usage == AIAgentTokenUsage(input: 10, output: 20, cacheRead: 300, cacheWrite: 40))
        #expect(working?.model == "claude-test-1")
        #expect(working?.usageKey == "msg_1")
        #expect(working?.turn == .active)
        #expect(working?.sessionID == "s1")
        #expect(working?.projectPath == "/Users/someone/code/demo-app")
        #expect(working?.timestamp.map { abs($0.timeIntervalSince(localNoon)) < 0.01 } == true)
        #expect(!String(describing: working as Any).contains("SECRET"))

        let done = record(parser.parse(line: line(claudeReply(id: "msg_2", stop: "end_turn", at: localNoon))))
        #expect(done?.turn == .ended)

        // A subagent ending its own turn does not end the session's.
        let sub = record(parser.parse(line: line(claudeReply(id: "msg_3", stop: "end_turn", at: localNoon, sidechain: true))))
        #expect(sub?.turn == .active)
        #expect(sub?.usage != nil)

        // Claude Code's locally made replies carry "<synthetic>", which is not a model.
        let synthetic = record(parser.parse(line: line(claudeReply(id: "msg_4", stop: "end_turn", at: localNoon, model: "<synthetic>"))))
        #expect(synthetic?.model == nil)
    }

    @Test("AIA-02: Claude Code prompts mark activity; other records, odd and broken lines are told apart")
    func testClaudeOtherLines() {
        let parser = ClaudeCodeLogParser()
        let prompt = record(parser.parse(line: line(claudeUser(at: localNoon))))
        #expect(prompt?.turn == .active)
        #expect(prompt?.usage == nil)
        #expect(!String(describing: prompt as Any).contains("SECRET"))

        #expect(parser.parse(line: Data(#"{"type":"custom-title","customTitle":"x","sessionId":"s1"}"#.utf8)) == .ignored)
        #expect(parser.parse(line: Data(#"{"type":"assistant"}"#.utf8)) == .record(AIAgentLogRecord(turn: .active)))
        #expect(parser.parse(line: Data(#"[1,2,3]"#.utf8)) == .ignored)
        #expect(parser.parse(line: Data("{\"type\":\"assistant\",".utf8)) == .malformed)
        #expect(parser.parse(line: Data("not json at all".utf8)) == .malformed)
        // Wrong types for known fields are skipped, not trusted.
        let odd = record(parser.parse(line: Data(#"{"type":"assistant","timestamp":5,"message":{"usage":{"input_tokens":"12","output_tokens":true}}}"#.utf8)))
        #expect(odd?.usage == AIAgentTokenUsage(input: 12))
    }

    @Test("AIA-03: Codex rollout lines give the session, model, running totals, limits and turn ends")
    func testCodexLines() {
        let parser = CodexRolloutParser()
        let meta = record(parser.parse(line: Data(
            #"{"timestamp":"2026-11-13T05:00:00.000Z","type":"session_meta","payload":{"id":"c-1","cwd":"/Users/someone/site","instructions":"SECRET"}}"#.utf8
        )))
        #expect(meta?.sessionID == "c-1")
        #expect(meta?.projectPath == "/Users/someone/site")
        #expect(meta?.turn == nil)

        let context = record(parser.parse(line: Data(
            #"{"timestamp":"2026-11-13T05:00:01Z","type":"turn_context","payload":{"model":"codex-test","cwd":"/Users/someone/site"}}"#.utf8
        )))
        #expect(context?.model == "codex-test")
        #expect(context?.turn == .active)

        let observed = localNoon
        let limits: [String: Any] = [
            "primary": ["used_percent": 38.5, "window_minutes": 300, "resets_in_seconds": 600],
            "secondary": ["used_percent": 12, "window_minutes": 10_080, "resets_at": observed.timeIntervalSince1970 + 86_400],
            "unknown_window": ["used_percent": 1]
        ]
        let tokens = record(parser.parse(line: line(codexTokenCount(at: observed, input: 1_000, cached: 600, output: 50, limits: limits))))
        #expect(tokens?.cumulativeUsage == AIAgentTokenUsage(input: 400, output: 50, cacheRead: 600))
        #expect(tokens?.rateLimits?.count == 2)
        #expect(tokens?.rateLimits?.first == AIAgentRateLimit(windowMinutes: 300, usedPercent: 38.5, resetsAt: observed.addingTimeInterval(600)))
        #expect(tokens?.rateLimits?.last?.resetsAt == observed.addingTimeInterval(86_400))

        #expect(record(parser.parse(line: Data(#"{"timestamp":"2026-11-13T05:10:00Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"SECRET"}}"#.utf8)))?.turn == .ended)
        #expect(record(parser.parse(line: Data(#"{"timestamp":"2026-11-13T05:10:00Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#.utf8)))?.turn == .ended)
        #expect(record(parser.parse(line: Data(#"{"timestamp":"2026-11-13T05:10:00Z","type":"response_item","payload":{"type":"message","content":"SECRET"}}"#.utf8)))?.turn == .active)
        #expect(parser.parse(line: Data(#"{"timestamp":"2026-11-13T05:10:00Z","type":"compacted","payload":{}}"#.utf8)) == .ignored)
        #expect(parser.parse(line: Data("{oops".utf8)) == .malformed)
    }

    // MARK: Ledger

    @Test("AIA-04: A reply split over several lines counts once; tokens add up per day and per session")
    func testLedgerTotals() {
        let parser = ClaudeCodeLogParser()
        var ledger = AIAgentUsageLedger(kind: .claudeCode)
        let yesterday = localNoon.addingTimeInterval(-86_400)
        let lines: [[String: Any]] = [
            claudeReply(session: "old", id: "msg_y", stop: "end_turn", at: yesterday, input: 1_000, output: 0, cacheRead: 0, cacheWrite: 0),
            claudeUser(at: localNoon.addingTimeInterval(-60)),
            claudeReply(id: "msg_a", stop: "tool_use", at: localNoon.addingTimeInterval(-50)),
            claudeReply(id: "msg_a", stop: "tool_use", at: localNoon.addingTimeInterval(-50)), // same reply, second block
            claudeReply(id: "msg_b", stop: "end_turn", at: localNoon.addingTimeInterval(-40), input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        ]
        for object in lines {
            if let record = record(parser.parse(line: line(object))) {
                ledger.apply(record, fallbackSessionID: "file")
            }
        }
        let snapshot = ledger.snapshot(now: localNoon)
        #expect(snapshot.todayUsage == AIAgentTokenUsage(input: 11, output: 22, cacheRead: 303, cacheWrite: 44))
        #expect(snapshot.sessionUsage == AIAgentTokenUsage(input: 11, output: 22, cacheRead: 303, cacheWrite: 44))
        #expect(snapshot.projectName == "demo-app")
        #expect(snapshot.model == "claude-test-1")
        #expect(snapshot.sessionsToday == 1)
        #expect(!snapshot.isWorking)
        #expect(snapshot.usageText == "Today 380 · Session 380")
    }

    @Test("AIA-05: Codex running totals become per-day additions, and a repeated total adds nothing")
    func testCumulativeTotals() {
        var ledger = AIAgentUsageLedger(kind: .codex)
        let morning = localNoon.addingTimeInterval(-3_600)
        ledger.apply(AIAgentLogRecord(timestamp: morning.addingTimeInterval(-86_400), cumulativeUsage: AIAgentTokenUsage(input: 100)), fallbackSessionID: "f1")
        ledger.apply(AIAgentLogRecord(timestamp: morning, cumulativeUsage: AIAgentTokenUsage(input: 150, output: 10)), fallbackSessionID: "f1")
        ledger.apply(AIAgentLogRecord(timestamp: morning, cumulativeUsage: AIAgentTokenUsage(input: 150, output: 10)), fallbackSessionID: "f1")
        ledger.apply(AIAgentLogRecord(timestamp: morning, cumulativeUsage: AIAgentTokenUsage(input: 20)), fallbackSessionID: "f2")
        let snapshot = ledger.snapshot(now: localNoon)
        #expect(snapshot.todayUsage == AIAgentTokenUsage(input: 70, output: 10))
        #expect(ledger.sessions["f1"]?.usage == AIAgentTokenUsage(input: 150, output: 10))
    }

    @Test("AIA-06: Working while a turn is open, idle after its end, and taken as stopped when the log goes quiet")
    func testWorkingDetection() {
        var ledger = AIAgentUsageLedger(kind: .claudeCode, staleAfter: 600)
        let start = localNoon
        ledger.apply(AIAgentLogRecord(timestamp: start, sessionID: "s", projectPath: "/p/app", turn: .active), fallbackSessionID: "f")
        #expect(ledger.snapshot(now: start.addingTimeInterval(30)).isWorking)
        #expect(ledger.snapshot(now: start.addingTimeInterval(30)).workingSince == start)
        #expect(ledger.snapshot(now: start.addingTimeInterval(30)).statusText == "Working · app")
        #expect(!ledger.snapshot(now: start.addingTimeInterval(601)).isWorking)
        // What the tool itself says wins: busy through a long, silent tool run…
        #expect(ledger.snapshot(now: start.addingTimeInterval(1_200), workingOverrides: ["s": true]).isWorking)
        // …and idle even with the turn still open.
        #expect(!ledger.snapshot(now: start.addingTimeInterval(5), workingOverrides: ["s": false]).isWorking)

        ledger.apply(AIAgentLogRecord(timestamp: start.addingTimeInterval(200), sessionID: "s", turn: .ended), fallbackSessionID: "f")
        #expect(!ledger.snapshot(now: start.addingTimeInterval(201)).isWorking)
        let activity = ledger.activities(now: start.addingTimeInterval(201)).first
        #expect(activity?.endedAt == start.addingTimeInterval(200))
        #expect(activity?.workingSince == start)
    }

    // MARK: Notices

    @Test("AIA-07: Only a long piece of work that ends by itself, recently and after the first look, gives a notice")
    func testLongTaskNotice() {
        var tracker = AIAgentActivityTracker(threshold: 120)
        let start = localNoon
        func activity(_ working: Bool, since: Date? = start, ended: Date? = nil, id: String = "s") -> AIAgentSessionActivity {
            AIAgentSessionActivity(kind: .claudeCode, sessionID: id, projectName: "app", isWorking: working, workingSince: since, endedAt: ended)
        }
        // First look: history says nothing, even a fresh end.
        #expect(tracker.update(kind: .claudeCode, activities: [activity(true)], now: start).isEmpty)
        // A long turn ending now.
        let notices = tracker.update(kind: .claudeCode, activities: [activity(false, ended: start.addingTimeInterval(180))], now: start.addingTimeInterval(181))
        #expect(notices == [AIAgentNotice(kind: .claudeCode, projectName: "app", duration: 180)])
        #expect(notices.first?.title == "Claude Code finished")
        #expect(notices.first?.subtitle == "app · 3 min")

        // A short one says nothing.
        _ = tracker.update(kind: .claudeCode, activities: [activity(true, since: start.addingTimeInterval(300))], now: start.addingTimeInterval(300))
        #expect(tracker.update(kind: .claudeCode, activities: [activity(false, since: start.addingTimeInterval(300), ended: start.addingTimeInterval(360))], now: start.addingTimeInterval(361)).isEmpty)

        // Going quiet (no end recorded) says nothing.
        _ = tracker.update(kind: .claudeCode, activities: [activity(true, since: start.addingTimeInterval(400))], now: start.addingTimeInterval(400))
        #expect(tracker.update(kind: .claudeCode, activities: [activity(false, since: start.addingTimeInterval(400), ended: nil)], now: start.addingTimeInterval(1_400)).isEmpty)

        // An end Zenith learns of long after it happened says nothing.
        _ = tracker.update(kind: .claudeCode, activities: [activity(true, since: start.addingTimeInterval(2_000))], now: start.addingTimeInterval(2_000))
        #expect(tracker.update(kind: .claudeCode, activities: [activity(false, since: start.addingTimeInterval(2_000), ended: start.addingTimeInterval(2_300))], now: start.addingTimeInterval(4_000)).isEmpty)

        let hours = AIAgentNotice(kind: .codex, projectName: nil, duration: 3_900)
        #expect(hours.subtitle == "1 h 5 min")
    }

    // MARK: Files

    @Test("AIA-08: A source reads only what was appended, and waits for a line to be finished")
    func testIncrementalReading() throws {
        let home = TempHome()
        let clock = AgentClock(localNoon)
        let file = home.write(".claude/projects/-Users-someone-demo/s1.jsonl", lines: [
            text(claudeUser(at: localNoon.addingTimeInterval(-30))),
            text(claudeReply(id: "m1", stop: "tool_use", at: localNoon.addingTimeInterval(-20)))
        ])
        let source = JSONLinesAgentSource.claudeCode(home: home.url, isProcessAlive: { _ in false })
        #expect(source.isInstalled())
        var result = try source.update(changedPaths: nil, now: clock.date)
        #expect(result.snapshot.isWorking)
        #expect(result.snapshot.todayUsage?.total == 370)
        #expect(!result.hasMoreWork)

        // Half a line: nothing yet.
        let ending = text(claudeReply(id: "m2", stop: "end_turn", at: localNoon.addingTimeInterval(5), input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        let cut = ending.index(ending.startIndex, offsetBy: 40)
        home.append(file, String(ending[..<cut]))
        clock.advance(10)
        result = try source.update(changedPaths: [file.path], now: clock.date)
        #expect(result.snapshot.isWorking)
        #expect(result.snapshot.todayUsage?.total == 370)

        home.append(file, String(ending[cut...]) + "\n")
        result = try source.update(changedPaths: [file.path], now: clock.date)
        #expect(!result.snapshot.isWorking)
        #expect(result.snapshot.todayUsage?.total == 372)

        // Nothing changed: nothing is added twice.
        result = try source.update(changedPaths: [file.path], now: clock.date)
        #expect(result.snapshot.todayUsage?.total == 372)
    }

    @Test("AIA-09: A pass reads a bounded number of bytes and carries on in the next one")
    func testByteBudget() throws {
        let home = TempHome()
        var lines: [String] = []
        for index in 0..<200 {
            lines.append(text(claudeReply(id: "m\(index)", stop: "tool_use", at: localNoon.addingTimeInterval(Double(index) - 300), input: 1, output: 0, cacheRead: 0, cacheWrite: 0)))
        }
        home.write(".claude/projects/p/s1.jsonl", lines: lines)
        let source = JSONLinesAgentSource(
            kind: .claudeCode, roots: [home.url.appendingPathComponent(".claude/projects")],
            parser: ClaudeCodeLogParser(), sessionKey: .fromRecord, maxDepth: 4, maxBytesPerPass: 8_000
        )
        var result = try source.update(changedPaths: nil, now: localNoon)
        #expect(result.hasMoreWork)
        var passes = 1
        while result.hasMoreWork, passes < 100 {
            result = try source.update(changedPaths: [], now: localNoon)
            passes += 1
        }
        #expect(passes > 3)
        #expect(result.snapshot.todayUsage?.input == 200)
    }

    @Test("AIA-10: A tool whose logs stop being JSON is switched off on its own; the others carry on")
    func testBrokenFormatIsolated() {
        let home = TempHome()
        home.write(".claude/projects/p/s1.jsonl", lines: Array(repeating: "<<binary garbage>>", count: JSONLinesAgentSource.malformedLineLimit + 5))
        let codexFile = "rollout-2026-11-13T05-00-00-abc.jsonl"
        home.write(".codex/sessions/2026/11/13/\(codexFile)", lines: [
            text(["timestamp": iso(localNoon.addingTimeInterval(-60)), "type": "session_meta", "payload": ["id": "c1", "cwd": "/x/site"]]),
            text(["timestamp": iso(localNoon.addingTimeInterval(-50)), "type": "event_msg", "payload": ["type": "task_started"]]),
            text(codexTokenCount(at: localNoon.addingTimeInterval(-40), input: 500, cached: 100, output: 40))
        ])
        let island = ZenithIslandState()
        let clock = AgentClock(localNoon)
        let monitor = AIAgentMonitor(
            sourceFactory: { kind in
                kind == .codex
                    ? JSONLinesAgentSource.codex(home: home.url, environment: [:])
                    : JSONLinesAgentSource.claudeCode(home: home.url, isProcessAlive: { _ in false })
            },
            now: { clock.date },
            island: island
        )
        monitor.startForTesting(kinds: [.claudeCode, .codex])
        monitor.processSynchronously(changedPaths: nil)

        #expect(monitor.snapshots.map(\.kind) == [.claudeCode, .codex])
        #expect(monitor.snapshots.first?.availability == .unreadable)
        let codex = monitor.snapshots.last
        #expect(codex?.availability == .available)
        #expect(codex?.isWorking == true)
        #expect(codex?.projectName == "site")
        #expect(codex?.todayUsage == AIAgentTokenUsage(input: 400, output: 40, cacheRead: 100))
        #expect(island.aiAgents.map(\.kind) == [.codex])
        #expect(island.workingAIAgent?.kind == .codex)
        #expect(island.hasCompactActivity)
    }

    @Test("AIA-11: The monitor shows an agent at work, then a notice when its long task ends, and clears on stop")
    func testMonitorEndToEnd() {
        let home = TempHome()
        let clock = AgentClock(localNoon)
        let file = home.write(".claude/projects/-Users-someone-demo-app/s1.jsonl", lines: [
            text(claudeUser(at: localNoon.addingTimeInterval(-10))),
            text(claudeReply(id: "m1", stop: "tool_use", at: localNoon.addingTimeInterval(-5)))
        ])
        let island = ZenithIslandState()
        let monitor = AIAgentMonitor(
            sourceFactory: { _ in JSONLinesAgentSource.claudeCode(home: home.url, isProcessAlive: { _ in false }) },
            now: { clock.date },
            island: island
        )
        var notices: [AIAgentNotice] = []
        monitor.onNotice = { notices.append($0) }
        monitor.longTaskThreshold = 120
        monitor.startForTesting(kinds: [.claudeCode])
        monitor.processSynchronously(changedPaths: nil)

        #expect(island.showsAIAgentsTab)
        #expect(island.workingAIAgent?.kind == .claudeCode)
        #expect(island.workingAIAgent?.projectName == "demo-app")
        #expect(ZenithIslandState.availableTabs(hasTrack: false, hasShelfItems: false, showsWidgets: false, showsAIAgents: island.showsAIAgentsTab) == [.aiAgents])

        // Three minutes of work, then the turn ends.
        clock.advance(180)
        home.append(file, text(claudeReply(id: "m2", stop: "end_turn", at: clock.date)) + "\n")
        monitor.simulateChange([file.path])
        #expect(island.workingAIAgent == nil)
        #expect(!island.hasCompactActivity)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .claudeCode)
        #expect(notices.first?.projectName == "demo-app")
        #expect((notices.first?.duration ?? 0) >= 180)

        // Nothing new: no second notice.
        monitor.simulateChange([file.path])
        #expect(notices.count == 1)

        // Notices off: the next long task ends quietly.
        monitor.notifiesWhenFinished = false
        home.append(file, text(claudeUser(at: clock.date.addingTimeInterval(1))) + "\n")
        monitor.simulateChange([file.path])
        clock.advance(300)
        home.append(file, text(claudeReply(id: "m3", stop: "end_turn", at: clock.date)) + "\n")
        monitor.simulateChange([file.path])
        #expect(notices.count == 1)

        monitor.stop()
        #expect(island.aiAgents.isEmpty)
        #expect(!island.showsAIAgentsTab)
        #expect(monitor.snapshots.isEmpty)
    }

    @Test("AIA-12: Claude Code's own busy/idle status counts only while its process is alive")
    func testSessionRegistry() throws {
        let home = TempHome()
        home.write(".claude/sessions/101.json", lines: [#"{"pid":101,"sessionId":"alive-busy","status":"busy","name":"SECRET TITLE"}"#])
        home.write(".claude/sessions/102.json", lines: [#"{"pid":102,"sessionId":"dead-busy","status":"busy"}"#])
        home.write(".claude/sessions/103.json", lines: [#"{"pid":103,"sessionId":"alive-idle","status":"idle"}"#])
        home.write(".claude/sessions/104.json", lines: ["not json"])
        let registry = ClaudeCodeSessionRegistry(
            directory: home.url.appendingPathComponent(".claude/sessions"),
            isProcessAlive: { $0 == 101 || $0 == 103 }
        )
        #expect(registry.workingStatus() == ["alive-busy": true, "alive-idle": false])

        // A long tool run writes nothing for 20 minutes, but the process says it is busy.
        home.write(".claude/projects/p/alive-busy.jsonl", lines: [text(claudeUser(session: "alive-busy", at: localNoon))])
        let source = JSONLinesAgentSource.claudeCode(home: home.url, isProcessAlive: { $0 == 101 })
        let result = try source.update(changedPaths: nil, now: localNoon.addingTimeInterval(1_200))
        #expect(result.snapshot.isWorking)
        #expect(source.watchedPaths().contains { $0.hasSuffix("/.claude/sessions") })
    }

    @Test("AIA-13: Antigravity's conversation index gives working state, project and model, and no tokens")
    func testAntigravity() throws {
        let home = TempHome()
        let folder = home.url.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"model":"Example Model (High)","trustedWorkspaces":["/x"]}"#.write(
            to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        let dbPath = folder.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE conversation_summaries (conversation_id text, title text NOT NULL DEFAULT "", preview text NOT NULL DEFAULT "",
              step_count integer, last_modified_time datetime NOT NULL, workspace_uris text NOT NULL, status text NOT NULL DEFAULT "",
              not_fully_idle numeric NOT NULL DEFAULT false, killed numeric NOT NULL DEFAULT false, last_user_input_time datetime NOT NULL,
              nesting_depth integer NOT NULL DEFAULT 0, future_column text, PRIMARY KEY (conversation_id));
            INSERT INTO conversation_summaries VALUES ('run','SECRET','SECRET',12,'\(Self.sqlDate(localNoon.addingTimeInterval(-20)))','["file:///Users/someone/rocket"]','CASCADE_RUN_STATUS_RUNNING',0,0,'\(Self.sqlDate(localNoon.addingTimeInterval(-200)))',0,NULL);
            INSERT INTO conversation_summaries VALUES ('old','SECRET','SECRET',40,'\(Self.sqlDate(localNoon.addingTimeInterval(-7_200)))','["file:///Users/someone/other"]','CASCADE_RUN_STATUS_IDLE',0,0,'\(Self.sqlDate(localNoon.addingTimeInterval(-7_300)))',0,NULL);
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let source = AntigravitySource(home: home.url)
        #expect(source.isInstalled())
        let result = try source.update(changedPaths: nil, now: localNoon)
        #expect(result.snapshot.isWorking)
        #expect(result.snapshot.projectName == "rocket")
        #expect(result.snapshot.model == "Example Model (High)")
        #expect(result.snapshot.todayUsage == nil)
        #expect(result.snapshot.usageText == nil)
        #expect(result.snapshot.sessionsToday == 2)
        #expect(result.snapshot.workingSince.map { abs($0.timeIntervalSince(localNoon.addingTimeInterval(-200))) < 0.01 } == true)
        let old = result.activities.first { $0.sessionID == "old" }
        #expect(old?.isWorking == false)
        #expect(old?.endedAt != nil)

        // A run marked running but untouched for an hour is stuck, not working.
        #expect(try !source.update(changedPaths: [], now: localNoon.addingTimeInterval(3_600)).snapshot.isWorking)

        #expect(SQLiteAntigravitySummaryReader.date("2026-11-12 23:18:23.440837+00:00").map { abs($0.timeIntervalSince1970 - 1_794_525_503.44) < 0.002 } == true)
        #expect(SQLiteAntigravitySummaryReader.date("2026-11-12 23:18:23+00:00") == Date(timeIntervalSince1970: 1_794_525_503))
        #expect(SQLiteAntigravitySummaryReader.uris(#"["file:///a/b"]"#) == ["file:///a/b"])
        #expect(SQLiteAntigravitySummaryReader.uris("not json") == [])
    }

    private static func sqlDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date)
    }

    @Test("AIA-14: A tool that is not on this Mac is listed as such and left off the island")
    func testNotInstalled() {
        let home = TempHome()
        let island = ZenithIslandState()
        let monitor = AIAgentMonitor(
            sourceFactory: { _ in JSONLinesAgentSource.codex(home: home.url, environment: [:]) },
            now: { localNoon },
            island: island
        )
        monitor.startForTesting(kinds: [.codex])
        monitor.processSynchronously(changedPaths: nil)
        #expect(monitor.snapshots == [AIAgentSnapshot(kind: .codex, availability: .notInstalled)])
        #expect(island.aiAgents.isEmpty)
        #expect(island.showsAIAgentsTab)
    }

    // MARK: Settings, tabs and text

    @Test("AIA-15: The feature is off by default; tools, notice and length are saved and clamped")
    func testSettings() {
        let suite = "zenith.ai-agents.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AIAgentSettings(userDefaults: defaults)
        #expect(!settings.isEnabled)
        #expect(settings.activeTools.isEmpty)
        #expect(settings.enabledTools == Set(AIAgentKind.allCases))
        #expect(settings.longTaskMinutes == 2)
        #expect(settings.longTaskThreshold == 120)
        #expect(settings.notifyWhenFinished)

        settings.isEnabled = true
        settings.setTool(.antigravity, enabled: false)
        settings.longTaskMinutes = 500
        settings.notifyWhenFinished = false
        #expect(settings.longTaskMinutes == AIAgentSettings.longTaskRange.upperBound)
        #expect(settings.activeTools == [.claudeCode, .codex])

        let reloaded = AIAgentSettings(userDefaults: defaults)
        #expect(reloaded.isEnabled)
        #expect(!reloaded.isToolEnabled(.antigravity))
        #expect(reloaded.longTaskMinutes == 60)
        #expect(!reloaded.notifyWhenFinished)

        reloaded.resetToDefaults()
        #expect(!reloaded.isEnabled)
        #expect(reloaded.enabledTools == Set(AIAgentKind.allCases))
    }

    @Test("AIA-16: The AI tab sits after Widgets; the closed island shows a working agent only after a timer or music")
    func testTabsAndCompactActivity() {
        #expect(ZenithIslandState.availableTabs(hasTrack: true, hasShelfItems: true, showsWidgets: true, showsAIAgents: true)
            == [.nowPlaying, .widgets, .aiAgents, .shelf])
        #expect(ZenithIslandState.availableTabs(hasTrack: true, hasShelfItems: true, showsWidgets: true) == [.nowPlaying, .widgets, .shelf])
        #expect(ZenithIslandState.resolvedTab(active: .aiAgents, hasTrack: false, hasShelfItems: false, showsWidgets: false, showsAIAgents: true, isDropTargeted: false) == .aiAgents)
        #expect(ZenithIslandState.resolvedTab(active: .aiAgents, hasTrack: false, hasShelfItems: false, showsWidgets: true, isDropTargeted: false) == .widgets)

        let island = ZenithIslandState()
        island.aiAgents = [AIAgentSnapshot(kind: .codex, isWorking: true)]
        #expect(island.workingAIAgent == nil) // the feature is off
        island.showsAIAgentsTab = true
        #expect(island.workingAIAgent?.kind == .codex)
        #expect(island.hasCompactActivity)
    }

    @Test("AIA-17: Token counts, limits and the detail text read well")
    func testFormatting() {
        let english = Locale(identifier: "en_US")
        #expect(AIAgentTokenUsage.compact(980, locale: english) == "980")
        #expect(AIAgentTokenUsage.compact(12_345, locale: english) == "12K")
        #expect(AIAgentTokenUsage.compact(1_250_000, locale: english) == "1.2M")
        #expect(AIAgentTokenUsage.compact(45_900_000, locale: english) == "45M")
        #expect(AIAgentTokenUsage.compact(3_400_000_000, locale: english) == "3.4B")
        #expect(AIAgentTokenUsage.compact(1_250_000, locale: Locale(identifier: "vi_VN")) == "1,2M")
        #expect(AIAgentTokenUsage(input: 5, output: 2).added(since: AIAgentTokenUsage(input: 7)) == AIAgentTokenUsage(output: 2))

        #expect(AIAgentRateLimit(windowMinutes: 300, usedPercent: 38.4, resetsAt: nil).shortLabel == "5h")
        #expect(AIAgentRateLimit(windowMinutes: 299, usedPercent: 38.4, resetsAt: nil).shortLabel == "5h")
        #expect(AIAgentRateLimit(windowMinutes: 10_080, usedPercent: 0, resetsAt: nil).shortLabel == "Weekly")
        #expect(AIAgentRateLimit(windowMinutes: nil, usedPercent: 0, resetsAt: nil).shortLabel == "Limit")
        #expect(AIAgentRateLimit(windowMinutes: 300, usedPercent: 120, resetsAt: nil).percentText == "100%")
        #expect(AIAgentRateLimit(windowMinutes: 300, usedPercent: 1, resetsAt: nil).resetDescription(now: localNoon) == nil)
        #expect(AIAgentRateLimit(windowMinutes: 300, usedPercent: 1, resetsAt: localNoon.addingTimeInterval(3_600)).resetDescription(now: localNoon)?.hasPrefix("resets ") == true)

        let snapshot = AIAgentSnapshot(
            kind: .codex, isWorking: false, projectName: "site", model: "codex-test",
            todayUsage: AIAgentTokenUsage(input: 1_000, output: 200, cacheRead: 3_000),
            rateLimits: [AIAgentRateLimit(windowMinutes: 300, usedPercent: 38, resetsAt: nil)]
        )
        #expect(snapshot.statusText == "Idle · site")
        #expect(snapshot.limitsText == "5h 38%")
        #expect(snapshot.detailText(now: localNoon).contains("Model: codex-test"))
        #expect(snapshot.detailText(now: localNoon).contains("5h limit: 38% used"))
        #expect(AIAgentUsageLedger.folderName("file:///Users/someone/my%20app") == "my app")
        #expect(AIAgentUsageLedger.folderName("/") == nil)
    }
}

/// Reads this Mac's real agent logs, read-only, and prints only totals and states (never a line of a log).
/// Opt-in: `ZENITH_E2E_AI_AGENTS=1 swift test --filter AIAgentLiveLogTests`.
@Suite("AI agents: this Mac's real logs (opt-in, read-only)", .enabled(if: ProcessInfo.processInfo.environment["ZENITH_E2E_AI_AGENTS"] == "1"))
struct AIAgentLiveLogTests {
    @Test("AIA-E2E: Every installed tool's real files are read without being taken as unreadable")
    func testRealLogs() throws {
        let now = Date()
        for kind in AIAgentKind.allCases {
            let source = AIAgentMonitor.liveSource(kind)
            guard source.isInstalled() else {
                print("[AIA-E2E] \(kind.displayName): not installed")
                continue
            }
            var result = try source.update(changedPaths: nil, now: now)
            var passes = 1
            while result.hasMoreWork, passes < 500 {
                result = try source.update(changedPaths: [], now: now)
                passes += 1
            }
            let s = result.snapshot
            print("[AIA-E2E] \(kind.displayName): passes=\(passes) working=\(s.isWorking) project=\(s.projectName ?? "-") model=\(s.model ?? "-") today=\(s.todayUsage?.total ?? -1) session=\(s.sessionUsage?.total ?? -1) limits=\(s.limitsText ?? "-") sessionsToday=\(s.sessionsToday)")
            #expect(s.availability == .available)
        }
    }
}
