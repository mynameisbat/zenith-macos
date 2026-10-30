import Testing
import Foundation
@testable import ZenithCore

/// Stands in for `lipo` and `codesign` so slimming can be exercised on a throwaway app bundle.
final class FakeSlimToolchain: @unchecked Sendable {
    static let thinContent = Data("ARM64-ONLY".utf8)

    private let lock = NSLock()
    private var _commands: [[String]] = []

    var lipoFails = false
    var thinnedArchs = "arm64"
    var entitlementsXML = "<plist><dict></dict></plist>"
    var signFails = false
    var verifyFails = false

    var commands: [[String]] { lock.withLock { _commands } }
    var didThin: Bool { commands.contains { $0.contains("-thin") } }

    var runner: SystemCommandRunner {
        { [self] executable, arguments in
            lock.withLock { _commands.append([URL(fileURLWithPath: executable).lastPathComponent] + arguments) }
            switch (URL(fileURLWithPath: executable).lastPathComponent, arguments.first) {
            case ("lipo", "-thin"):
                if lipoFails { return SystemCommandResult(status: 1, output: "", errorOutput: "lipo failed") }
                try? Self.thinContent.write(to: URL(fileURLWithPath: arguments[4]))
                return SystemCommandResult(status: 0, output: "")
            case ("lipo", "-archs"):
                return SystemCommandResult(status: 0, output: thinnedArchs + "\n")
            case ("codesign", "-d"):
                return SystemCommandResult(status: 0, output: entitlementsXML)
            case ("codesign", "--force"):
                return SystemCommandResult(status: signFails ? 1 : 0, output: "", errorOutput: signFails ? "sign failed" : "")
            case ("codesign", "--verify"):
                return SystemCommandResult(status: verifyFails ? 1 : 0, output: "", errorOutput: verifyFails ? "invalid signature" : "")
            default:
                return nil
            }
        }
    }
}

@Suite("Binary Slimmer Safety Suite")
struct BinarySlimmerSafetyTests {

    private let intelSize: UInt32 = 4000

    /// A minimal two-slice (x86_64 + arm64) fat Mach-O header followed by padding.
    private func fatBinary() -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        var bytes: [UInt8] = []
        bytes += bigEndian(0xCAFEBABE)
        bytes += bigEndian(2)
        bytes += bigEndian(0x01000007) + bigEndian(3) + bigEndian(0x1000) + bigEndian(intelSize) + bigEndian(12)
        bytes += bigEndian(0x0100000C) + bigEndian(0) + bigEndian(0x2000) + bigEndian(4000) + bigEndian(12)
        bytes += [UInt8](repeating: 0xAB, count: 8192 - bytes.count)
        return Data(bytes)
    }

    private struct Fixture {
        let root: URL
        let appURL: URL
        let binaryURL: URL
        let original: Data
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ZenithSlimTest-\(UUID().uuidString)")
        let appURL = root.appendingPathComponent("Fake.app")
        let macOS = appURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binaryURL = macOS.appendingPathComponent("Fake")
        let original = fatBinary()
        try original.write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return Fixture(root: root, appURL: appURL, binaryURL: binaryURL, original: original)
    }

    private func makeService(
        _ toolchain: FakeSlimToolchain,
        running: Bool = false,
        disposed: DisposedBackups = DisposedBackups()
    ) -> BinarySlimmerService {
        BinarySlimmerService(
            runner: toolchain.runner,
            isApplicationRunning: { _ in running },
            disposeBackup: { disposed.record($0) },
            historyTracker: SystemCleaningHistoryTracker(defaults: UserDefaults(suiteName: "zenith.tests.slim.\(UUID().uuidString)")!)
        )
    }

    final class DisposedBackups: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func record(_ url: URL) { lock.withLock { _urls.append(url) } }
    }

    private func directoryEntries(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - Success

    @Test("SLIM-03: A slimmed app is swapped in whole and the original is kept for recovery")
    func testSuccessfulSlimKeepsOriginalRecoverable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let toolchain = FakeSlimToolchain()
        let disposed = DisposedBackups()
        let service = makeService(toolchain, disposed: disposed)

        let plan = try #require(service.scanApp(atPath: fixture.appURL.path))
        #expect(plan.binaries.count == 1)

        let saved = try service.slimApp(plan: plan)
        #expect(saved == Int64(intelSize))

        // The installed binary is now the verified arm64-only one, with its permissions intact.
        #expect(try Data(contentsOf: fixture.binaryURL) == FakeSlimToolchain.thinContent)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.binaryURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
        #expect(!FileManager.default.fileExists(atPath: fixture.binaryURL.path + ".arm64_thin"))

        // The original bundle was handed over for disposal (the Trash), not deleted, and is still intact.
        let backup = try #require(disposed.urls.first)
        #expect(disposed.urls.count == 1)
        #expect(backup.lastPathComponent.hasPrefix("Fake.app.zenith-backup-"))
        #expect(try Data(contentsOf: backup.appendingPathComponent("Contents/MacOS/Fake")) == fixture.original)

        // The signature was checked before the swap.
        let names = toolchain.commands.map { $0.prefix(2).joined(separator: " ") }
        let signIndex = try #require(names.firstIndex(of: "codesign --force"))
        let verifyIndex = try #require(names.firstIndex(of: "codesign --verify"))
        #expect(signIndex < verifyIndex)
        #expect(toolchain.commands[signIndex].contains("--preserve-metadata=identifier,entitlements,flags,runtime"))
    }

    // MARK: - Failures leave the installed app untouched

    private func expectUntouched(_ fixture: Fixture, disposed: DisposedBackups) throws {
        #expect(try Data(contentsOf: fixture.binaryURL) == fixture.original)
        #expect(disposed.urls.isEmpty)
        // Nothing was left beside the app: no backups, no half-written files.
        #expect(directoryEntries(fixture.root) == ["Fake.app"])
        #expect(directoryEntries(fixture.binaryURL.deletingLastPathComponent()) == ["Fake"])
    }

    @Test("SLIM-04: If lipo fails, the app is not changed")
    func testLipoFailureLeavesAppUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let toolchain = FakeSlimToolchain()
        toolchain.lipoFails = true
        let disposed = DisposedBackups()
        let service = makeService(toolchain, disposed: disposed)
        let plan = try #require(service.scanApp(atPath: fixture.appURL.path))

        #expect(throws: SlimmerError.binaryExtractionFailed(fixture.binaryURL.path)) {
            try service.slimApp(plan: plan)
        }
        try expectUntouched(fixture, disposed: disposed)
    }

    @Test("SLIM-05: A slice that is not arm64-only is rejected")
    func testNonArm64OutputIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let toolchain = FakeSlimToolchain()
        toolchain.thinnedArchs = "arm64 x86_64"
        let disposed = DisposedBackups()
        let service = makeService(toolchain, disposed: disposed)
        let plan = try #require(service.scanApp(atPath: fixture.appURL.path))

        #expect(throws: SlimmerError.binaryExtractionFailed(fixture.binaryURL.path)) {
            try service.slimApp(plan: plan)
        }
        try expectUntouched(fixture, disposed: disposed)
    }

    @Test("SLIM-06: If re-signing or verification fails, the app is not changed")
    func testSigningFailuresLeaveAppUntouched() throws {
        for failure in ["sign", "verify"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let toolchain = FakeSlimToolchain()
            toolchain.signFails = failure == "sign"
            toolchain.verifyFails = failure == "verify"
            let disposed = DisposedBackups()
            let service = makeService(toolchain, disposed: disposed)
            let plan = try #require(service.scanApp(atPath: fixture.appURL.path))

            #expect(throws: SlimmerError.self) {
                try service.slimApp(plan: plan)
            }
            try expectUntouched(fixture, disposed: disposed)
        }
    }

    // MARK: - Apps that must not be modified

    @Test("SLIM-07: Running, App Store and team-entitled apps are refused before anything is touched")
    func testUnsafeAppsAreRefused() throws {
        // Running app
        do {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let toolchain = FakeSlimToolchain()
            let disposed = DisposedBackups()
            let service = makeService(toolchain, running: true, disposed: disposed)
            let plan = try #require(service.scanApp(atPath: fixture.appURL.path))
            #expect(throws: SlimmerError.applicationIsRunning) { try service.slimApp(plan: plan) }
            #expect(!toolchain.didThin)
            try expectUntouched(fixture, disposed: disposed)
        }

        // Mac App Store receipt
        do {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.createDirectory(at: fixture.appURL.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
            let toolchain = FakeSlimToolchain()
            let service = makeService(toolchain)
            let plan = try #require(service.scanApp(atPath: fixture.appURL.path))
            #expect(throws: SlimmerError.self) { try service.slimApp(plan: plan) }
            #expect(!toolchain.didThin)
            #expect(try Data(contentsOf: fixture.binaryURL) == fixture.original)
        }

        // Entitlements that only work with the developer's own signature
        for entitlement in ["com.apple.developer.icloud-services", "keychain-access-groups", "com.apple.security.application-groups"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let toolchain = FakeSlimToolchain()
            toolchain.entitlementsXML = "<plist><dict><key>\(entitlement)</key><array/></dict></plist>"
            let service = makeService(toolchain)
            let plan = try #require(service.scanApp(atPath: fixture.appURL.path))
            #expect(throws: SlimmerError.self) { try service.slimApp(plan: plan) }
            #expect(!toolchain.didThin)
            #expect(try Data(contentsOf: fixture.binaryURL) == fixture.original)
        }
    }

    @Test("SLIM-08: Error messages tell the user the app was left unchanged")
    func testErrorMessages() {
        #expect(SlimmerError.binaryExtractionFailed("/x").errorDescription?.contains("not changed") == true)
        #expect(SlimmerError.signingFailed("bad").errorDescription?.contains("not changed") == true)
        #expect(SlimmerError.applicationIsRunning.errorDescription?.contains("Quit") == true)
        #expect(SlimmerError.unsupportedApplication("reason").errorDescription?.contains("reason") == true)
    }
}
