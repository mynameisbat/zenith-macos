import Foundation

/// Which macOS a release needs, read from the release itself so the updater knows before it announces anything.
///
/// The format is one line in the GitHub release notes:
///
///     Minimum macOS: 26.0
///
/// Matching is forgiving about what a person types on a web page: any case, any amount of white space, Markdown
/// emphasis or code ticks around the words, a list or quote marker in front, and a version of one to three numbers
/// (`26`, `26.0`, `15.6.1`). The first line that matches wins. Anything else (no line, an unreadable number) means
/// "not stated", which the updater treats as compatible; the install-time check against the staged app's own
/// `LSMinimumSystemVersion` is the authority.
///
/// `scripts/create_dmg.sh` prints the exact line for the Zenith.app it just packaged: paste it into the release notes.
public enum MinimumSystemMarker {
    /// Lines longer than this are prose, not a marker.
    static let maximumLineLength = 120

    /// The text of the line to publish for `version` (`26.0` → `Minimum macOS: 26.0`).
    public static func line(for version: AppVersion) -> String {
        "Minimum macOS: \(version.description)"
    }

    /// The version a release's notes state, or nil when they state none.
    public static func parse(releaseNotes: String?) -> AppVersion? {
        guard let releaseNotes else { return nil }
        for rawLine in releaseNotes.split(whereSeparator: \.isNewline) {
            guard rawLine.utf8.count <= maximumLineLength else { continue }
            if let version = parse(line: String(rawLine)) { return version }
        }
        return nil
    }

    static func parse(line: String) -> AppVersion? {
        // Markdown emphasis and code ticks carry no meaning here: `**Minimum macOS:** 26.0` is the same line.
        let plain = line.filter { $0 != "*" && $0 != "_" && $0 != "`" }
        let leadingMarkers = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ">-+•"))
        var words = plain.unicodeScalars.drop(while: { leadingMarkers.contains($0) })
            .map(Character.init).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
            .map { String($0) }
        // `Minimum macOS : 26.0` and `Minimum macOS:26.0` both split the colon off its neighbours.
        guard words.count >= 2, words[0].lowercased() == "minimum" else { return nil }
        words.removeFirst()
        let rest = words.joined(separator: " ")
        guard rest.lowercased().hasPrefix("macos") else { return nil }
        let afterName = rest.dropFirst("macos".count).drop(while: { $0 == " " })
        guard afterName.first == ":" else { return nil }
        let value = afterName.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let version = AppVersion(value), value.first != "v", value.first != "V",
              version.components.count <= 3, version.components[0] > 0 else { return nil }
        return version
    }
}
