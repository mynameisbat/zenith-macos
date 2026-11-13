import Testing
import Foundation
import CryptoKit
@testable import ZenithCore

/// The installer on fake bundles in a temporary folder, with a fake downloader, a fake `hdiutil` and an injected
/// verifier. Nothing here touches a real app, a real disk image or the network.
@Suite("Updater: installer on fake bundles")
struct UpdateInstallerTests {
    // MARK: - Fixture

    /// A sandbox: `Applications/Zenith.app` (installed, "old"), `template/Zenith.app` (what the image holds, "new"),
    /// `tmp` (the installer's temporary root), `Downloads`, and `trash` (where the injected Trash moves things).
    final class Sandbox {
        let root: URL
        var applications: URL { root.appendingPathComponent("Applications") }
        var installed: URL { applications.appendingPathComponent("Zenith.app") }
        var template: URL { root.appendingPathComponent("template/Zenith.app") }
        var tmp: URL { root.appendingPathComponent("tmp") }
        var downloads: URL { root.appendingPathComponent("Downloads") }
        var trash: URL { root.appendingPathComponent("trash") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-updater-tests-\(UUID().uuidString)")
            for dir in [applications, tmp, downloads, trash, template.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Self.makeBundle(at: installed, version: "2.4.0", marker: "old")
            try Self.makeBundle(at: template, version: "2.5.0", marker: "new")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        static func makeBundle(at url: URL, version: String, identifier: String = "com.zenith.workspace", marker: String) throws {
            let macOS = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Zenith"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            try Data(marker.utf8).write(to: macOS.appendingPathComponent("Zenith"))
        }

        func marker(of app: URL) -> String? {
            (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Zenith"))).map { String(decoding: $0, as: UTF8.self) }
        }

        func contents(_ dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }

        /// The installed app is exactly the old one and nothing else was left behind anywhere.
        func expectUntouched(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(marker(of: installed) == "old", comment, sourceLocation: sourceLocation)
            #expect(contents(applications) == ["Zenith.app"], comment, sourceLocation: sourceLocation)
            #expect(contents(tmp).isEmpty, comment, sourceLocation: sourceLocation)
            #expect(contents(trash).isEmpty, comment, sourceLocation: sourceLocation)
        }
    }

    /// Writes `payload` where the download should go, or fails as told.
    final class FakeDownloader: UpdateDownloading, @unchecked Sendable {
        var payload = Data(repeating: 0x5A, count: 4_096)
        var failure: Error?
        var urls: [URL] = []
        func download(_ url: URL, to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Double?) -> Void) async throws {
            urls.append(url)
            if let failure { throw failure }
            progress(0.5)
            try payload.write(to: destination)
            progress(1)
        }
    }

    /// `hdiutil`: records every call; `attach` copies the template app to the mount point (as a mounted image would
    /// show it) unless told to fail or to present an image without the app.
    final class FakeHdiutil: @unchecked Sendable {
        let lock = NSLock()
        var commands: [[String]] = []
        var attachFails = false
        var imageHasApp = true
        var detachFails = false
        let template: URL
        init(template: URL) { self.template = template }

        var attaches: [[String]] { lock.withLock { commands.filter { $0.first == "attach" } } }
        var detaches: [[String]] { lock.withLock { commands.filter { $0.first == "detach" } } }

        var runner: SystemCommandRunner {
            { [self] executable, arguments in
                lock.withLock { commands.append(arguments) }
                #expect(executable == "/usr/bin/hdiutil")
                switch arguments.first {
                case "attach":
                    if attachFails { return SystemCommandResult(status: 1, output: "", errorOutput: "attach failed") }
                    if imageHasApp, let index = arguments.firstIndex(of: "-mountpoint") {
                        let mountPoint = URL(fileURLWithPath: arguments[index + 1])
                        try? FileManager.default.copyItem(at: template, to: mountPoint.appendingPathComponent("Zenith.app"))
                    }
                    return SystemCommandResult(status: 0, output: "")
                case "detach":
                    if let mountPoint = arguments.dropFirst().first {
                        // A real detach makes the volume's files disappear from the mount point.
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: mountPoint).appendingPathComponent("Zenith.app"))
                    }
                    return SystemCommandResult(status: detachFails ? 1 : 0, output: "")
                default:
                    return SystemCommandResult(status: 1, output: "")
                }
            }
        }
    }

    final class FakeVerifier: CodeSignatureVerifying, @unchecked Sendable {
        var signing: RunningAppSigning = .stable(requirement: "identifier \"com.zenith.workspace\" and certificate leaf = H\"00\"")
        var candidateResult: CandidateSignatureCheck = .satisfiesRunningRequirement
        var checked: [URL] = []
        var markersSeen: [String?] = []
        var onCheck: (() -> Void)?
        func runningAppSigning() -> RunningAppSigning { signing }
        func checkCandidate(at candidate: URL) -> CandidateSignatureCheck {
            onCheck?()
            checked.append(candidate)
            markersSeen.append((try? Data(contentsOf: candidate.appendingPathComponent("Contents/MacOS/Zenith"))).map { String(decoding: $0, as: UTF8.self) })
            return candidateResult
        }
    }

    struct Harness {
        let sandbox: Sandbox
        let downloader = FakeDownloader()
        let hdiutil: FakeHdiutil
        let verifier = FakeVerifier()
        var operations: UpdateFileOperations

        init() throws {
            sandbox = try Sandbox()
            hdiutil = FakeHdiutil(template: sandbox.template)
            let trash = sandbox.trash
            operations = UpdateFileOperations(
                copy: UpdateFileOperations.live.copy,
                replace: UpdateFileOperations.live.replace,
                trash: { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent)) }
            )
        }

        func installer() -> UpdateInstaller {
            UpdateInstaller(
                appURL: sandbox.installed, runningVersion: AppVersion("2.4.0")!, verifier: verifier, downloader: downloader,
                runner: hdiutil.runner, fileOperations: operations, temporaryRoot: sandbox.tmp, downloadsDirectory: sandbox.downloads
            )
        }

        func release(version: String = "2.5.0", sha256: String? = nil, size: Int64? = nil) -> UpdateRelease {
            UpdateRelease(
                version: AppVersion(version)!, tag: "v\(version)", assetName: "Zenith-\(version).dmg",
                downloadURL: URL(string: "https://github.com/mynameisbat/zenith-macos/releases/download/v\(version)/Zenith-\(version).dmg")!,
                assetSize: size ?? Int64(downloader.payload.count), sha256: sha256
            )
        }

        var payloadSHA256: String { SHA256.hash(data: downloader.payload).map { String(format: "%02x", $0) }.joined() }
    }

    private struct Injected: Error, LocalizedError {
        var errorDescription: String? { "injected failure" }
    }

    // MARK: - Happy path

    @Test("UPD-I01: Happy path: new bundle in place, old one in the Trash, staging and downloads gone")
    func testHappyPath() async throws {
        let h = try Harness()
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var items: [UpdateInstallProgress] = []
        }
        let log = Log()
        let installed = try await h.installer().install(h.release(sha256: h.payloadSHA256)) { p in log.lock.withLock { log.items.append(p) } }

        #expect(installed.standardizedFileURL == h.sandbox.installed.standardizedFileURL)
        #expect(h.sandbox.marker(of: h.sandbox.installed) == "new")
        #expect(h.sandbox.contents(h.sandbox.applications) == ["Zenith.app"])
        let trashed = h.sandbox.contents(h.sandbox.trash)
        #expect(trashed.count == 1)
        #expect(trashed.first?.hasPrefix("Zenith.app.zenith-previous-") == true)
        #expect(h.sandbox.marker(of: h.sandbox.trash.appendingPathComponent(trashed[0])) == "old")
        #expect(h.sandbox.contents(h.sandbox.tmp).isEmpty)
        #expect(log.lock.withLock { log.items.contains(.verifying) && log.items.contains(.installing) })
    }

    @Test("UPD-I02: The copy beside the app is what gets verified, after the image is detached")
    func testVerifiesTheCopy() async throws {
        let h = try Harness()
        var detachesWhenChecked = -1
        h.verifier.onCheck = { [hdiutil = h.hdiutil] in detachesWhenChecked = hdiutil.detaches.count }
        _ = try await h.installer().install(h.release()) { _ in }
        #expect(detachesWhenChecked == 1)
        let checked = try #require(h.verifier.checked.first)
        #expect(h.verifier.checked.count == 1)
        // Inside a hidden staging folder in the installed app's own folder (same volume: the swap is a rename).
        #expect(checked.lastPathComponent == "Zenith.app")
        #expect(checked.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == h.sandbox.applications.standardizedFileURL.path)
        #expect(checked.deletingLastPathComponent().lastPathComponent.hasPrefix(".zenith-update-"))
        #expect(!checked.path.contains("/mount/"))
        #expect(h.verifier.markersSeen == ["new"])
        // Detached before verification: the detach is the last hdiutil call and came before the check.
        #expect(h.hdiutil.detaches.count == 1)
    }

    @Test("UPD-I03: hdiutil gets exactly attach -nobrowse -readonly -noautoopen at a mount point in the temporary folder")
    func testHdiutilArguments() async throws {
        let h = try Harness()
        _ = try await h.installer().install(h.release()) { _ in }
        let attach = try #require(h.hdiutil.attaches.first)
        #expect(h.hdiutil.attaches.count == 1)
        #expect(attach.count == 7)
        #expect(attach[0] == "attach")
        let tmp = h.sandbox.tmp.standardizedFileURL.path + "/"
        #expect(attach[1].hasPrefix(tmp) && attach[1].hasSuffix("/Zenith-2.5.0.dmg"))
        #expect(Array(attach[2...5]) == ["-nobrowse", "-readonly", "-noautoopen", "-mountpoint"])
        #expect(attach[6].hasPrefix(tmp) && attach[6].hasSuffix("/mount"))
        #expect(h.hdiutil.detaches == [["detach", attach[6]]])
        #expect(h.downloader.urls == [h.release().downloadURL])
    }

    // MARK: - Refusals before anything happens

    @Test("UPD-I04: An ad-hoc running app is refused before any download")
    func testAdHocRefused() async throws {
        let h = try Harness()
        h.verifier.signing = .adHoc
        await #expect(throws: UpdateInstallError.refused(.notSignedWithStableIdentity)) {
            try await h.installer().install(h.release()) { _ in }
        }
        #expect(h.downloader.urls.isEmpty)
        #expect(h.hdiutil.commands.isEmpty)
        h.sandbox.expectUntouched()
    }

    @Test("UPD-I05: A release that is not newer, or whose URL or name was tampered with, is refused before any download")
    func testReleaseRecheck() async throws {
        let h = try Harness()
        await #expect(throws: UpdateInstallError.rejected(.notNewer(found: "2.4.0", running: "2.4.0"))) {
            try await h.installer().install(h.release(version: "2.4.0")) { _ in }
        }
        let good = h.release()
        let tampered = [
            UpdateRelease(version: good.version, tag: good.tag, assetName: good.assetName,
                          downloadURL: URL(string: "https://evil.example/Zenith-2.5.0.dmg")!, assetSize: good.assetSize, sha256: nil),
            UpdateRelease(version: good.version, tag: good.tag, assetName: "../../Zenith-2.5.0.dmg",
                          downloadURL: good.downloadURL, assetSize: good.assetSize, sha256: nil),
            UpdateRelease(version: good.version, tag: "v2.6.0", assetName: good.assetName,
                          downloadURL: good.downloadURL, assetSize: good.assetSize, sha256: nil),
            UpdateRelease(version: good.version, tag: good.tag, assetName: good.assetName,
                          downloadURL: good.downloadURL, assetSize: UpdateLimits.maximumDownloadBytes + 1, sha256: nil)
        ]
        for release in tampered {
            await #expect(throws: UpdateInstallError.untrustedRelease) { try await h.installer().install(release) { _ in } }
        }
        #expect(h.downloader.urls.isEmpty)
        h.sandbox.expectUntouched()
    }

    // MARK: - A failure at each step

    @Test("UPD-I06: Download fails, wrong size, or wrong checksum: nothing mounted, nothing changed")
    func testDownloadFailures() async throws {
        let h = try Harness()
        h.downloader.failure = URLError(.networkConnectionLost)
        await #expect(throws: UpdateInstallError.self) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched("download error")

        h.downloader.failure = nil
        await #expect(throws: UpdateInstallError.sizeMismatch(expected: 4_097, actual: 4_096)) {
            try await h.installer().install(h.release(size: 4_097)) { _ in }
        }
        h.sandbox.expectUntouched("size")

        await #expect(throws: UpdateInstallError.digestMismatch) {
            try await h.installer().install(h.release(sha256: String(repeating: "0", count: 64))) { _ in }
        }
        h.sandbox.expectUntouched("digest")

        h.downloader.failure = UpdateInstallError.tooLarge
        await #expect(throws: UpdateInstallError.tooLarge) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched("too large")
        #expect(h.hdiutil.commands.isEmpty)
    }

    @Test("UPD-I07: Mount fails, or the image has no Zenith.app: detach still runs, nothing changed")
    func testMountFailures() async throws {
        let h = try Harness()
        h.hdiutil.attachFails = true
        await #expect(throws: UpdateInstallError.mountFailed) { try await h.installer().install(h.release()) { _ in } }
        #expect(h.hdiutil.detaches.count >= 1)
        h.sandbox.expectUntouched("attach")

        h.hdiutil.attachFails = false
        h.hdiutil.imageHasApp = false
        let before = h.hdiutil.detaches.count
        await #expect(throws: UpdateInstallError.appMissingInImage) { try await h.installer().install(h.release()) { _ in } }
        #expect(h.hdiutil.detaches.count == before + 1)
        h.sandbox.expectUntouched("no app")
    }

    @Test("UPD-I08: A detach that fails is retried with -force")
    func testDetachForce() async throws {
        let h = try Harness()
        h.hdiutil.detachFails = true
        _ = try? await h.installer().install(h.release()) { _ in }
        let detaches = h.hdiutil.detaches
        #expect(detaches.count == 2)
        #expect(detaches.last?.last == "-force")
    }

    @Test("UPD-I09: The copy fails: detached, nothing changed")
    func testCopyFails() async throws {
        var h = try Harness()
        h.operations.copy = { _, _ in throw Injected() }
        await #expect(throws: UpdateInstallError.copyFailed("injected failure")) { try await h.installer().install(h.release()) { _ in } }
        #expect(h.hdiutil.detaches.count == 1)
        h.sandbox.expectUntouched()
    }

    @Test("UPD-I10: Wrong identifier, wrong version, or a bad signature on the copy: nothing changed")
    func testCandidateRejected() async throws {
        let h = try Harness()
        try FileManager.default.removeItem(at: h.sandbox.template)
        try Sandbox.makeBundle(at: h.sandbox.template, version: "2.5.0", identifier: "com.example.other", marker: "new")
        await #expect(throws: UpdateInstallError.rejected(.wrongIdentifier)) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched("identifier")

        try FileManager.default.removeItem(at: h.sandbox.template)
        try Sandbox.makeBundle(at: h.sandbox.template, version: "2.6.0", marker: "new")
        await #expect(throws: UpdateInstallError.rejected(.versionMismatch(claimed: "2.5.0", found: "2.6.0"))) {
            try await h.installer().install(h.release()) { _ in }
        }
        h.sandbox.expectUntouched("version")

        try FileManager.default.removeItem(at: h.sandbox.template)
        try Sandbox.makeBundle(at: h.sandbox.template, version: "2.5.0", marker: "new")
        h.verifier.candidateResult = .rejected("different certificate")
        await #expect(throws: UpdateInstallError.rejected(.signature("different certificate"))) {
            try await h.installer().install(h.release()) { _ in }
        }
        h.sandbox.expectUntouched("signature")
        #expect(h.hdiutil.detaches.count == 3)
    }

    @Test("UPD-I11: The swap fails before or halfway: the installed app is back in place")
    func testSwapFails() async throws {
        var h = try Harness()
        h.operations.replace = { _, _, _ in throw Injected() }
        await #expect(throws: UpdateInstallError.replaceFailed("injected failure")) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched("replace refused")

        // Halfway: the original was moved to its backup name and then the swap failed.
        h.operations.replace = { original, _, backupName in
            try FileManager.default.moveItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent(backupName))
            throw Injected()
        }
        await #expect(throws: UpdateInstallError.replaceFailed("injected failure")) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched("replace halfway")
    }

    @Test("UPD-I12: The Trash refuses the old app: the update stands and the old app is kept beside it, never deleted")
    func testTrashFails() async throws {
        var h = try Harness()
        h.operations.trash = { _ in throw Injected() }
        _ = try await h.installer().install(h.release()) { _ in }
        #expect(h.sandbox.marker(of: h.sandbox.installed) == "new")
        let names = h.sandbox.contents(h.sandbox.applications)
        #expect(names.count == 2)
        let backup = try #require(names.first { $0.hasPrefix("Zenith.app.zenith-previous-") })
        #expect(h.sandbox.marker(of: h.sandbox.applications.appendingPathComponent(backup)) == "old")
        #expect(h.sandbox.contents(h.sandbox.tmp).isEmpty)
    }

    @Test("UPD-I13: A symbolic link named Zenith.app in the image is not followed")
    func testSymlinkInImage() async throws {
        let h = try Harness()
        try FileManager.default.removeItem(at: h.sandbox.template)
        let elsewhere = h.sandbox.root.appendingPathComponent("elsewhere/Zenith.app")
        try Sandbox.makeBundle(at: elsewhere, version: "2.5.0", marker: "new")
        try FileManager.default.createSymbolicLink(at: h.sandbox.template, withDestinationURL: elsewhere)
        // copyItem of the template copies the link itself into the mount point.
        await #expect(throws: UpdateInstallError.appMissingInImage) { try await h.installer().install(h.release()) { _ in } }
        h.sandbox.expectUntouched()
    }

    // MARK: - Manual download

    @Test("UPD-I14: Manual download lands in Downloads, marked as downloaded, and installs nothing")
    func testManualDownload() async throws {
        let h = try Harness()
        h.verifier.signing = .adHoc
        let file = try await h.installer().downloadForManualInstall(h.release(sha256: h.payloadSHA256)) { _ in }
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == h.sandbox.downloads.standardizedFileURL.path)
        #expect(file.lastPathComponent == "Zenith-2.5.0.dmg")
        #expect(try Data(contentsOf: file) == h.downloader.payload)
        let quarantine = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine != nil)
        #expect(h.hdiutil.commands.isEmpty)
        #expect(h.sandbox.marker(of: h.sandbox.installed) == "old")
        #expect(h.sandbox.contents(h.sandbox.tmp).isEmpty)

        let second = try await h.installer().downloadForManualInstall(h.release()) { _ in }
        #expect(second.lastPathComponent == "Zenith-2.5.0 2.dmg")
    }
}
