import Testing
import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
@testable import ZenithCore

// Text snippets: the matcher, the variables, the trigger rules and the key translation. Pure code, no event tap.

private func snippet(_ trigger: String, _ body: String = "body", name: String = "") -> Snippet {
    Snippet(name: name, trigger: trigger, body: body)
}

@Suite("Snippet matcher")
struct SnippetMatcherTests {
    @Test("SNP-01: typing a trigger fires once, asks to delete it, and empties the buffer")
    func firesOnTrigger() {
        var matcher = SnippetMatcher(snippets: [snippet(";sig", "Best")])
        var matches: [SnippetMatch] = []
        for character in "hello ;sig" {
            if let match = matcher.handle(.characters(String(character))) { matches.append(match) }
        }
        #expect(matches.count == 1)
        #expect(matches.first?.snippet.body == "Best")
        #expect(matches.first?.deleteCount == 4)
        #expect(matcher.buffer.isEmpty)
    }

    @Test("SNP-02: a reset in the middle of a trigger (click, arrow, app switch, shortcut) stops it")
    func resetBreaksTrigger() {
        var matcher = SnippetMatcher(snippets: [snippet(";sig")])
        _ = matcher.handle(.characters(";"))
        _ = matcher.handle(.characters("s"))
        _ = matcher.handle(.characters("i"))
        _ = matcher.handle(.reset)
        #expect(matcher.handle(.characters("g")) == nil)
    }

    @Test("SNP-03: backspace removes the last typed character, so a corrected trigger still fires")
    func backspaceCorrects() {
        var matcher = SnippetMatcher(snippets: [snippet(";sig")])
        for character in ";sx" { _ = matcher.handle(.characters(String(character))) }
        _ = matcher.handle(.backspace)
        _ = matcher.handle(.characters("i"))
        #expect(matcher.handle(.characters("g"))?.deleteCount == 4)
    }

    @Test("SNP-04: when one trigger is a suffix of another, the longer one wins")
    func longestSuffixWins() {
        let short = snippet("sig", "short")
        let long = snippet(";sig", "long")
        var matcher = SnippetMatcher(snippets: [short, long])
        var result: SnippetMatch?
        for character in ";sig" { result = matcher.handle(.characters(String(character))) ?? result }
        #expect(result?.snippet.body == "long")
        #expect(result?.deleteCount == 4)

        result = nil
        for character in "xsig" { result = matcher.handle(.characters(String(character))) ?? result }
        #expect(result?.snippet.body == "short")
        #expect(result?.deleteCount == 3)
    }

    @Test("SNP-05: the buffer never holds more than the longest trigger")
    func bufferIsBounded() {
        var matcher = SnippetMatcher(snippets: [snippet(";ab"), snippet(";abcd")])
        for character in String(repeating: "x", count: 500) { _ = matcher.handle(.characters(String(character))) }
        #expect(matcher.buffer.count == 5)
    }

    @Test("SNP-06: empty, spaced, too long and repeated triggers are left out; the first of a repeat keeps it")
    func invalidTriggersIgnored() {
        let first = snippet(";a", "first")
        let second = snippet(";a", "second")
        var matcher = SnippetMatcher(snippets: [
            snippet(""), snippet("a b"), snippet(String(repeating: "z", count: SnippetMatcher.maximumTriggerLength + 1)),
            first, second
        ])
        _ = matcher.handle(.characters(";"))
        #expect(matcher.handle(.characters("a"))?.snippet.body == "first")
        #expect(SnippetMatcher(snippets: [snippet(""), snippet("a b")]).isEmpty)
    }

    @Test("SNP-07: a typed line break cuts the buffer; the same trigger fires again when typed twice")
    func newlineAndRepeat() {
        var matcher = SnippetMatcher(snippets: [snippet(";x")])
        _ = matcher.handle(.characters(";"))
        _ = matcher.handle(.characters("\r"))
        #expect(matcher.handle(.characters("x")) == nil)

        var count = 0
        for character in ";x;x" where matcher.handle(.characters(String(character))) != nil { count += 1 }
        #expect(count == 2)
    }

    @Test("SNP-08: new snippets take effect at once; no snippets means nothing is remembered")
    func updateSnippets() {
        var matcher = SnippetMatcher()
        _ = matcher.handle(.characters("a"))
        #expect(matcher.buffer.isEmpty)
        matcher.update(snippets: [snippet("ab")])
        _ = matcher.handle(.characters("a"))
        #expect(matcher.handle(.characters("b")) != nil)
    }

    @Test("SNP-09: a trigger of non-Latin characters and emoji fires and deletes one per character")
    func unicodeTriggers() {
        var matcher = SnippetMatcher(snippets: [snippet("đc👍")])
        var result: SnippetMatch?
        for character in "xđc👍" { result = matcher.handle(.characters(String(character))) ?? result }
        #expect(result?.deleteCount == 3)
    }
}

@Suite("Snippet variables")
struct SnippetExpanderTests {
    /// 13 November 2026, 10:05:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_794_564_300)

    private func expander(clipboard: String? = "copied", locale: String = "en_US") -> SnippetExpander {
        SnippetExpander(
            now: { Self.fixedDate },
            clipboardText: { clipboard },
            locale: Locale(identifier: locale),
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test("SNP-10: {date}, {time} and {datetime} take a format; without one they follow the locale")
    func dates() {
        let e = expander()
        #expect(e.expand("{date:yyyy-MM-dd}").text == "2026-11-13")
        #expect(e.expand("{time:HH:mm}").text == "10:05")
        #expect(e.expand("{datetime:yyyy-MM-dd HH:mm}").text == "2026-11-13 10:05")
        #expect(e.expand("{date}").text == "Nov 13, 2026")
        let vietnamese = expander(locale: "vi_VN").expand("{date}").text
        #expect(vietnamese != "Nov 13, 2026")
        #expect(vietnamese.contains("2026"))
        let both = e.expand("{datetime}").text
        #expect(both.contains("2026") && both.contains("10:05"))
    }

    @Test("SNP-11: {clipboard} is the clipboard's text, or nothing when it holds none")
    func clipboard() {
        #expect(expander(clipboard: "abc").expand("[{clipboard}]").text == "[abc]")
        #expect(expander(clipboard: nil).expand("[{clipboard}]").text == "[]")
    }

    @Test("SNP-12: {cursor} is removed and says how far back the caret goes; only the first counts")
    func cursor() {
        let result = expander().expand("Hi {cursor}there{cursor}!")
        #expect(result.text == "Hi there!")
        #expect(result.caretOffsetFromEnd == 6)
        #expect(expander().expand("plain").caretOffsetFromEnd == 0)
        #expect(expander().expand("end{cursor}").caretOffsetFromEnd == 0)
    }

    @Test("SNP-13: unknown names, code braces and unclosed braces are kept as typed")
    func literalBraces() {
        let e = expander()
        #expect(e.expand("if (x) { y }").text == "if (x) { y }")
        #expect(e.expand("{foo} {clipboard:x}").text == "{foo} {clipboard:x}")
        #expect(e.expand("{{date:yyyy}}").text == "{2026}")
        #expect(e.expand("open {date").text == "open {date")
        #expect(e.expand("{DATE:yyyy}").text == "2026")
    }

    @Test("SNP-14: the clock and the clipboard are read once, and only when the body uses them")
    func readsSourcesOnce() {
        final class Counter: @unchecked Sendable { var clock = 0; var clipboard = 0 }
        let counter = Counter()
        let e = SnippetExpander(
            now: { counter.clock += 1; return Self.fixedDate },
            clipboardText: { counter.clipboard += 1; return "x" },
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        _ = e.expand("no variables")
        #expect(counter.clock == 0 && counter.clipboard == 0)
        _ = e.expand("{date} {time} {clipboard} {clipboard}")
        #expect(counter.clock == 1 && counter.clipboard == 1)
    }
}

@Suite("Snippet rules")
struct SnippetRulesTests {
    @Test("SNP-15: no expansion when off, in secure input, in Zenith, in clipboard-ignored or excluded apps")
    func gate() {
        func decide(
            enabled: Bool = true, secure: Bool = false, app: String? = "com.apple.TextEdit",
            ignored: [String] = ["com.1password.1password"], excluded: [String] = ["com.microsoft.VSCode"]
        ) -> SnippetExpansionDecision {
            SnippetExpansionGate.decide(
                isEnabled: enabled, isSecureInputOn: secure, frontmostBundleIdentifier: app,
                ownBundleIdentifier: "com.zenith.app", clipboardIgnoredApps: ignored, snippetExcludedApps: excluded
            )
        }
        #expect(decide() == .expand)
        #expect(decide(app: nil) == .expand)
        #expect(decide(enabled: false) == .disabled)
        #expect(decide(secure: true) == .secureInput)
        #expect(decide(app: "com.zenith.app") == .zenith)
        #expect(decide(app: "com.1Password.1password") == .clipboardIgnoredApp("com.1Password.1password"))
        #expect(decide(app: "com.microsoft.vscode") == .excludedApp("com.microsoft.vscode"))
    }

    @Test("SNP-16: key events become typing, backspace or a reset; Zenith's own keys and F-keys are ignored")
    func translator() {
        func input(_ keyCode: Int, _ characters: String, flags: CGEventFlags = [], keyDown: Bool = true, userData: Int64 = 0) -> SnippetKeyInput? {
            SnippetKeyEventTranslator.input(isKeyDown: keyDown, keyCode: Int64(keyCode), flags: flags, characters: characters, userData: userData)
        }
        #expect(input(kVK_ANSI_A, "a") == .characters("a"))
        #expect(input(kVK_ANSI_A, "å", flags: .maskAlternate) == .characters("å"))
        #expect(input(kVK_ANSI_A, "A", flags: .maskShift) == .characters("A"))
        #expect(input(kVK_ANSI_C, "c", flags: .maskCommand) == .reset)
        #expect(input(kVK_ANSI_A, "\u{1}", flags: .maskControl) == .reset)
        #expect(input(kVK_Delete, "\u{7F}") == .backspace)
        for key in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_Home] {
            #expect(input(key, "") == .reset)
        }
        #expect(input(0, "", keyDown: false) == .reset)   // a click
        #expect(input(kVK_Delete, "\u{7F}", userData: SnippetSyntheticEventMarker.userData) == nil)
        #expect(input(kVK_F5, "\u{F708}") == nil)
        #expect(input(kVK_ANSI_E, "") == nil)   // a dead key
    }

    @Test("SNP-17: Settings warns about spaces, repeats, length and a trigger that hides a longer one")
    func triggerIssues() {
        let a = Snippet(name: "A", trigger: ";s", body: "x")
        let b = Snippet(name: "B", trigger: ";sig", body: "x")
        let c = Snippet(name: "C", trigger: ";sig", body: "x")
        let spaced = Snippet(name: "D", trigger: "a b", body: "x")
        let long = Snippet(name: "E", trigger: String(repeating: "x", count: 40), body: "x")
        let all = [a, b, c, spaced, long]
        #expect(SnippetTriggerRules.issues(for: a, among: all) == [.hidesLongerTrigger(";sig")])
        #expect(SnippetTriggerRules.issues(for: b, among: all).isEmpty)
        #expect(SnippetTriggerRules.issues(for: c, among: all) == [.duplicate(of: "B")])
        #expect(SnippetTriggerRules.issues(for: spaced, among: all) == [.containsWhitespace])
        #expect(SnippetTriggerRules.issues(for: long, among: all) == [.tooLong])
        #expect(SnippetTriggerRules.issues(for: Snippet(name: "", trigger: "", body: "x"), among: all).isEmpty)
    }

    @Test("SNP-18: search ranks a trigger or name match first, then text, then letters in order")
    func search() {
        let sig = Snippet(name: "Signature", trigger: ";sig", body: "Best regards")
        let address = Snippet(name: "Home address", trigger: ";addr", body: "1 Infinite Loop")
        let meeting = Snippet(name: "Meeting notes", trigger: "", body: "Agenda: signing")
        let all = [meeting, address, sig]
        #expect(SnippetSearch.search("", in: all) == all)
        #expect(SnippetSearch.search(";sig", in: all).first == sig)
        #expect(SnippetSearch.search("sig", in: all) == [sig, meeting])
        #expect(SnippetSearch.search("hmadr", in: all) == [address])
        #expect(SnippetSearch.search("LOOP", in: all) == [address])
        #expect(SnippetSearch.search("zzz", in: all).isEmpty)
    }

    @Test("SNP-19: the snippet menu shortcut has a built-in default that is not a macOS screenshot key")
    func hotKey() {
        #expect(HotKeyDefinition.builtIn(for: HotKeyDefinition.snippetsMenuId) == HotKeyDefinition.defaultSnippetsMenu)
        #expect(HotKeyDefinition.defaultSnippetsMenu.menuStyleKeyEquivalent == "⌃⌥S")
        #expect(!HotKeyDefinition.defaultSnippetsMenu.clashesWithMacOSScreenshot)
        let others = [HotKeyDefinition.defaultClipboard, .defaultAreaCapture, .defaultFullscreenCapture, .defaultOCR]
        #expect(!others.contains { $0.keyCode == HotKeyDefinition.defaultSnippetsMenu.keyCode && $0.carbonModifiers == HotKeyDefinition.defaultSnippetsMenu.carbonModifiers })
    }
}
