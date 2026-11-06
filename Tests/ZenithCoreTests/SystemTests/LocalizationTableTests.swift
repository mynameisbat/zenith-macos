import Testing
import Foundation

/// Checks the translation tables in `Localization/` (copied into Zenith.app by `scripts/bundle_app.sh`).
/// Which keys the code uses is checked by `scripts/check_localization.sh`, which needs the compiler.
@Suite("Localization tables")
struct LocalizationTableTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/ZenithCoreTests/SystemTests/LocalizationTableTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var tables: [URL] {
        let folder = repoRoot.appendingPathComponent("Localization")
        let languages = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return languages
            .filter { $0.pathExtension == "lproj" }
            .flatMap { lproj in
                ((try? FileManager.default.contentsOfDirectory(at: lproj, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "strings" }
            }
    }

    /// The argument types of a format string, in argument order (positional `%2$@` included); `%%` is not one.
    static func argumentTypes(_ format: String) -> [String]? {
        let pattern = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|ld|llu|lu|d|u|i|@|lf|f|%)")
        var sequential: [String] = []
        var positional: [Int: String] = [:]
        let ns = format as NSString
        for match in pattern.matches(in: format, range: NSRange(location: 0, length: ns.length)) {
            let type = ns.substring(with: match.range(at: 2))
            if type == "%" { continue }
            let normalized = ["ld": "lld", "d": "lld", "i": "lld", "u": "u", "lu": "llu", "llu": "llu"][type] ?? type
            if match.range(at: 1).location != NSNotFound, let index = Int(ns.substring(with: match.range(at: 1))) {
                positional[index] = normalized
            } else {
                sequential.append(normalized)
            }
        }
        if positional.isEmpty { return sequential }
        guard sequential.isEmpty else { return nil } // mixing both styles is an error
        return (1...max(1, positional.count)).map { positional[$0] ?? "missing" }
    }

    private static func load(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String], "\(url.lastPathComponent) is not a strings table")
    }

    @Test("L10N-01: Every table parses, has no duplicate keys and no empty translation")
    func testTablesParse() throws {
        #expect(!Self.tables.isEmpty)
        for url in Self.tables {
            let table = try Self.load(url)
            let text = try String(contentsOf: url, encoding: .utf8)
            let keyPattern = try NSRegularExpression(pattern: "^\"((?:[^\"\\\\]|\\\\.)*)\"\\s*=", options: .anchorsMatchLines)
            let keys = keyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range(at: 1), in: text)!])
            }
            let duplicates = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys
            #expect(duplicates.isEmpty, "\(url.path): duplicate keys \(Array(duplicates))")
            #expect(keys.count == table.count, "\(url.path): \(keys.count) lines, \(table.count) entries")
            for (key, value) in table where !key.isEmpty {
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(url.lastPathComponent): empty translation for \(key)")
            }
        }
    }

    @Test("L10N-02: A translation takes the same arguments as its key, in the same order")
    func testFormatArguments() throws {
        for url in Self.tables where url.lastPathComponent == "Localizable.strings" {
            for (key, value) in try Self.load(url) {
                let expected = Self.argumentTypes(key)
                let actual = Self.argumentTypes(value)
                #expect(actual != nil, "\(url.lastPathComponent): \(value) mixes %@ and %1$@")
                #expect(expected == actual, "\(url.lastPathComponent): \(key) → \(value): \(String(describing: expected)) vs \(String(describing: actual))")
            }
        }
    }

    @Test("L10N-03: The argument check itself reads positional and plain specifiers alike")
    func testArgumentParser() {
        #expect(Self.argumentTypes("Move %lld items to the Trash?") == ["lld"])
        #expect(Self.argumentTypes("Start a %lld-minute %@") == ["lld", "@"])
        #expect(Self.argumentTypes("Bắt đầu %2$@ %1$lld phút") == ["lld", "@"])
        #expect(Self.argumentTypes("Charging • %lld%%") == ["lld"])
        #expect(Self.argumentTypes("%1$@ and %@") == nil)
    }

    @Test("L10N-04: InfoPlist.strings only translates keys the bundle's Info.plist has")
    func testInfoPlistStrings() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/bundle_app.sh"), encoding: .utf8)
        #expect(script.contains("<key>CFBundleLocalizations</key>"))
        for url in Self.tables where url.lastPathComponent == "InfoPlist.strings" {
            for key in try Self.load(url).keys {
                #expect(script.contains("<key>\(key)</key>"), "\(url.path): \(key) is not in the Info.plist bundle_app.sh writes")
            }
        }
    }
}
