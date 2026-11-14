import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import ZenithCore

// Snippet storage (a temporary folder), insertion (a private pasteboard, recorded key presses, a manual clock) and
// the service (a mock key source). No event tap is created, no key is pressed, the general pasteboard is not used.

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("zenith-snippets-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Suite("Snippet storage")
struct SnippetStorageTests {
    @Test("SNP-20: a first launch shows the examples without writing a file; an edit saves, a new library reads it")
    func firstLaunchAndSave() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SnippetLibrary(directory: folder)
        #expect(library.snippets.map(\.trigger) == SnippetLibrary.examples.map(\.trigger))
        #expect(!FileManager.default.fileExists(atPath: library.fileURL.path))

        let added = Snippet(name: "Addr", trigger: ";addr", body: "1 Main St")
        library.add(added)
        #expect(FileManager.default.fileExists(atPath: library.fileURL.path))

        var edited = added
        edited.body = "2 Main St"
        library.update(edited)
        library.delete(id: library.snippets[0].id)

        let reloaded = SnippetLibrary(directory: folder)
        #expect(reloaded.snippets == library.snippets)
        #expect(reloaded.snippet(id: added.id)?.body == "2 Main St")
        #expect(reloaded.lastError == nil)
    }

    @Test("SNP-21: export and import round-trip; an import replaces by id or trigger and adds the rest")
    func importExport() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SnippetLibrary(directory: folder)
        let existing = library.snippets
        let exported = try library.exportData()
        #expect(try SnippetLibraryFile.decode(exported) == existing)

        // A hand-written bare array: no ids, one trigger already in use.
        let json = #"[{"name":"New sig","trigger":";sig","body":"Cheers"},{"trigger":";hi","body":"Hello {clipboard}"}]"#
        let result = try library.importSnippets(from: Data(json.utf8))
        #expect(result == SnippetImportResult(added: 1, replaced: 1))
        let sig = library.snippets.first { $0.trigger == ";sig" }
        #expect(sig?.body == "Cheers")
        #expect(sig?.id == existing.first { $0.trigger == ";sig" }?.id)
        #expect(library.snippets.count == existing.count + 1)

        // Importing the export again changes nothing but replaces each by id.
        let again = try library.importSnippets(from: library.exportData())
        #expect(again == SnippetImportResult(added: 0, replaced: library.snippets.count))
    }

    @Test("SNP-22: a file that is not snippets is refused and nothing changes; a damaged library file is kept")
    func badFiles() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SnippetLibrary(directory: folder)
        let before = library.snippets
        #expect(throws: SnippetLibraryError.self) {
            try library.importSnippets(from: Data("{\"hello\": 1}".utf8))
        }
        #expect(library.snippets == before)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let damaged = Data("not json".utf8)
        try damaged.write(to: library.fileURL)
        let reopened = SnippetLibrary(directory: folder)
        #expect(reopened.snippets.isEmpty)
        #expect(reopened.lastError != nil)
        #expect(try Data(contentsOf: reopened.fileURL) == damaged)
    }

    @Test("SNP-23: typed expansion is off by default; excluded apps are saved, without repeats")
    func settings() {
        let defaults = TestDefaults.make("snippets-\(UUID().uuidString)")!
        let settings = SnippetSettings(userDefaults: defaults)
        #expect(!settings.isTypedExpansionEnabled)
        #expect(settings.addExcludedApp(bundleIdentifier: "com.microsoft.VSCode"))
        #expect(!settings.addExcludedApp(bundleIdentifier: "com.microsoft.vscode"))
        #expect(!settings.addExcludedApp(bundleIdentifier: " "))
        settings.isTypedExpansionEnabled = true

        let reloaded = SnippetSettings(userDefaults: defaults)
        #expect(reloaded.isTypedExpansionEnabled)
        #expect(reloaded.excludedAppBundleIdentifiers == ["com.microsoft.VSCode"])
        reloaded.removeExcludedApp(bundleIdentifier: "COM.microsoft.vscode")
        #expect(reloaded.excludedAppBundleIdentifiers.isEmpty)
    }

    @Test("SNP-24: the Permissions page reports typed expansion as on or off from its switch")
    func permissionsMapping() {
        let defaults = TestDefaults.make("snippets-activity-\(UUID().uuidString)")!
        let settings = SnippetSettings(userDefaults: defaults)
        let widgets = IslandWidgetSettings(userDefaults: TestDefaults.make("snippets-widgets-\(UUID().uuidString)")!, island: nil)
        let activity = LiveFeatureActivity(widgets: widgets, snippets: settings)
        #expect(ZenithPermissionFeature.snippetExpansion.permission == .accessibility)
        #expect(activity.activity(for: .snippetExpansion) == .off)
        settings.isTypedExpansionEnabled = true
        #expect(activity.activity(for: .snippetExpansion) == .on)
    }

    @Test("SNP-25: the editor blocks a repeated trigger, previews the caret, and saves into the library")
    func editor() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SnippetLibrary(directory: folder)
        let expander = SnippetExpander(now: { Date() }, clipboardText: { "CLIP" })
        let editor = SnippetEditorModel(snippet: nil, library: library) { expander.expand($0.body) }
        editor.trigger = ";sig"   // an example uses it
        editor.body = "Hi {clipboard}{cursor}!"
        #expect(!editor.canSave)
        #expect(editor.previewText == "Hi CLIP|!")
        editor.trigger = ";new"
        #expect(editor.canSave)
        #expect(editor.save())
        #expect(library.snippet(id: editor.id)?.trigger == ";new")
    }

    @Test("SNP-26: the snippet menu keeps its selection inside the results and starts over on a new search")
    func picker() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SnippetLibrary(directory: folder)
        let picker = SnippetPickerModel(library: library)
        let count = picker.results.count
        #expect(count >= 2)
        picker.moveSelection(by: 10)
        #expect(picker.selected == picker.results.last)
        picker.moveSelection(by: -10)
        #expect(picker.selected == picker.results.first)
        picker.moveSelection(by: 1)
        picker.query = "date"
        #expect(picker.selectedIndex == 0)
        #expect(picker.selected?.trigger == ";date")
        picker.query = "nothing like this"
        #expect(picker.selected == nil)
    }
}

// MARK: - Insertion

private final class RecordingPaster: AutoPasteServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var seen: [String?] = []
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    var pasteCount: Int { lock.withLock { count } }
    /// What the clipboard held at each ⌘V.
    var pastedTexts: [String?] { lock.withLock { seen } }

    func paste() -> Bool {
        let text = pasteboard.string(forType: .string)
        lock.withLock { count += 1; seen.append(text) }
        return true
    }
}

@MainActor
@Suite("Snippet insertion")
struct SnippetInserterTests {
    private struct Fixture {
        let pasteboard: NSPasteboard
        let paster: RecordingPaster
        let keys: RecordingSnippetKeyPoster
        let scheduler: ManualClipboardScheduler
        let inserter: SnippetInserter
        let ownWrites: OwnWrites
    }

    final class OwnWrites { var counts: [Int] = [] }

    private func makeFixture(trusted: Bool = true) -> Fixture {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = RecordingPaster(pasteboard: pasteboard)
        let keys = RecordingSnippetKeyPoster()
        let scheduler = ManualClipboardScheduler()
        let writes = OwnWrites()
        let inserter = SnippetInserter(
            pasteboard: pasteboard, paster: paster, keys: keys, isTrusted: { trusted },
            scheduler: scheduler, onOwnWrite: { writes.counts.append($0) }
        )
        return Fixture(pasteboard: pasteboard, paster: paster, keys: keys, scheduler: scheduler, inserter: inserter, ownWrites: writes)
    }

    /// The user's own copy: plain text and rich text.
    private func userCopy(_ text: String, on pasteboard: NSPasteboard) -> Data {
        let rtf = Data("{\\rtf1 \(text)}".utf8)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(rtf, forType: .rtf)
        return rtf
    }

    @Test("SNP-27: deletes the trigger, pastes the text marked as transient, moves the caret, then restores the clipboard")
    func fullInsertion() {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        let rtf = userCopy("user copy", on: f.pasteboard)

        let result = f.inserter.insert(SnippetExpansion(text: "Hello there", caretOffsetFromEnd: 5), deletingCharacters: 4)
        #expect(result == .inserted)
        #expect(f.keys.pressedKeys == Array(repeating: SnippetKeyCode.delete, count: 4))
        #expect(f.paster.pastedTexts == ["Hello there"])
        let types = f.pasteboard.types ?? []
        #expect(types.contains(SensitivePasteboardMarker.transientType))
        #expect(ClipboardCapturePolicy.decide(types: types.map(\.rawValue), frontmostBundleIdentifier: nil, options: .init()) == .skipSensitive)
        #expect(f.ownWrites.counts == [f.pasteboard.changeCount])

        f.scheduler.advance(by: SnippetInserter.caretDelay)
        #expect(f.keys.pressedKeys.filter { $0 == SnippetKeyCode.leftArrow }.count == 5)

        f.scheduler.advance(by: SnippetInserter.restoreDelay)
        #expect(f.pasteboard.string(forType: .string) == "user copy")
        #expect(f.pasteboard.data(forType: .rtf) == rtf)
        #expect(!(f.pasteboard.types ?? []).contains(SensitivePasteboardMarker.transientType))
        #expect(f.ownWrites.counts.count == 2)
        #expect(f.ownWrites.counts.last == f.pasteboard.changeCount)
        #expect(!f.inserter.isRestorePending)
    }

    @Test("SNP-28: a copy the user makes before the restore is kept")
    func userCopyWins() {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        _ = userCopy("old", on: f.pasteboard)
        f.inserter.insert(SnippetExpansion(text: "snippet"), deletingCharacters: 0)
        _ = userCopy("newer copy", on: f.pasteboard)
        f.scheduler.advance(by: 1)
        #expect(f.pasteboard.string(forType: .string) == "newer copy")
        #expect(f.ownWrites.counts.count == 1)
    }

    @Test("SNP-29: two snippets in a row put back the user's clipboard, not the first snippet")
    func twoInARow() {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        _ = userCopy("mine", on: f.pasteboard)
        f.inserter.insert(SnippetExpansion(text: "one"), deletingCharacters: 2)
        #expect(f.inserter.userClipboardText() == "mine")
        f.scheduler.advance(by: 0.1)
        f.inserter.insert(SnippetExpansion(text: "two"), deletingCharacters: 2)
        #expect(f.paster.pastedTexts == ["one", "two"])
        f.scheduler.advance(by: 1)
        #expect(f.pasteboard.string(forType: .string) == "mine")
        #expect(f.scheduler.pendingCount == 0)
    }

    @Test("SNP-30: without Accessibility nothing is pressed or written")
    func untrusted() {
        let f = makeFixture(trusted: false)
        defer { f.pasteboard.releaseGlobally() }
        _ = userCopy("mine", on: f.pasteboard)
        let count = f.pasteboard.changeCount
        #expect(f.inserter.insert(SnippetExpansion(text: "x"), deletingCharacters: 3) == .notTrusted)
        #expect(f.keys.pressedKeys.isEmpty)
        #expect(f.paster.pasteCount == 0)
        #expect(f.pasteboard.changeCount == count)
    }

    @Test("SNP-31: an empty clipboard stays empty; a very long caret move is skipped; restoreNow restores at once")
    func edges() {
        let f = makeFixture()
        defer { f.pasteboard.releaseGlobally() }
        f.pasteboard.clearContents()
        f.inserter.insert(SnippetExpansion(text: "x", caretOffsetFromEnd: SnippetInserter.maximumCaretMoves + 1), deletingCharacters: 0)
        f.inserter.restoreNow()
        #expect(f.pasteboard.string(forType: .string) == nil)
        f.scheduler.advance(by: 1)
        #expect(f.keys.pressedKeys.isEmpty)
    }

    @Test("SNP-32: the pasteboard monitor does not record a write Zenith marks as its own")
    func monitorSkipsOwnWrite() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: pasteboard, pollingInterval: 60)
        final class Seen { var counts: [Int] = [] }
        let seen = Seen()
        monitor.changeObserver = { seen.counts.append($0) }
        monitor.startMonitoring { _ in }
        defer { monitor.stopMonitoring() }

        pasteboard.clearContents()
        pasteboard.setString("snippet", forType: .string)
        monitor.markOwnWrite(changeCount: pasteboard.changeCount)
        monitor.checkForChanges()
        #expect(seen.counts.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("user", forType: .string)
        monitor.checkForChanges()
        #expect(seen.counts == [pasteboard.changeCount])
    }
}

// MARK: - Service

@MainActor
private final class RecordingInserter: SnippetInserting {
    var inserted: [(expansion: SnippetExpansion, deleteCount: Int)] = []
    var clipboard: String? = "CLIP"
    var restoreCount = 0

    func insert(_ expansion: SnippetExpansion, deletingCharacters deleteCount: Int) -> SnippetInsertionResult {
        inserted.append((expansion, deleteCount))
        return .inserted
    }

    func userClipboardText() -> String? { clipboard }
    func restoreNow() { restoreCount += 1 }
}

@MainActor
@Suite("Snippet expansion service")
struct SnippetExpansionServiceTests {
    private final class World {
        var frontmost: String? = "com.apple.TextEdit"
        var secure = false
        var ignored = ["com.1password.1password"]
    }

    private struct Fixture {
        let library: SnippetLibrary
        let settings: SnippetSettings
        let source: MockSnippetKeySource
        let inserter: RecordingInserter
        let world: World
        let service: SnippetExpansionService
        let folder: URL
    }

    private func makeFixture(enabled: Bool = true, allowsStart: Bool = true) -> Fixture {
        let folder = temporaryFolder()
        let library = SnippetLibrary(directory: folder)
        library.add(Snippet(name: "Greeting", trigger: ";hi", body: "Hello {clipboard}{cursor}!"))
        let settings = SnippetSettings(userDefaults: TestDefaults.make("snippet-service-\(UUID().uuidString)")!)
        settings.isTypedExpansionEnabled = enabled
        let source = MockSnippetKeySource(allowsStart: allowsStart)
        let inserter = RecordingInserter()
        let world = World()
        let service = SnippetExpansionService(
            library: library, settings: settings, keySource: source, inserter: inserter,
            frontmostBundleIdentifier: { world.frontmost },
            isSecureInputOn: { world.secure },
            clipboardIgnoredApps: { world.ignored },
            ownBundleIdentifier: "com.zenith.app",
            deferExpansion: false
        )
        service.refresh()
        return Fixture(library: library, settings: settings, source: source, inserter: inserter, world: world, service: service, folder: folder)
    }

    @Test("SNP-33: a typed trigger is replaced by the expanded snippet")
    func expandsTypedTrigger() {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        #expect(f.service.isListening)
        f.source.type("ok ;hi")
        #expect(f.inserter.inserted.count == 1)
        #expect(f.inserter.inserted.first?.deleteCount == 3)
        #expect(f.inserter.inserted.first?.expansion == SnippetExpansion(text: "Hello CLIP!", caretOffsetFromEnd: 1))
        #expect(f.service.lastDecision == .expand)
    }

    @Test("SNP-34: nothing expands in secure input, in Zenith, or in ignored or excluded apps")
    func respectsExclusions() {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        f.world.secure = true
        f.source.type(";hi")
        #expect(f.service.lastDecision == .secureInput)
        f.world.secure = false

        f.world.frontmost = "com.zenith.app"
        f.source.type(";hi")
        #expect(f.service.lastDecision == .zenith)

        f.world.frontmost = "com.1password.1password"
        f.source.type(";hi")
        #expect(f.service.lastDecision == .clipboardIgnoredApp("com.1password.1password"))

        f.settings.addExcludedApp(bundleIdentifier: "com.apple.Terminal")
        f.world.frontmost = "com.apple.Terminal"
        f.source.type(";hi")
        #expect(f.service.lastDecision == .excludedApp("com.apple.Terminal"))
        #expect(f.inserter.inserted.isEmpty)
    }

    @Test("SNP-35: turning typed expansion off stops the key source; it is not started while off")
    func onOff() {
        let f = makeFixture(enabled: false)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        #expect(f.source.startCount == 0)
        #expect(!f.service.isListening)
        f.settings.isTypedExpansionEnabled = true
        f.service.refresh()
        #expect(f.service.isListening)
        f.settings.isTypedExpansionEnabled = false
        f.service.refresh()
        #expect(!f.source.isRunning)
        #expect(!f.service.isListening)
        f.service.stop()
        #expect(f.inserter.restoreCount == 1)
    }

    @Test("SNP-36: without Accessibility the service says so instead of listening")
    func needsAccessibility() {
        let f = makeFixture(allowsStart: false)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        #expect(!f.service.isListening)
        #expect(f.service.needsAccessibility)
        f.source.allowsStart = true
        f.service.refresh()
        #expect(f.service.isListening)
        #expect(!f.service.needsAccessibility)
    }

    @Test("SNP-37: a new snippet expands at once; the menu inserts without deleting anything")
    func libraryChangesAndMenu() {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        f.library.add(Snippet(name: "Bye", trigger: ";by", body: "Goodbye"))
        f.source.type(";by")
        #expect(f.inserter.inserted.last?.expansion.text == "Goodbye")

        let menuSnippet = Snippet(name: "Menu", trigger: "", body: "From the menu")
        #expect(f.service.insertFromMenu(menuSnippet) == .inserted)
        #expect(f.inserter.inserted.last?.deleteCount == 0)
        #expect(f.inserter.inserted.last?.expansion.text == "From the menu")
    }
}
