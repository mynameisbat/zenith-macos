import Testing
import Foundation
@testable import ZenithCore

/// The `Minimum macOS: 26.0` line in a release's notes, and how it reaches the parsed release.
@Suite("Updater: minimum macOS marker")
struct MinimumSystemMarkerTests {
    private func version(_ notes: String?) -> String? {
        MinimumSystemMarker.parse(releaseNotes: notes)?.description
    }

    @Test("UPD-M01: The documented line, alone or among other notes")
    func testDocumentedLine() {
        #expect(version("Minimum macOS: 26.0") == "26.0")
        #expect(version("## What's new\n\n- Faster island\n\nMinimum macOS: 26.0\n\nThanks!") == "26.0")
        #expect(version("Intro\r\nMinimum macOS: 15.6.1\r\nOutro") == "15.6.1")
        #expect(version("Minimum macOS: 26") == "26")
        #expect(MinimumSystemMarker.line(for: AppVersion("26.0")!) == "Minimum macOS: 26.0")
        #expect(version(MinimumSystemMarker.line(for: AppVersion("26.0")!)) == "26.0")
    }

    @Test("UPD-M02: Tolerant of case, white space, Markdown emphasis, code ticks and list or quote markers")
    func testTolerance() {
        for line in [
            "minimum macos: 26.0", "MINIMUM MACOS: 26.0", "  Minimum   macOS :  26.0  ", "Minimum macOS:26.0",
            "**Minimum macOS:** 26.0", "**Minimum macOS**: 26.0", "_Minimum macOS: 26.0_", "- Minimum macOS: 26.0",
            "* Minimum macOS: `26.0`", "> Minimum macOS: 26.0", "\tMinimum macOS: 26.0", "Minimum\u{00A0}macOS: 26.0"
        ] {
            #expect(version(line) == "26.0", "\(line)")
        }
    }

    @Test("UPD-M03: Anything else states nothing")
    func testNotAMarker() {
        for notes in [
            nil, "", "No marker here", "Needs macOS 26", "Minimum macOS", "Minimum macOS:", "Minimum macOS: soon",
            "Minimum macOS: 26.0-beta", "Minimum macOS: v26", "Minimum macOS: 26.0.0.0", "Minimum macOS: 0", "Minimum macOS: -26",
            "Minimum macOS version: 26.0", "Minimum: 26.0", "The Minimum macOS: 26.0 is required",
            "Minimum macOS: " + String(repeating: "9", count: 200)
        ] as [String?] {
            #expect(version(notes) == nil, "\(notes ?? "nil")")
        }
    }

    @Test("UPD-M04: The first valid line wins; an unreadable one before it is skipped")
    func testFirstWins() {
        #expect(version("Minimum macOS: 26.0\nMinimum macOS: 15.0") == "26.0")
        #expect(version("Minimum macOS: later\nMinimum macOS: 15.6") == "15.6")
    }

    // MARK: - From the feed

    private static let url = "https://github.com/mynameisbat/zenith-macos/releases/download/v3.0.0/Zenith-3.0.0.dmg"

    private func parse(body: Any?) throws -> UpdateRelease {
        var object: [String: Any] = [
            "tag_name": "v3.0.0", "draft": false, "prerelease": false,
            "assets": [["name": "Zenith-3.0.0.dmg", "size": 4_000_000, "browser_download_url": Self.url]]
        ]
        if let body { object["body"] = body }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .release(let release) = try UpdateReleaseParser.parse(data) else {
            Issue.record("expected a release")
            throw UpdateFeedError.malformedResponse
        }
        return release
    }

    @Test("UPD-M05: The release carries the minimum from its notes; no notes, no marker or a non-string body state none")
    func testReleaseCarriesMinimum() throws {
        #expect(try parse(body: "Big release.\n\nMinimum macOS: 26.0").minimumSystemVersion == AppVersion("26.0"))
        #expect(try parse(body: "Big release.").minimumSystemVersion == nil)
        #expect(try parse(body: nil).minimumSystemVersion == nil)
        #expect(try parse(body: NSNull()).minimumSystemVersion == nil)
        // A wrongly typed body would fail a strict decode of the whole release; it must not take the update down.
        #expect(try parse(body: 42).minimumSystemVersion == nil)
    }

    @Test("UPD-M06: A release without a stated minimum is compatible with any macOS")
    func testUnstatedIsCompatible() throws {
        let release = try parse(body: "Old style notes")
        #expect(release.isCompatible(withSystem: AppVersion("10.15")!))
        let strict = try parse(body: "Minimum macOS: 26.0")
        #expect(!strict.isCompatible(withSystem: AppVersion("15.6")!))
        #expect(strict.isCompatible(withSystem: AppVersion("26.0")!))
    }
}
