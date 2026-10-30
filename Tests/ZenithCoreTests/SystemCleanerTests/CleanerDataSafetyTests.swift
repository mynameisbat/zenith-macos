import Testing
import Foundation
@testable import ZenithCore

@Suite("Cleaner, Purge and Sanitizer Data Safety Suite")
struct CleanerDataSafetyTests {

    // MARK: - Helpers

    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int = 4_096, contents: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents ?? Data(repeating: 0x41, count: bytes)).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - System cleaner

    @Test("SAFE-01: Docker's VM disk (every image, container and volume) is never offered for cleaning")
    @MainActor
    func testDockerDataIsNeverOffered() async throws {
        let home = try makeTempDirectory("CleanHome")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"))
        try write(home.appendingPathComponent("Library/Caches/Homebrew/downloads/package.tar.gz"))

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let offered = service.categories.flatMap { $0.items.map(\.path) }

        #expect(offered.contains { $0.hasSuffix("Library/Caches/Homebrew") })          // real caches still are
        #expect(!offered.contains { $0.contains("com.docker.docker") })

        // And even if something offered it, the deletion guard refuses.
        let dockerPath = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms").path
        #expect(SystemCleanerService.isPathSafeForDeletion(dockerPath, home: home.path) == false)
        #expect(SystemCleanerService.isPathSafeForDeletion(dockerPath + "/0/data/Docker.raw", home: home.path) == false)
    }

    @Test("SAFE-02: The Trash is the user's data, so it is listed but not selected")
    @MainActor
    func testTrashIsOptIn() async throws {
        let home = try makeTempDirectory("CleanHome")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home.appendingPathComponent(".Trash/old-report.pdf"))
        try write(home.appendingPathComponent("Library/Caches/Homebrew/downloads/package.tar.gz"))

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()

        let trash = try #require(service.categories.first { $0.id == "user_trash" })
        #expect(!trash.isSelected)
        #expect(trash.items.allSatisfy { !$0.isSelected })
        #expect(trash.totalSize > 0)
        #expect(service.selectedJunkSize == service.totalJunkSize - trash.totalSize)
        #expect(!service.selectionSummary.contains("Trash"))
    }

    @Test("SAFE-03: Cleaning removes selected caches and leaves the Trash and Docker data alone")
    @MainActor
    func testCleanLeavesUnselectedAndProtectedData() async throws {
        let home = try makeTempDirectory("CleanHome")
        defer { try? FileManager.default.removeItem(at: home) }
        let brew = home.appendingPathComponent("Library/Caches/Homebrew")
        let trashed = home.appendingPathComponent(".Trash/old-report.pdf")
        let dockerDisk = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        try write(brew.appendingPathComponent("downloads/package.tar.gz"))
        try write(trashed)
        try write(dockerDisk)

        let service = SystemCleanerService(homeDirectory: home.path)
        await service.scan()
        let freed = await service.cleanSelected()

        #expect(freed > 0)
        #expect(!exists(brew))
        #expect(exists(trashed))
        #expect(exists(dockerDisk))
    }

    @Test("SAFE-04: A symlinked folder between the root and the item cannot redirect a deletion; a symlinked root is fine")
    func testIntermediateSymlinksAreRefused() throws {
        let home = try makeTempDirectory("CleanHome")
        let outside = try makeTempDirectory("Outside")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        let fm = FileManager.default

        // ~/.cache/sneaky -> a folder that is not a cache
        try fm.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try write(outside.appendingPathComponent("precious/thesis.docx"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache/sneaky"), withDestinationURL: outside.appendingPathComponent("precious"))
        #expect(SystemCleanerService.isPathSafeForDeletion(home.path + "/.cache/sneaky/thesis.docx", home: home.path) == false)

        // An ordinary subfolder of the same root is fine.
        try write(home.appendingPathComponent(".cache/real/blob"))
        #expect(SystemCleanerService.isPathSafeForDeletion(home.path + "/.cache/real/blob", home: home.path) == true)

        // The root itself being a symlink (a cache moved to another drive) is a legitimate setup.
        try write(outside.appendingPathComponent("npm/_cacache/index"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".npm"), withDestinationURL: outside.appendingPathComponent("npm"))
        #expect(SystemCleanerService.isPathSafeForDeletion(home.path + "/.npm/_cacache", home: home.path) == true)
    }

    // MARK: - Project purge

    private func gitRunner(ignoring ignored: Set<String>) -> SystemCommandRunner {
        { executable, arguments in
            guard executable == "/usr/bin/git", arguments.contains("check-ignore"), let name = arguments.last else { return nil }
            return SystemCommandResult(status: ignored.contains(name) ? 0 : 1, output: "")
        }
    }

    private func makeWorkspace() throws -> (home: URL, projects: URL) {
        let home = try makeTempDirectory("PurgeHome")
        let projects = home.appendingPathComponent("Projects")
        let layout: [(String, String)] = [
            ("node-app", "package.json"), ("node-app", "node_modules/dep/index.js"), ("node-app", "bin/run.sh"), ("node-app", "dist/out.js"),
            ("dotnet-app", "App.csproj"), ("dotnet-app", "bin/App.dll"), ("dotnet-app", "obj/App.pdb"),
            ("go-app", "go.mod"), ("go-app", "bin/tool"),
            ("rust-app", "Cargo.toml"), ("rust-app", "target/debug/app"),
            ("py-app", "requirements.txt"), ("py-app", ".venv/lib/site.py"), ("py-app", "build/helper.py")
        ]
        for (project, file) in layout {
            try write(projects.appendingPathComponent(project).appendingPathComponent(file))
        }
        return (home, projects)
    }

    private func offered(_ service: ProjectPurgeService, in projects: URL) -> Set<String> {
        Set(service.scan(customSearchRoots: [projects.path], minAgeDays: 0).artifacts.map { "\($0.projectName)/\($0.artifactName)" })
    }

    @Test("PURGE-03: A folder is only offered when this kind of project rebuilds it; committed-looking names need git's word")
    func testArtifactsMustBelongToTheProjectType() throws {
        let (home, projects) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: home) }

        // git ignores nothing: only folders that cannot hold committed work are offered.
        let unambiguous = offered(ProjectPurgeService(homeDirectory: home.path, runner: gitRunner(ignoring: [])), in: projects)
        #expect(unambiguous == ["node-app/node_modules", "rust-app/target", "py-app/.venv"])

        // git ignores bin/obj/build/dist: they are offered, but only where the project type actually builds into them.
        let ignoring = offered(ProjectPurgeService(homeDirectory: home.path, runner: gitRunner(ignoring: ["bin", "obj", "build", "dist"])), in: projects)
        #expect(ignoring == unambiguous.union(["node-app/dist", "dotnet-app/bin", "dotnet-app/obj"]), "offered: \(ignoring.sorted())")
        #expect(!ignoring.contains("node-app/bin"))     // a Node project's bin/ holds scripts
        #expect(!ignoring.contains("go-app/bin"))       // go.mod is not a marker for bin
        #expect(!ignoring.contains("py-app/build"))     // requirements.txt alone is not a marker for build
    }

    @Test("PURGE-04: A symlinked artifact folder is not offered")
    func testSymlinkedArtifactIsSkipped() throws {
        let home = try makeTempDirectory("PurgeHome")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Projects/app")
        try write(app.appendingPathComponent("package.json"))
        try write(home.appendingPathComponent("Projects/shared-store/pkg/index.js"))
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("node_modules"),
            withDestinationURL: home.appendingPathComponent("Projects/shared-store")
        )

        let service = ProjectPurgeService(homeDirectory: home.path, runner: gitRunner(ignoring: []))
        #expect(offered(service, in: home.appendingPathComponent("Projects")).isEmpty)
    }

    @Test("PURGE-05: One folder that cannot be removed does not stop the rest, and is reported with what was freed")
    func testPurgeContinuesPastFailures() throws {
        let home = try makeTempDirectory("PurgeHome")
        let locked = home.appendingPathComponent("Projects/locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: home)
        }
        for name in ["locked", "open"] {
            try write(home.appendingPathComponent("Projects/\(name)/package.json"))
            try write(home.appendingPathComponent("Projects/\(name)/node_modules/dep/index.js"))
        }
        let service = ProjectPurgeService(homeDirectory: home.path, runner: gitRunner(ignoring: []))
        let artifacts = service.scan(customSearchRoots: [home.appendingPathComponent("Projects").path], minAgeDays: 0).artifacts
        #expect(artifacts.count == 2)

        // A read-only project folder cannot have entries removed from it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        do {
            _ = try service.purge(artifacts: artifacts, moveToTrash: false)
            Issue.record("purge should have reported the folder it could not remove")
        } catch let ProjectPurgeError.someItemsFailed(paths, freedBytes) {
            #expect(paths == [locked.appendingPathComponent("node_modules").path])
            #expect(freedBytes > 0)
        }
        #expect(!exists(home.appendingPathComponent("Projects/open/node_modules")))
        #expect(exists(locked.appendingPathComponent("node_modules")))
    }

    @Test("PURGE-06: A folder is checked again when it is about to go; a project that changed since the scan is left alone")
    func testPurgeRechecksTheProject() throws {
        let home = try makeTempDirectory("PurgeHome")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Projects/app")
        try write(app.appendingPathComponent("package.json"))
        try write(app.appendingPathComponent("node_modules/dep/index.js"))

        let service = ProjectPurgeService(homeDirectory: home.path, runner: gitRunner(ignoring: []))
        let artifacts = service.scan(customSearchRoots: [home.appendingPathComponent("Projects").path], minAgeDays: 0).artifacts
        #expect(artifacts.count == 1)

        try FileManager.default.removeItem(at: app.appendingPathComponent("package.json"))   // no longer a Node project
        #expect(try service.purge(artifacts: artifacts, moveToTrash: false) == 0)
        #expect(exists(app.appendingPathComponent("node_modules")))
    }

    @Test("PURGE-07: With real git, an ignored dist/ is offered and a committed one is not")
    func testRealGitIgnoreDecidesAmbiguousFolders() throws {
        let home = try makeTempDirectory("PurgeHome")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Projects/app")
        try write(app.appendingPathComponent("package.json"))
        try write(app.appendingPathComponent(".gitignore"), contents: Data("dist/\n".utf8))
        try write(app.appendingPathComponent("dist/bundle.js"))
        try write(app.appendingPathComponent("build/hand-written.js"))
        let gitInit = SystemCommand.processRunner("/usr/bin/git", ["-C", app.path, "init", "-q"])
        #expect(gitInit?.status == 0)

        let service = ProjectPurgeService(homeDirectory: home.path)
        #expect(offered(service, in: home.appendingPathComponent("Projects")) == ["app/dist"])
    }

    // MARK: - External drive sanitizer

    private func appleDouble() -> Data {
        var data = Data([0x00, 0x05, 0x16, 0x07])
        data.append(Data(repeating: 0, count: 252))
        return data
    }

    @Test("EXT-01: Only the root of a mounted external volume can be sanitized")
    func testRefusesAnythingButAVolume() async throws {
        let home = try makeTempDirectory("ExtHome")
        let volume = try makeTempDirectory("Volume")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: volume)
        }
        try write(home.appendingPathComponent("Documents/.DS_Store"))
        try write(volume.appendingPathComponent("Folder/.DS_Store"))

        let service = ExternalDriveSanitizerService(volumeProvider: { [volume] in [volume] })

        await #expect(throws: ExternalDriveError.self) { try await service.sanitize(volumeURL: home) }
        await #expect(throws: ExternalDriveError.self) { try await service.sanitize(volumeURL: volume.appendingPathComponent("Folder")) }
        #expect(exists(home.appendingPathComponent("Documents/.DS_Store")))
        #expect(exists(volume.appendingPathComponent("Folder/.DS_Store")))

        let result = try await service.sanitize(volumeURL: volume)
        #expect(result.removedCount == 1)
    }

    @Test("EXT-02: A ._ file is only removed if it really is AppleDouble metadata; Windows folder settings are kept")
    func testNameAloneDoesNotMakeAFilePhantom() async throws {
        let volume = try makeTempDirectory("Volume")
        defer { try? FileManager.default.removeItem(at: volume) }
        try write(volume.appendingPathComponent("Photos/._IMG_0001.jpg"), contents: appleDouble())       // junk
        try write(volume.appendingPathComponent("Photos/IMG_0001.jpg"))
        try write(volume.appendingPathComponent("Notes/._my-notes"), contents: Data("remember the milk".utf8))   // user's file
        try write(volume.appendingPathComponent("Shared/desktop.ini"), contents: Data("[.ShellClassInfo]".utf8))
        try write(volume.appendingPathComponent("Shared/Thumbs.db"))
        try write(volume.appendingPathComponent(".DS_Store"))

        let service = ExternalDriveSanitizerService(volumeProvider: { [volume] in [volume] })
        let result = try await service.sanitize(volumeURL: volume)

        #expect(result.removedCount == 3)       // ._IMG_0001.jpg, Thumbs.db, .DS_Store
        #expect(!exists(volume.appendingPathComponent("Photos/._IMG_0001.jpg")))
        #expect(!exists(volume.appendingPathComponent("Shared/Thumbs.db")))
        #expect(!exists(volume.appendingPathComponent(".DS_Store")))
        #expect(exists(volume.appendingPathComponent("Photos/IMG_0001.jpg")))
        #expect(exists(volume.appendingPathComponent("Notes/._my-notes")))
        #expect(exists(volume.appendingPathComponent("Shared/desktop.ini")))
    }

    @Test("EXT-03: macOS's volume-level folders are removed at the root only, and counted by their real size")
    func testVolumeRootFoldersOnlyAtTheRoot() async throws {
        let volume = try makeTempDirectory("Volume")
        defer { try? FileManager.default.removeItem(at: volume) }
        try write(volume.appendingPathComponent(".Spotlight-V100/Store-V2/index"), bytes: 20_000)
        try write(volume.appendingPathComponent("Backups/Old Mac/.fseventsd/000001"), bytes: 4_096)   // someone's copy of a disk

        let service = ExternalDriveSanitizerService(volumeProvider: { [volume] in [volume] })
        let scan = await service.scanVolume(url: volume)
        #expect(scan.fileCount == 1)
        #expect(scan.byteSize >= 20_000)

        let result = try await service.sanitize(volumeURL: volume)
        #expect(result.removedCount == 1)
        #expect(result.freedBytes >= 20_000)
        #expect(!exists(volume.appendingPathComponent(".Spotlight-V100")))
        #expect(exists(volume.appendingPathComponent("Backups/Old Mac/.fseventsd/000001")))
    }

    @Test("EXT-04: Only what was really removed is counted, and a link named like junk is never followed")
    func testFailuresAreNotCountedAndLinksAreSkipped() async throws {
        let volume = try makeTempDirectory("Volume")
        let outside = try makeTempDirectory("Outside")
        let readOnly = volume.appendingPathComponent("Locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: volume)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(readOnly.appendingPathComponent(".DS_Store"))
        try write(volume.appendingPathComponent("Open/.DS_Store"))
        try write(outside.appendingPathComponent("important.txt"))
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("Linked"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: volume.appendingPathComponent("Linked/.DS_Store"),
            withDestinationURL: outside.appendingPathComponent("important.txt")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)

        let service = ExternalDriveSanitizerService(volumeProvider: { [volume] in [volume] })
        let result = try await service.sanitize(volumeURL: volume)

        #expect(result.removedCount == 1)                                   // only Open/.DS_Store
        #expect(exists(readOnly.appendingPathComponent(".DS_Store")))
        #expect(exists(outside.appendingPathComponent("important.txt")))
    }
}
