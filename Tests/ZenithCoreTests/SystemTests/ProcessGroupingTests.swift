import Testing
import Foundation
@testable import ZenithCore

@Suite("Running Apps: helper processes are folded into their app")
struct ProcessGroupingTests {
    private let chrome = "/Applications/Google Chrome.app/Contents"

    private func process(_ pid: Int, _ command: String, cpu: Double = 0, memory: Int64 = 0) -> ProcessTelemetry {
        ProcessTelemetry(
            pid: pid, ppid: 1, name: (command as NSString).lastPathComponent, command: command,
            cpuPercent: cpu, memoryPercent: cpu / 10, memoryBytes: memory
        )
    }

    @Test("PG-01: An app and its helpers become one row with the app's name and the sums")
    func helpersJoinTheirApp() {
        let records = [
            process(300, "\(chrome)/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", cpu: 12, memory: 400),
            process(100, "\(chrome)/MacOS/Google Chrome", cpu: 3, memory: 900),
            process(301, "\(chrome)/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", cpu: 8, memory: 350),
            process(200, "/opt/homebrew/bin/node", cpu: 5, memory: 100)
        ]
        let grouped = ProcessGrouping.grouped(records)

        #expect(grouped.count == 2)
        let app = grouped[0]
        #expect(app.name == "Google Chrome")
        #expect(app.pid == 100)                       // the app's own process: the one to ask to quit
        #expect(app.cpuPercent == 23)
        #expect(app.memoryBytes == 1_650)
        #expect(app.processCount == 3)
        #expect(app.appBundlePath == "/Applications/Google Chrome.app")
        // A process outside any app is left as it was.
        #expect(grouped[1].name == "node")
        #expect(grouped[1].processCount == 1)
    }

    @Test("PG-02: Without the app's own process listed, the heaviest helper stands for it")
    func fallbackRepresentative() {
        let records = [
            process(7, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", memory: 10),
            process(8, "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", memory: 30)
        ]
        let grouped = ProcessGrouping.grouped(records)
        #expect(grouped.count == 1)
        #expect(grouped[0].name == "Claude")
        #expect(grouped[0].pid == 8)
    }

    @Test("PG-03: Apps stay apart and each keeps its place; a command-line tool is not an app")
    func separateAppsAndTools() {
        let records = [
            process(1, "/Applications/Notes.app/Contents/MacOS/Notes", cpu: 2),
            process(2, "/usr/local/bin/python3", cpu: 9),
            process(3, "/Applications/Slack.app/Contents/MacOS/Slack", cpu: 4),
            process(4, "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", cpu: 1),
            process(5, "python3", cpu: 1)
        ]
        let grouped = ProcessGrouping.grouped(records)
        #expect(grouped.map(\.name) == ["Notes", "python3", "Slack", "python3"])
        #expect(grouped[2].cpuPercent == 5)
        #expect(grouped[2].processCount == 2)
    }

    @Test("PG-04: ps output is grouped before the busiest are picked, so helpers add up")
    func parseGroupsBeforeRanking() {
        let output = """
          10     1 S   6.0  1.0  100 /Applications/Big.app/Contents/Frameworks/Big Helper.app/Contents/MacOS/Big Helper
          11     1 S   6.0  1.0  100 /Applications/Big.app/Contents/Frameworks/Big Helper.app/Contents/MacOS/Big Helper
          12     1 S   6.0  1.0  100 /Applications/Big.app/Contents/MacOS/Big
          20     1 S   9.0  1.0  100 /Applications/Solo.app/Contents/MacOS/Solo
        """
        let result = HardwareTelemetryService.shared.parseProcessOutput(output, topLimit: 5, ownPID: 99_999)
        #expect(result.topHogs.map(\.name) == ["Big", "Solo"])
        #expect(result.topHogs[0].cpuPercent == 18)
        #expect(result.topHogs[0].pid == 12)
    }
}
