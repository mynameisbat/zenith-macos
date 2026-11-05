import Testing
import Foundation
@testable import ZenithCore

@Suite("Trash Mover Suite")
struct TrashMoverTests {

    private let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    private let url = URL(fileURLWithPath: "/Users/someone/Library/Containers/com.defunct.app")

    /// Remembers the commands the mover ran.
    final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: [[String]] = []
        var list: [[String]] { lock.withLock { _list } }
        func record(_ arguments: [String]) { lock.withLock { _list.append(arguments) } }
    }

    @Test("TRM-01: A move that works never involves Finder")
    func testDirectMove() throws {
        let commands = Commands()
        let mover = TrashMover(trashDirectly: { _ in }, runCommand: { _, args in commands.record(args); return nil }, itemExists: { _ in true })
        try mover.move(url)
        #expect(commands.list.isEmpty)
    }

    @Test("TRM-02: A permission refusal is retried through Finder, and succeeds when the item is gone afterwards")
    func testFinderFallback() throws {
        let commands = Commands()
        let mover = TrashMover(
            trashDirectly: { _ in throw permissionError },
            runCommand: { _, args in commands.record(args); return SystemCommandResult(status: 0, output: "") },
            itemExists: { _ in false }
        )
        try mover.move(url)
        #expect(commands.list.count == 1)
        let script = commands.list[0].last ?? ""
        #expect(script.contains("tell application \"Finder\" to delete (POSIX file \"/Users/someone/Library/Containers/com.defunct.app\")"))
        #expect(script.contains("with timeout of 20 seconds"))
    }

    @Test("TRM-03: If Finder is refused too, or the item is still there, the error explains what to do")
    func testBothRefused() {
        let declined = TrashMover(
            trashDirectly: { _ in throw permissionError },
            runCommand: { _, _ in SystemCommandResult(status: 1, output: "", errorOutput: "not allowed assistive access (-1743)") },
            itemExists: { _ in true }
        )
        #expect(throws: TrashMover.Failure.protectedByMacOS(name: "com.defunct.app")) { try declined.move(url) }

        let silentlyFailed = TrashMover(
            trashDirectly: { _ in throw permissionError },
            runCommand: { _, _ in SystemCommandResult(status: 0, output: "") },
            itemExists: { _ in true }                       // Finder said yes but the folder is still there
        )
        #expect(throws: TrashMover.Failure.protectedByMacOS(name: "com.defunct.app")) { try silentlyFailed.move(url) }

        let noOsascript = TrashMover(trashDirectly: { _ in throw permissionError }, runCommand: { _, _ in nil }, itemExists: { _ in true })
        #expect(throws: TrashMover.Failure.protectedByMacOS(name: "com.defunct.app")) { try noOsascript.move(url) }

        let message = TrashMover.Failure.protectedByMacOS(name: "com.defunct.app").errorDescription ?? ""
        #expect(message.contains("com.defunct.app"))
        #expect(message.contains("Finder"))
        #expect(message.contains("Full Disk Access"))
    }

    @Test("TRM-04: Any other failure is passed on as it is, with no Finder attempt")
    func testOtherErrorsPassThrough() {
        let commands = Commands()
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let mover = TrashMover(trashDirectly: { _ in throw missing }, runCommand: { _, args in commands.record(args); return nil }, itemExists: { _ in true })
        #expect(throws: (any Error).self) { try mover.move(url) }
        #expect(commands.list.isEmpty)
    }

    @Test("TRM-05: A path with quotes or backslashes cannot break out of the AppleScript string")
    func testScriptEscaping() {
        let script = TrashMover.finderScript(for: "/Users/x/Library/Containers/a\"b\\c")
        #expect(script.contains("POSIX file \"/Users/x/Library/Containers/a\\\"b\\\\c\""))
    }

    @Test("TRM-06: The leftovers purge reports what could not be moved, with the reason, and still moves the rest")
    func testLeftoversPurgeReportsFailures() async throws {
        let fm = FileManager.default
        let library = fm.temporaryDirectory.appendingPathComponent("zenith_trm_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: library) }
        let old = Date().addingTimeInterval(-90 * 86_400)
        for name in ["com.defunct.fine", "com.defunct.protected"] {
            let folder = library.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("data.db")
            try Data(count: 4096).write(to: file)
            for path in [file.path, folder.path] { try fm.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: path) }
        }
        let denied = permissionError
        let mover = TrashMover(
            trashDirectly: { target in
                if target.lastPathComponent == "com.defunct.protected" { throw denied }
                try FileManager.default.removeItem(at: target)       // stands in for the Trash in this test
            },
            runCommand: { _, _ in SystemCommandResult(status: 1, output: "") },
            itemExists: { _ in true }
        )
        let service = OrphanedAppLeftoversService(
            locations: [(library, "Containers")], applicationRoots: [], isBundleIdentifierInUse: { _ in false },
            minIdleDays: 0, trashMover: mover
        )
        let items = await service.scan()
        #expect(items.count == 2)

        do {
            _ = try await service.purge(items: items, moveToTrash: true)
            Issue.record("expected a failure for the protected folder")
        } catch let error as OrphanedAppLeftoversService.PurgeError {
            guard case .someFailed(let moved, let failed, let reason) = error else { return }
            #expect(moved == 1 && failed == 1)
            #expect(reason.contains("com.defunct.protected"))
            #expect((error.errorDescription ?? "").hasPrefix("1 moved. 1 could not be moved."))
        }
        #expect(!fm.fileExists(atPath: library.appendingPathComponent("com.defunct.fine").path))
        #expect(fm.fileExists(atPath: library.appendingPathComponent("com.defunct.protected").path))
    }
}
