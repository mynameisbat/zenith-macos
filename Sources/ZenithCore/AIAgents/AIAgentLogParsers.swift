import Foundation

/// Shared helpers for the JSON-lines parsers. Every lookup is optional: a field that is missing or of another type
/// is simply not used, so a format that grows new fields keeps working.
enum AIAgentJSON {
    /// Lines longer than this are not decoded (a tool result can hold a whole file). They never carry usage.
    static let maxDecodedLineBytes = 2 * 1_024 * 1_024

    static func object(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty, line.count <= maxDecodedLineBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: line, options: [])) as? [String: Any]
    }

    /// What to make of a line that did not decode to an object: too long to decode, or valid JSON of another shape,
    /// is just not interesting; anything else is broken.
    static func unparsed(_ line: Data) -> AIAgentLineResult {
        if line.count > maxDecodedLineBytes { return .ignored }
        return (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) != nil ? .ignored : .malformed
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            guard double.isFinite, abs(double) < 1e15 else { return nil }
            return Int(double)
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    /// ISO 8601 with or without fractional seconds ("2026-11-13T14:44:04.662Z").
    static func date(_ value: Any?) -> Date? {
        if let seconds = double(value) {
            // Epoch seconds or milliseconds.
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1_000 : seconds)
        }
        guard let text = value as? String else { return nil }
        if let date = fractional.date(from: text) { return date }
        return plain.date(from: text)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Claude Code

/// Reads `~/.claude/projects/<project>/<session>.jsonl`.
///
/// Used: `type` (`user` / `assistant`), `timestamp`, `sessionId`, `cwd`, `isSidechain`, and for replies
/// `message.id`, `message.model`, `message.stop_reason` and `message.usage` (`input_tokens`, `output_tokens`,
/// `cache_read_input_tokens`, `cache_creation_input_tokens`). A reply with several content blocks is written as one
/// line per block, each with the same id and usage: `usageKey` lets the ledger count it once. `message.content`
/// (the prompt, the reply, tool input and output) is never read. Claude Code does not write plan limits here.
public struct ClaudeCodeLogParser: AIAgentLineParsing {
    public init() {}

    /// Replies that end the turn; anything else (`tool_use`, `pause_turn`, a missing value) means it goes on.
    private static let endingStopReasons: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]

    public func parse(line: Data) -> AIAgentLineResult {
        // Too long to decode is not broken: tool results can be huge.
        guard let object = AIAgentJSON.object(line) else { return AIAgentJSON.unparsed(line) }
        guard let type = object["type"] as? String, type == "user" || type == "assistant" else { return .ignored }

        var record = AIAgentLogRecord()
        record.timestamp = AIAgentJSON.date(object["timestamp"])
        record.sessionID = AIAgentJSON.string(object["sessionId"])
        record.projectPath = AIAgentJSON.string(object["cwd"])
        // A subagent's turn ending is not the session's: its lines only show activity.
        let isSidechain = (object["isSidechain"] as? Bool) == true || object["agentId"] != nil

        guard type == "assistant" else {
            record.turn = .active
            return .record(record)
        }

        let message = object["message"] as? [String: Any] ?? [:]
        if let model = AIAgentJSON.string(message["model"]), !model.hasPrefix("<") {
            // "<synthetic>" marks a reply Claude Code made up locally (an error notice), not a model.
            record.model = model
        }
        if let usage = message["usage"] as? [String: Any] {
            let tokens = AIAgentTokenUsage(
                input: AIAgentJSON.int(usage["input_tokens"]) ?? 0,
                output: AIAgentJSON.int(usage["output_tokens"]) ?? 0,
                cacheRead: AIAgentJSON.int(usage["cache_read_input_tokens"]) ?? 0,
                cacheWrite: AIAgentJSON.int(usage["cache_creation_input_tokens"]) ?? 0
            )
            if !tokens.isZero {
                record.usage = tokens
                record.usageKey = AIAgentJSON.string(message["id"])
                    ?? AIAgentJSON.string(object["requestId"])
                    ?? AIAgentJSON.string(object["uuid"])
            }
        }
        if !isSidechain, let stop = message["stop_reason"] as? String, Self.endingStopReasons.contains(stop) {
            record.turn = .ended
        } else {
            record.turn = .active
        }
        return .record(record)
    }
}

// MARK: - Codex CLI

/// Reads `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (or `$CODEX_HOME/sessions`).
///
/// Each line is `{"timestamp", "type", "payload"}`. Used: `session_meta` (`id`, `cwd`), `turn_context` (`model`,
/// `cwd`), and `event_msg` whose `payload.type` is `task_started` / `task_complete` / `turn_aborted` (turn state) or
/// `token_count` (`info.total_token_usage` – the session's running total – and `rate_limits.primary/secondary` with
/// `used_percent`, `window_minutes` and `resets_at` or `resets_in_seconds`). Messages, reasoning and tool output are
/// never read. Codex was not installed on the machine this was written on, so this follows the format Codex
/// publishes in its rollout files rather than files seen locally; anything else in a line is ignored.
public struct CodexRolloutParser: AIAgentLineParsing {
    public init() {}

    public func parse(line: Data) -> AIAgentLineResult {
        guard let object = AIAgentJSON.object(line) else { return AIAgentJSON.unparsed(line) }
        guard let type = object["type"] as? String else { return .ignored }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = AIAgentJSON.date(object["timestamp"])

        switch type {
        case "session_meta":
            var record = AIAgentLogRecord(timestamp: timestamp)
            record.sessionID = AIAgentJSON.string(payload["id"])
            record.projectPath = AIAgentJSON.string(payload["cwd"])
            return .record(record)

        case "turn_context":
            var record = AIAgentLogRecord(timestamp: timestamp)
            record.model = AIAgentJSON.string(payload["model"])
            record.projectPath = AIAgentJSON.string(payload["cwd"])
            record.turn = .active
            return .record(record)

        case "event_msg":
            return parseEvent(payload, timestamp: timestamp)

        case "response_item":
            // The model at work (messages, reasoning, tool calls): only the time is used.
            return .record(AIAgentLogRecord(timestamp: timestamp, turn: .active))

        default:
            return .ignored
        }
    }

    private func parseEvent(_ payload: [String: Any], timestamp: Date?) -> AIAgentLineResult {
        guard let kind = payload["type"] as? String else { return .ignored }
        switch kind {
        case "task_complete", "turn_aborted", "turn_complete":
            return .record(AIAgentLogRecord(timestamp: timestamp, turn: .ended))
        case "token_count":
            var record = AIAgentLogRecord(timestamp: timestamp, turn: .active)
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                // `input_tokens` includes the cached part; `reasoning_output_tokens` is part of `output_tokens`.
                let input = AIAgentJSON.int(total["input_tokens"]) ?? 0
                let cached = AIAgentJSON.int(total["cached_input_tokens"]) ?? 0
                record.cumulativeUsage = AIAgentTokenUsage(
                    input: max(0, input - cached),
                    output: AIAgentJSON.int(total["output_tokens"]) ?? 0,
                    cacheRead: cached
                )
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let parsed = ["primary", "secondary"].compactMap { key -> AIAgentRateLimit? in
                    guard let window = limits[key] as? [String: Any] else { return nil }
                    return Self.rateLimit(window, observedAt: timestamp)
                }
                if !parsed.isEmpty { record.rateLimits = parsed }
            }
            return .record(record)
        default:
            // task_started, user_message, agent_message, exec_command_begin, …: the agent is at work.
            return .record(AIAgentLogRecord(timestamp: timestamp, turn: .active))
        }
    }

    static func rateLimit(_ window: [String: Any], observedAt: Date?) -> AIAgentRateLimit? {
        guard let used = AIAgentJSON.double(window["used_percent"]) else { return nil }
        var resetsAt: Date?
        if let at = AIAgentJSON.double(window["resets_at"]) {
            resetsAt = Date(timeIntervalSince1970: at > 1e12 ? at / 1_000 : at)
        } else if let inSeconds = AIAgentJSON.double(window["resets_in_seconds"]), let observedAt {
            resetsAt = observedAt.addingTimeInterval(inSeconds)
        }
        return AIAgentRateLimit(
            windowMinutes: AIAgentJSON.int(window["window_minutes"]),
            usedPercent: used,
            resetsAt: resetsAt
        )
    }
}
