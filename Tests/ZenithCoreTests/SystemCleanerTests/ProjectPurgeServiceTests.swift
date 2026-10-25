import Testing
import Foundation
@testable import ZenithCore

@Suite("Project Purge & Build Artifacts Scanner Suite")
struct ProjectPurgeServiceTests {

    @Test("PURGE-01: Discovers project artifact folders (node_modules, target, .build, .venv)")
    func testProjectArtifactsDiscovery() throws {
        let fm = FileManager.default
        let tempWorkspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Workspace_\(UUID().uuidString)")
        try fm.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempWorkspace) }

        // Setup 2 mock projects
        // Project 1: Node.js project with package.json and node_modules
        let nodeProj = tempWorkspace.appendingPathComponent("WebProject")
        try fm.createDirectory(at: nodeProj, withIntermediateDirectories: true)
        try "{}".write(to: nodeProj.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let nodeModulesDir = nodeProj.appendingPathComponent("node_modules/lodash")
        try fm.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
        try "module code".write(to: nodeModulesDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        // Project 2: Rust project with Cargo.toml and target
        let rustProj = tempWorkspace.appendingPathComponent("RustApp")
        try fm.createDirectory(at: rustProj, withIntermediateDirectories: true)
        try "[package]".write(to: rustProj.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        let targetDir = rustProj.appendingPathComponent("target/debug")
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try "binary".write(to: targetDir.appendingPathComponent("app"), atomically: true, encoding: .utf8)

        let service = ProjectPurgeService()
        let summary = service.scan(customSearchRoots: [tempWorkspace.path], minAgeDays: 0)

        #expect(summary.totalProjectsFound >= 2)
        #expect(summary.artifacts.count >= 2)
        #expect(summary.totalReclaimableBytes > 0)
        #expect(summary.artifacts.contains(where: { $0.projectName == "WebProject" && $0.artifactName == "node_modules" }))
        #expect(summary.artifacts.contains(where: { $0.projectName == "RustApp" && $0.artifactName == "target" }))
    }

    @Test("PURGE-02: Safety validator blocks deletion of user roots and non-artifact paths")
    func testPurgeSafetyValidation() {
        let service = ProjectPurgeService()
        let home = NSHomeDirectory()

        // Root directory protections
        #expect(service.isPathSafeForPurge(home) == false)
        #expect(service.isPathSafeForPurge("\(home)/Desktop") == false)
        #expect(service.isPathSafeForPurge("\(home)/Documents") == false)
        #expect(service.isPathSafeForPurge("\(home)/Library/Caches") == false)

        // Must match known artifact type
        #expect(service.isPathSafeForPurge("\(home)/Projects/MyApp/src") == false)
        #expect(service.isPathSafeForPurge("\(home)/Projects/MyApp/package.json") == false)

        // Valid artifact folders inside projects are allowed
        #expect(service.isPathSafeForPurge("\(home)/Projects/MyApp/node_modules") == true)
        #expect(service.isPathSafeForPurge("\(home)/dev/RustApp/target") == true)
        #expect(service.isPathSafeForPurge("\(home)/Code/PythonService/.venv") == true)
        #expect(service.isPathSafeForPurge("\(home)/RiderProjects/DotNetApp/bin") == true)
    }
}
