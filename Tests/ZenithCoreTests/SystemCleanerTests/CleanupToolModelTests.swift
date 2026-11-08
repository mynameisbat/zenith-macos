import Testing
import Foundation
@testable import ZenithCore

@Suite("Cleanup Tool Model Suite")
struct CleanupToolModelTests {

    /// Remembers what a fake tool was asked to remove.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [[String]] = []
        var removed: [[String]] { lock.withLock { _removed } }
        func record(_ ids: [String]) { lock.withLock { _removed.append(ids) } }
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "disk is read-only" } }

    @MainActor
    private func makeModel(
        movesToTrash: Bool = true,
        recorder: Recorder = Recorder(),
        failing: Bool = false
    ) -> CleanupToolModel {
        let items = [
            CleanupCandidate(id: "a", title: "big", detail: "~/a", bytes: 3_000_000, isSelected: true),
            CleanupCandidate(id: "b", title: "small", detail: "~/b", bytes: 1_000, isSelected: true),
            CleanupCandidate(id: "c", title: "unticked", detail: "~/c", bytes: 500_000, isSelected: false)
        ]
        return CleanupToolModel(
            kind: .projects, title: "Test", explanation: "", actionTitle: movesToTrash ? "Move to Trash" : "Delete",
            movesToTrash: movesToTrash,
            scan: {
                // What is left once the fake has "removed" some ids.
                let gone: Set<String> = Set(recorder.removed.flatMap { $0 })
                return items.filter { candidate in !gone.contains(candidate.id) }
            },
            clean: { chosen in
                if failing { throw Boom() }
                recorder.record(chosen.map(\.id))
                return chosen.reduce(0) { $0 + $1.bytes }
            }
        )
    }

    @Test("CLN-01: A scan lists what the tool found and totals it; selection is the tool's own default")
    @MainActor
    func testScanAndSelection() async {
        let model = makeModel()
        #expect(model.hasScanned == false)
        await model.scan()
        #expect(model.hasScanned)
        #expect(model.candidates.map(\.id) == ["a", "b", "c"])
        #expect(model.selectedCandidates.map(\.id) == ["a", "b"])
        #expect(model.selectedBytes == 3_001_000)
        #expect(model.totalBytes == 3_501_000)

        model.setSelected(true, id: "c")
        model.setSelected(false, id: "a")
        #expect(model.selectedCandidates.map(\.id) == ["b", "c"])
        model.selectAll(false)
        #expect(model.selectedCandidates.isEmpty)
    }

    @Test("CLN-02: Declining the confirmation removes nothing")
    @MainActor
    func testDecliningRemovesNothing() async {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        await model.scan()
        var asked: CleanupConfirmation?

        let freed = await model.cleanSelected { confirmation in asked = confirmation; return false }

        #expect(freed == 0)
        #expect(recorder.removed.isEmpty)
        #expect(asked != nil)
        #expect(model.candidates.count == 3)
    }

    @Test("CLN-03: The confirmation names the largest items and says Trash or permanent")
    @MainActor
    func testConfirmationText() async {
        let trash = makeModel()
        await trash.scan()
        let first = trash.confirmation()
        #expect(first.title == "Move 2 items to the Trash?")
        #expect(first.actionTitle == "Move to Trash")
        #expect(first.message.contains("big"))
        #expect(first.message.contains("still restore"))
        #expect(!first.message.contains("unticked"))

        let permanent = makeModel(movesToTrash: false)
        await permanent.scan()
        let second = permanent.confirmation()
        #expect(second.actionTitle == "Delete")
        #expect(second.message.contains("cannot be restored"))
    }

    @Test("CLN-04: Only the ticked items are removed, and the list is rescanned afterwards")
    @MainActor
    func testRemovesOnlyTickedItems() async {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        await model.scan()

        let freed = await model.cleanSelected { _ in true }

        #expect(recorder.removed == [["a", "b"]])
        #expect(freed == 3_001_000)
        #expect(model.candidates.map(\.id) == ["c"])
        #expect(model.status == "Freed 3 MB.")
        #expect(model.isCleaning == false)
    }

    @Test("CLN-05: A failure is reported, not swallowed, and the list is rescanned")
    @MainActor
    func testFailureIsReported() async {
        let model = makeModel(failing: true)
        await model.scan()

        let freed = await model.cleanSelected { _ in true }

        #expect(freed == 0)
        #expect(model.status == "disk is read-only")
        #expect(model.candidates.count == 3)
    }

    @Test("CLN-06: With nothing ticked there is nothing to confirm or remove")
    @MainActor
    func testNothingTicked() async {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        await model.scan()
        model.selectAll(false)
        var asked = false

        let freed = await model.cleanSelected { _ in asked = true; return true }

        #expect(freed == 0)
        #expect(asked == false)
        #expect(recorder.removed.isEmpty)
    }

    // MARK: - The real services behind the four tools (in throwaway folders)

    private func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenith_cln_\(name)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("CLN-07: Projects: a rebuildable folder is listed, ticked, and goes to the Trash only when confirmed")
    @MainActor
    func testProjectsTool() async throws {
        let home = try temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/webapp")
        let modules = project.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "{}".write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 4096).write(to: modules.appendingPathComponent("lib.js"))
        // Idle for a while: a project touched this week would not be ticked (OVL-04).
        let longAgo = Date().addingTimeInterval(-40 * 86_400)
        for path in [modules.appendingPathComponent("lib.js").path, modules.path,
                     project.appendingPathComponent("package.json").path, project.path] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: path)
        }

        let service = ProjectPurgeService(homeDirectory: home.path, runner: { _, _ in nil })
        let root = home.appendingPathComponent("Projects").path
        let model = CleanupToolModel.projects(service: service, roots: { [root] })
        await model.scan()
        #expect(model.candidates.count == 1)
        #expect(model.candidates.first?.title == "webapp / node_modules")
        #expect(model.candidates.first?.isSelected == true)

        _ = await model.cleanSelected { _ in false }
        #expect(FileManager.default.fileExists(atPath: modules.path))
    }

    @Test("CLN-08: Installers: a mounted image is left out; the rest is listed")
    @MainActor
    func testInstallersTool() async throws {
        let dir = try temp("downloads")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 4096).write(to: dir.appendingPathComponent("Old.dmg"))

        let images = [] as [[String: Any]]
        let plist = try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
        let service = InstallerPurgeService(
            runCommand: { _, _ in SystemCommandResult(status: 0, output: String(decoding: plist, as: UTF8.self)) },
            zipMinSizeBytes: 100,
            now: { Date().addingTimeInterval(90 * 86_400) }
        )
        let model = CleanupToolModel.installers(service: service, directories: [dir])
        // The size floor of a real scan is 10 MB, so this 4 KB file is not offered.
        await model.scan()
        #expect(model.candidates.isEmpty)
        #expect(model.status == "Nothing to clean here.")
    }

    @Test("CLN-09: Leftovers: nothing is ticked for the user")
    @MainActor
    func testLeftoversTool() async throws {
        let library = try temp("library")
        defer { try? FileManager.default.removeItem(at: library) }
        let folder = library.appendingPathComponent("com.defunct.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("data.db"))

        let service = OrphanedAppLeftoversService(
            locations: [(library, "Application Support")], applicationRoots: [], isBundleIdentifierInUse: { _ in false }, minIdleDays: 0
        )
        let model = CleanupToolModel.leftovers(service: service)
        await model.scan()
        #expect(model.candidates.count == 1)
        #expect(model.selectedCandidates.isEmpty)
        #expect(model.movesToTrash)
    }

    @Test("CLN-10: Drives: junk files are deleted for good, and the wording says so")
    @MainActor
    func testDrivesTool() async throws {
        let volume = try temp("volume")
        defer { try? FileManager.default.removeItem(at: volume) }
        try Data(repeating: 1, count: 6148).write(to: volume.appendingPathComponent(".DS_Store"))
        try Data(repeating: 1, count: 100).write(to: volume.appendingPathComponent("photo.jpg"))

        let item = ExternalVolumeItem(
            name: "Backup", url: volume, totalCapacity: 1_000_000, availableCapacity: 500_000,
            isRemovable: true, phantomFileCount: 1, phantomBytes: 6148
        )
        let service = ExternalDriveSanitizerService(volumeProvider: { [volume] in [volume] })
        let model = CleanupToolModel.drives(service: service, discover: { [item] in [item] })
        await model.scan()
        #expect(model.candidates.map(\.title) == ["Backup"])
        #expect(model.movesToTrash == false)
        #expect(model.confirmation().actionTitle == "Delete")

        _ = await model.cleanSelected { _ in true }
        #expect(!FileManager.default.fileExists(atPath: volume.appendingPathComponent(".DS_Store").path))
        #expect(FileManager.default.fileExists(atPath: volume.appendingPathComponent("photo.jpg").path))
    }
}

@Suite("Project Search Roots Suite")
struct ProjectSearchRootsTests {
    @Test("CLN-11: The usual folders come first; added ones follow, once, and can be removed")
    func testRoots() throws {
        let defaults = try #require(TestDefaults.make("project_roots_\(UUID().uuidString)"))
        let home = "/Users/someone"
        #expect(ProjectSearchRoots.current(defaults: defaults, home: home).first == "/Users/someone/Projects")

        ProjectSearchRoots.add("/Volumes/Work/Code/", defaults: defaults)
        ProjectSearchRoots.add("/Volumes/Work/Code", defaults: defaults)
        #expect(ProjectSearchRoots.custom(defaults: defaults) == ["/Volumes/Work/Code"])
        #expect(ProjectSearchRoots.current(defaults: defaults, home: home).last == "/Volumes/Work/Code")

        ProjectSearchRoots.remove("/Volumes/Work/Code", defaults: defaults)
        #expect(ProjectSearchRoots.custom(defaults: defaults).isEmpty)
    }
}
