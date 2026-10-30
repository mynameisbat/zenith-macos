import Testing
import Foundation
@testable import ZenithCore

@Suite("System Optimizer Honest Reporting Suite")
struct SystemOptimizerHonestyTests {

    private let snapshotListing = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-24-123456.local\n"

    @Test("OPT-01: A task whose command fails reports the failure instead of success")
    func testFailedCommandsThrow() {
        let commands = RecordingCommandRunner()
        commands.failing = ["defaults"]
        let optimizer = SystemOptimizerService(runner: commands.runner)

        #expect(throws: OptimizerError.self) {
            try optimizer.execute(taskId: .preventNetworkDsStore)
        }

        commands.failing = ["lsregister"]
        #expect(throws: OptimizerError.self) {
            try optimizer.execute(taskId: .launchServicesRebuild)
        }
    }

    @Test("OPT-02: A DNS flush that cannot reach the system responder says it needs administrator rights")
    func testDnsFlushNeedsAdministrator() {
        let commands = RecordingCommandRunner()
        commands.failing = ["killall"]
        let optimizer = SystemOptimizerService(runner: commands.runner)

        #expect(throws: OptimizerError.self) {
            try optimizer.execute(taskId: .dnsCacheFlush)
        }
        #expect(commands.didRun("dscacheutil", containing: "-flushcache"))

        // With the rights to signal mDNSResponder, the task completes.
        let allowed = RecordingCommandRunner()
        #expect(throws: Never.self) {
            try SystemOptimizerService(runner: allowed.runner).execute(taskId: .dnsCacheFlush)
        }
    }

    @Test("OPT-03: Deleting snapshots without the needed rights is an error, and no space is claimed as freed")
    func testSnapshotDeletionWithoutRights() {
        let commands = RecordingCommandRunner()
        commands.outputs = ["tmutil": snapshotListing]
        commands.failing = []
        // Listing works, deleting does not: model that with a runner that fails only the delete subcommand.
        let runner: SystemCommandRunner = { executable, arguments in
            if arguments.first == "deletelocalsnapshots" {
                _ = commands.runner(executable, arguments)
                return SystemCommandResult(status: 1, output: "", errorOutput: "must be root")
            }
            return commands.runner(executable, arguments)
        }
        let optimizer = SystemOptimizerService(runner: runner)

        #expect(optimizer.listApfsLocalSnapshots() == ["2026-10-24-123456"])
        #expect(throws: OptimizerError.self) {
            try optimizer.execute(taskId: .apfsSnapshots)
        }
        #expect(commands.didRun("tmutil", containing: "deletelocalsnapshots"))
    }

    @Test("OPT-04: Only a zombie with a real parent is nudged to be reaped")
    func testRequestReapGuards() {
        let service = HardwareTelemetryService()
        func process(pid: Int, ppid: Int, zombie: Bool) -> ProcessTelemetry {
            ProcessTelemetry(pid: pid, ppid: ppid, name: "x", command: "x", cpuPercent: 0, memoryPercent: 0, memoryBytes: 0, state: zombie ? "Z" : "S", isZombie: zombie)
        }
        #expect(!service.requestReap(of: process(pid: 900_001, ppid: 900_002, zombie: false)))   // not a zombie
        #expect(!service.requestReap(of: process(pid: 900_001, ppid: 1, zombie: true)))          // launchd reaps its own
        #expect(!service.requestReap(of: process(pid: 900_001, ppid: 900_002, zombie: true)))    // parent does not exist
    }

    @Test("OPT-05: A kill request is refused for a process that is not safe to kill, even if the caller asked")
    func testKillIsRevalidated() {
        let service = HardwareTelemetryService()
        // PID 1 (launchd) is never killable; the live check refuses before any signal is sent.
        #expect(!service.terminateProcess(pid: 1))
        #expect(!service.forceKillProcess(pid: 1))
        // This test process is Zenith's own test runner; killing the app itself is also refused.
        #expect(!service.terminateProcess(pid: Int(ProcessInfo.processInfo.processIdentifier)))
    }
}
