import Testing
import Foundation
@testable import ZenithCore

/// The relaunch helper with a fake `open`: it waits for the PID, then opens exactly the path it was given; it gives
/// up when the process never exits. Opens nothing real.
@Suite("Updater: relaunch helper")
struct RelaunchHelperTests {
    private func makeFakeOpen(in directory: URL) throws -> (tool: URL, marker: URL) {
        let marker = directory.appendingPathComponent("opened.txt")
        let tool = directory.appendingPathComponent("fake-open")
        // Writes its arguments, one per line, to the marker file.
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '\(marker.path)'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, marker)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenith-relaunch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sleeper(seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        return process
    }

    @Test("UPD-R01: Opens the app path (as one argument, never as script text) after the PID exits")
    func testOpensAfterExit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (tool, marker) = try makeFakeOpen(in: directory)
        let waitedOn = try sleeper(seconds: "1")
        // A path a naive script would break on or execute.
        let appPath = "/Applications/Ze nith \"$(touch \(directory.path)/pwned)\"; .app"

        let helper = try #require(RelaunchHelper.start(
            appPath: appPath, pid: waitedOn.processIdentifier, timeoutSeconds: 10, environment: ["OPEN": tool.path]
        ))
        // Not before the process is gone.
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        helper.waitUntilExit()
        waitedOn.waitUntilExit()

        #expect(helper.terminationStatus == 0)
        let opened = try String(contentsOf: marker, encoding: .utf8)
        #expect(opened == appPath + "\n")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    }

    @Test("UPD-R02: Gives up after the time limit if the process never exits, and opens nothing")
    func testTimeout() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (tool, marker) = try makeFakeOpen(in: directory)
        let stuck = try sleeper(seconds: "30")
        defer { stuck.terminate() }

        let started = Date()
        let helper = try #require(RelaunchHelper.start(
            appPath: "/Applications/Zenith.app", pid: stuck.processIdentifier, timeoutSeconds: 1, environment: ["OPEN": tool.path]
        ))
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 1)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(stuck.isRunning)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("UPD-R03: The PID and path are arguments; the script text is fixed")
    func testScriptIsFixed() {
        #expect(RelaunchHelper.script.contains("pid=\"$1\"; app=\"$2\"; limit=\"$3\""))
        #expect(RelaunchHelper.script.contains("exec \"$open_tool\" \"$app\""))
    }
}
