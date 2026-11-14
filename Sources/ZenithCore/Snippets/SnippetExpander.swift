import Foundation

/// A snippet's body with its variables filled in.
public struct SnippetExpansion: Equatable, Sendable {
    /// The text to insert.
    public var text: String
    /// How many characters the caret moves back from the end of `text` after inserting it (`{cursor}`); 0 leaves it
    /// at the end.
    public var caretOffsetFromEnd: Int

    public init(text: String, caretOffsetFromEnd: Int = 0) {
        self.text = text
        self.caretOffsetFromEnd = caretOffsetFromEnd
    }
}

/// Fills in a snippet body's variables:
///
/// - `{clipboard}`: the text on the clipboard (nothing if it holds no text)
/// - `{date}`, `{time}`, `{datetime}`: now, in the user's locale; `{date:yyyy-MM-dd}` and the like take a
///   `DateFormatter` pattern instead
/// - `{cursor}`: where the caret ends up (the first one counts; any other is dropped)
///
/// Anything else in braces is left as it is, so `{` in code snippets needs no escaping. The clock, locale, time zone
/// and clipboard are injected, so tests never read the real ones.
public struct SnippetExpander: Sendable {
    public static let variables = ["clipboard", "date", "time", "datetime", "cursor"]

    private let now: @Sendable () -> Date
    private let clipboardText: @Sendable () -> String?
    private let locale: Locale
    private let timeZone: TimeZone

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        clipboardText: @escaping @Sendable () -> String?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.now = now
        self.clipboardText = clipboardText
        self.locale = locale
        self.timeZone = timeZone
    }

    public func expand(_ body: String) -> SnippetExpansion {
        // Read each source at most once, so `{date}` and `{time}` in one body describe the same moment.
        var date: Date?
        var clipboard: String??
        var output = ""
        var caretIndex: Int?   // characters written before `{cursor}`

        var rest = Substring(body)
        while let open = rest.firstIndex(of: "{") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(where: { $0 == "}" || $0 == "{" || $0.isNewline }),
                  rest[close] == "}" else {
                output.append("{")
                rest = rest[afterOpen...]
                continue
            }
            let token = rest[afterOpen..<close]
            let name: Substring
            let format: String?
            if let colon = token.firstIndex(of: ":") {
                name = token[..<colon]
                format = String(token[token.index(after: colon)...])
            } else {
                name = token
                format = nil
            }

            switch name.lowercased() {
            case "clipboard" where format == nil:
                if clipboard == nil { clipboard = .some(clipboardText()) }
                output += (clipboard ?? nil) ?? ""
            case "date", "time", "datetime":
                if date == nil { date = now() }
                output += formatted(date!, variable: name.lowercased(), format: format)
            case "cursor" where format == nil:
                if caretIndex == nil { caretIndex = output.count }
            default:
                output += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest

        let offset = caretIndex.map { output.count - $0 } ?? 0
        return SnippetExpansion(text: output, caretOffsetFromEnd: offset)
    }

    private func formatted(_ date: Date, variable: String, format: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if let format, !format.trimmingCharacters(in: .whitespaces).isEmpty {
            formatter.dateFormat = format
        } else {
            switch variable {
            case "date":
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
            case "time":
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            default:
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
            }
        }
        return formatter.string(from: date)
    }
}
