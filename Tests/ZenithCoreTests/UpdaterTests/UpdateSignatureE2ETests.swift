import Testing
import Foundation
@testable import ZenithCore

/// The real Security-framework verifier on real signatures. Opt-in, because it creates a throwaway keychain with two
/// self-signed identities (`scripts/setup_signing.sh` with a test keychain) and signs tiny fake apps with
/// `scripts/sign_app.sh --keychain`:
///
///     ZENITH_E2E_SIGNING=1 swift test --filter UpdateSignatureE2ETests
///
/// The keychain is a file in a temporary folder, is never added to the search list, and is deleted at the end; the
/// test checks that `security list-keychains` is the same afterwards. No real app and no network are involved.
@Suite("Updater: signature verification end to end (opt-in)")
struct UpdateSignatureE2ETests {
    static let enabled = ProcessInfo.processInfo.environment["ZENITH_E2E_SIGNING"] == "1"

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func makeApp(at url: URL, version: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Zenith").path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.zenith.workspace", "CFBundleExecutable": "Zenith",
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    @Test(
        "UPD-E2E: Same certificate accepted; other certificate, ad hoc and tampered rejected; ad-hoc reference refuses",
        .enabled(if: UpdateSignatureE2ETests.enabled, "Creates a throwaway keychain and signs fake apps; set ZENITH_E2E_SIGNING=1")
    )
    func testRealSignatures() async throws {
        let (_, keychainsBefore) = try Self.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-signing-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let keychain = work.appendingPathComponent("e2e.keychain-db").path
        let password = UUID().uuidString
        defer {
            _ = try? Self.run("/usr/bin/security", ["delete-keychain", keychain])
            try? FileManager.default.removeItem(at: work)
        }

        #expect(try Self.run("/usr/bin/security", ["create-keychain", "-p", password, keychain]).0 == 0)
        let scripts = Self.repositoryRoot.appendingPathComponent("scripts")
        for name in ["Zenith E2E A", "Zenith E2E B"] {
            let (status, output) = try Self.run(scripts.appendingPathComponent("setup_signing.sh").path, [], environment: [
                "ZENITH_SIGN_IDENTITY": name, "ZENITH_SIGN_KEYCHAIN": keychain, "ZENITH_SIGN_KEYCHAIN_PASSWORD": password
            ])
            try #require(status == 0, "setup_signing.sh failed: \(output)")
        }

        func signedApp(_ name: String, version: String, identity: String) throws -> URL {
            let app = work.appendingPathComponent("\(name)/Zenith.app")
            try Self.makeApp(at: app, version: version)
            var environment = ["ZENITH_SIGN_IDENTITY": identity]
            if identity != "-" { environment["ZENITH_SIGN_KEYCHAIN"] = keychain }
            let (status, output) = try Self.run(scripts.appendingPathComponent("sign_app.sh").path, [app.path], environment: environment)
            try #require(status == 0, "sign_app.sh failed: \(output)")
            return app
        }

        let running = try signedApp("running", version: "1.0.0", identity: "Zenith E2E A")
        let sameSigner = try signedApp("same", version: "1.1.0", identity: "Zenith E2E A")
        let otherSigner = try signedApp("other", version: "1.1.0", identity: "Zenith E2E B")
        let adHoc = try signedApp("adhoc", version: "1.1.0", identity: "-")
        let tampered = try signedApp("tampered", version: "1.1.0", identity: "Zenith E2E A")
        try Data("tampered".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/Zenith"))

        let verifier = SecurityFrameworkSignatureVerifier(referencePath: running)
        guard case .stable(let requirement) = verifier.runningAppSigning() else {
            Issue.record("a certificate-signed reference must classify as stable"); return
        }
        #expect(requirement.contains("certificate leaf = H\""))
        #expect(requirement.contains("identifier \"com.zenith.workspace\""))

        #expect(verifier.checkCandidate(at: sameSigner) == .satisfiesRunningRequirement)
        #expect(verifier.checkCandidate(at: otherSigner) != .satisfiesRunningRequirement)
        #expect(verifier.checkCandidate(at: adHoc) != .satisfiesRunningRequirement)
        #expect(verifier.checkCandidate(at: tampered) != .satisfiesRunningRequirement)

        let adHocReference = SecurityFrameworkSignatureVerifier(referencePath: adHoc)
        #expect(adHocReference.runningAppSigning() == .adHoc)
        #expect(adHocReference.checkCandidate(at: sameSigner) != .satisfiesRunningRequirement)

        // The whole installer with the real verifier: the same-signer build goes in, the other signer's does not.
        for (candidate, shouldInstall) in [(otherSigner, false), (sameSigner, true)] {
            let sandbox = work.appendingPathComponent("install-\(UUID().uuidString)")
            let applications = sandbox.appendingPathComponent("Applications")
            let tmp = sandbox.appendingPathComponent("tmp")
            let trash = sandbox.appendingPathComponent("trash")
            for dir in [applications, tmp, trash] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let installed = applications.appendingPathComponent("Zenith.app")
            try FileManager.default.copyItem(at: running, to: installed)

            let payload = Data(repeating: 1, count: 100)
            let downloader = UpdateInstallerTests.FakeDownloader()
            downloader.payload = payload
            let hdiutil = UpdateInstallerTests.FakeHdiutil(template: candidate)
            let installer = UpdateInstaller(
                appURL: installed, runningVersion: AppVersion("1.0.0")!, verifier: verifier, downloader: downloader,
                runner: hdiutil.runner,
                fileOperations: UpdateFileOperations(
                    copy: UpdateFileOperations.live.copy, replace: UpdateFileOperations.live.replace,
                    trash: { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent)) }
                ),
                temporaryRoot: tmp, downloadsDirectory: nil
            )
            let release = UpdateRelease(
                version: AppVersion("1.1.0")!, tag: "v1.1.0", assetName: "Zenith-1.1.0.dmg",
                downloadURL: URL(string: "https://github.com/mynameisbat/zenith-macos/releases/download/v1.1.0/Zenith-1.1.0.dmg")!,
                assetSize: Int64(payload.count), sha256: nil
            )
            do {
                _ = try await installer.install(release) { _ in }
                #expect(shouldInstall, "the other signer's build must not be installed")
            } catch {
                #expect(!shouldInstall, "same signer refused: \(error)")
            }
            let version = UpdateInstaller.readInfo(of: installed)?["CFBundleShortVersionString"] as? String
            #expect(version == (shouldInstall ? "1.1.0" : "1.0.0"))
            // Either way what is installed still verifies as a whole.
            #expect(verifier.checkCandidate(at: installed) == .satisfiesRunningRequirement)
            #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path).count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
        }

        _ = try? Self.run("/usr/bin/security", ["delete-keychain", keychain])
        let (_, keychainsAfter) = try Self.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        #expect(keychainsAfter == keychainsBefore)
        print("UPD-E2E keychains before/after:\n\(keychainsBefore)\(keychainsAfter)")
    }
}
