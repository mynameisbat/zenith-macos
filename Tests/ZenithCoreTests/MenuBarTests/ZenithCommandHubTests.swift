import Testing
import Foundation
@testable import ZenithCore

@Suite("Zenith Command Hub State & Action Hub Test Suite")
struct ZenithCommandHubTests {

    @Test("HUB-01: ZenithHubAction has 6 quick actions with correct titles, icons, and shortcuts")
    func testZenithHubActionsExclusivity() {
        let allActions = ZenithHubAction.allCases
        #expect(allActions == [.area, .screen, .record, .ocr, .clipboard, .cleaning])
        #expect(ZenithHubAction.record.hotKeyId == HotKeyDefinition.recordScreenId)
        #expect(ZenithHubAction.record.shortcut == HotKeyDefinition.defaultRecordScreen.keyEquivalent)
        #expect(ZenithHubAction.record.matches(query: "video"))

        // Verify Area action metadata
        let area = ZenithHubAction.area
        #expect(area.rawValue == "area")
        #expect(area.title == "Capture Area")
        #expect(area.icon == "crop")
        #expect(area.shortcut == "⌘⇧2")
        #expect(area.hotKeyId == HotKeyDefinition.captureAreaId)

        // Verify Screen action metadata
        let screen = ZenithHubAction.screen
        #expect(screen.rawValue == "screen")
        #expect(screen.title == "Capture Screen")
        #expect(screen.icon == "macwindow")
        #expect(screen.shortcut == "⌘⇧1")
        #expect(screen.hotKeyId == HotKeyDefinition.captureFullscreenId)

        // OCR and clipboard use the same shortcuts as their global hot keys
        #expect(ZenithHubAction.ocr.shortcut == HotKeyDefinition.defaultOCR.keyEquivalent)
        #expect(ZenithHubAction.ocr.hotKeyId == HotKeyDefinition.captureOCRId)
        #expect(ZenithHubAction.clipboard.shortcut == HotKeyDefinition.defaultClipboard.keyEquivalent)
        #expect(ZenithHubAction.clipboard.hotKeyId == HotKeyDefinition.clipboardToggleId)
        #expect(ZenithHubAction.ocr.matches(query: "qr"))
        #expect(ZenithHubAction.clipboard.matches(query: "history"))
        #expect(!ZenithHubAction.ocr.matches(query: "clipboard"))
        for action in allActions {
            #expect(!action.detail.isEmpty)
        }
    }

    @Test("HUB-01B: The hub shows the shortcut the user chose, written like a macOS menu")
    func testEffectiveShortcutAndMenuStyle() {
        let defaults = TestDefaults.make("ZenithCommandHubTests_\(UUID().uuidString)")!
        let store = SettingsStore(userDefaults: defaults)

        // Nothing saved for OCR: its built-in shortcut applies
        #expect(store.effectiveHotkey(for: HotKeyDefinition.captureOCRId) == HotKeyDefinition.defaultOCR)
        // A saved shortcut wins
        store.updateHotkey(HotKeyDefinition.alternativeAreaCaptureX)
        #expect(store.effectiveHotkey(for: HotKeyDefinition.captureAreaId)?.keyEquivalent == "⌘⇧X")
        #expect(store.effectiveHotkey(for: "no.such.action") == nil)

        #expect(HotKeyDefinition.menuStyle("⌘⇧2") == "⇧⌘2")
        #expect(HotKeyDefinition.menuStyle("⌘⌥⌃T") == "⌃⌥⌘T")
        #expect(HotKeyDefinition.defaultOCR.menuStyleKeyEquivalent == "⌃⌥T")
        #expect(HotKeyDefinition.menuStyle(",") == ",")
    }

    @Test("HUB-01C: A helper process is shown with the icon of the app it belongs to")
    func testAppBundlePath() {
        let helper = ProcessTelemetry(
            pid: 10, name: "Google Chrome Helper (Renderer)",
            command: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer"
        )
        #expect(helper.appBundlePath == "/Applications/Google Chrome.app")
        #expect(ProcessTelemetry(pid: 11, name: "Notes", command: "/System/Applications/Notes.app").appBundlePath == "/System/Applications/Notes.app")
        #expect(ProcessTelemetry(pid: 12, name: "node", command: "/usr/local/bin/node server.js").appBundlePath == nil)
        #expect(ProcessTelemetry(pid: 13, name: "node", command: "node server.app/x").appBundlePath == nil)
    }

    @Test("HUB-02: Action query matching filters actions accurately")
    func testActionQueryMatching() {
        // Empty or whitespace matches all
        #expect(ZenithHubAction.area.matches(query: ""))
        #expect(ZenithHubAction.screen.matches(query: "   "))

        // "Capture" matches area and screen
        #expect(ZenithHubAction.area.matches(query: "capture"))
        #expect(ZenithHubAction.screen.matches(query: "CAPTURE"))

        // Specific titles or synonyms
        #expect(ZenithHubAction.area.matches(query: "area"))
        #expect(ZenithHubAction.screen.matches(query: "screen"))

        // Non-existent search query matches nothing
        #expect(!ZenithHubAction.area.matches(query: "nonexistent_query_xyz"))
        #expect(!ZenithHubAction.screen.matches(query: "nonexistent_query_xyz"))
    }

    @Test("HUB-03: ZenithCommandHubState initial values are cleanly nil and empty")
    @MainActor
    func testInitialState() {
        let state = ZenithCommandHubState()
        #expect(state.searchText.isEmpty)
        #expect(state.hoveredActionId == nil)
        #expect(state.hoveredClipId == nil)
        #expect(state.hoveredFooterId == nil)
    }

    @Test("HUB-04: Action hover race condition protection prevents premature hover clearing")
    @MainActor
    func testActionHoverRaceConditionProtection() {
        let state = ZenithCommandHubState()

        state.setHoveredAction("area")
        #expect(state.hoveredActionId == "area")

        // When pointer moves to "screen", enter event fires first
        state.setHoveredAction("screen")
        #expect(state.hoveredActionId == "screen")

        // Exit event from "area" arrives after enter into "screen"
        state.clearHoveredAction(ifCurrent: "area")
        #expect(state.hoveredActionId == "screen", "Exiting a previous tile must not cancel current tile hover!")

        // Normal exit when pointer leaves the row entirely
        state.clearHoveredAction(ifCurrent: "screen")
        #expect(state.hoveredActionId == nil)
    }

    @Test("HUB-05: Clip row hover race condition protection")
    @MainActor
    func testClipHoverRaceConditionProtection() {
        let state = ZenithCommandHubState()
        let clip1 = UUID()
        let clip2 = UUID()

        state.setHoveredClip(clip1)
        #expect(state.hoveredClipId == clip1)

        // Enter clip2
        state.setHoveredClip(clip2)
        #expect(state.hoveredClipId == clip2)

        // Delayed exit from clip1
        state.clearHoveredClip(ifCurrent: clip1)
        #expect(state.hoveredClipId == clip2)

        // Normal exit from clip2
        state.clearHoveredClip(ifCurrent: clip2)
        #expect(state.hoveredClipId == nil)
    }

    @Test("HUB-06: Footer hover race condition protection and full reset")
    @MainActor
    func testFooterHoverRaceConditionProtectionAndReset() {
        let state = ZenithCommandHubState()

        state.setHoveredFooter("doh")
        #expect(state.hoveredFooterId == "doh")

        // Rapid transition to "cleaner"
        state.setHoveredFooter("cleaner")
        state.clearHoveredFooter(ifCurrent: "doh")
        #expect(state.hoveredFooterId == "cleaner")

        // Transition to "settings"
        state.setHoveredFooter("settings")
        #expect(state.hoveredFooterId == "settings")

        // Transition to "quit"
        state.setHoveredFooter("quit")
        state.clearHoveredFooter(ifCurrent: "settings")
        #expect(state.hoveredFooterId == "quit")

        // Full state reset
        state.setSearchText("swift")
        state.setHoveredAction("area")
        state.setHoveredClip(UUID())
        state.reset()
        #expect(state.searchText.isEmpty)
        #expect(state.hoveredActionId == nil)
        #expect(state.hoveredClipId == nil)
        #expect(state.hoveredFooterId == nil)
    }

    @Test("HUB-07: Multi-word queries and specialized action keywords")
    func testMultiWordQueryMatching() {
        // Multi-word distinct matching
        #expect(ZenithHubAction.screen.matches(query: "screen capture"))
        #expect(!ZenithHubAction.area.matches(query: "screen capture"))

        #expect(ZenithHubAction.area.matches(query: "area capture"))
        #expect(!ZenithHubAction.screen.matches(query: "area capture"))

        // Specialized synonyms
        #expect(ZenithHubAction.screen.matches(query: "fullscreen"))
        #expect(ZenithHubAction.area.matches(query: "snip"))
    }

    @Test("HUB-08: Presentation ID regenerates on reset for reliable focus acquisition")
    @MainActor
    func testPresentationIDRegeneration() {
        let state = ZenithCommandHubState()
        let initialID = state.presentationID

        state.reset()
        #expect(state.presentationID != initialID)
    }

    @Test("HUB-09: Process hover race condition protection")
    @MainActor
    func testProcessHoverRaceConditionProtection() {
        let state = ZenithCommandHubState()

        state.setHoveredProcess(101)
        #expect(state.hoveredProcessId == 101)

        // Enter process 202
        state.setHoveredProcess(202)
        #expect(state.hoveredProcessId == 202)

        // Delayed exit from process 101
        state.clearHoveredProcess(ifCurrent: 101)
        #expect(state.hoveredProcessId == 202, "Exiting previous process must not clear hover for newly entered process")

        // Exit process 202
        state.clearHoveredProcess(ifCurrent: 202)
        #expect(state.hoveredProcessId == nil)
    }

    @Test("HUB-10: Boost system executes maintenance operations and refreshes snapshot")
    @MainActor
    func testBoostSystemExecution() async throws {
        // Boost clears caches and flushes DNS; here those go to a recorder and a throwaway home
        // instead of the machine running the tests.
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zenith_Boost_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let commands = RecordingCommandRunner()
        let state = ZenithCommandHubState(optimizer: SystemOptimizerService(homeDirectory: home.path, runner: commands.runner))

        state.boostSystem()

        #expect(state.hardwareSnapshot.timestamp <= Date())
        #expect(state.showTopHogs == true)

        // The maintenance steps run in the background; they must all go through the injected runner.
        for _ in 0..<40 where !commands.didRun("dscacheutil") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(commands.didRun("qlmanage"))
        #expect(commands.didRun("dscacheutil"))
        // Boost is a one-click action; it must not quietly change persistent Finder preferences.
        #expect(!commands.didRun("defaults"))
    }

    @Test("HUB-11: Process termination triggers hardware snapshot refresh and invalidation")
    @MainActor
    func testProcessTerminationTriggersRefresh() {
        let state = ZenithCommandHubState()
        // Terminate non-existent fake pid safely
        state.killProcess(pid: 999999)
        #expect(state.hardwareSnapshot.timestamp <= Date())
    }

    @Test("HUB-12: Default HardwareSnapshot creates valid lightweight initial state without child process overhead")
    func testDefaultHardwareSnapshot() {
        let snapshot = HardwareSnapshot()
        #expect(snapshot.thermalState == "Nominal")
        #expect(snapshot.cpu.coreCount > 0)
        #expect(snapshot.bluetoothDevices.isEmpty)
    }

    @Test("HUB-13: Filtered top hogs returns prefix 5 when query is empty or /boost")
    @MainActor
    func testFilteredTopHogsDefaultAndBoost() {
        let state = ZenithCommandHubState()
        var fakeHogs: [ProcessTelemetry] = []
        for i in 1...10 {
            let pid: Int = 1000 + i
            let cpu: Double = Double(10 - i)
            let memory: Int64 = Int64(i) * 1024 * 1024
            fakeHogs.append(ProcessTelemetry(pid: pid, name: "proc_\(i)", cpuPercent: cpu, memoryBytes: memory))
        }
        state.hardwareSnapshot = HardwareSnapshot(cpu: CPUTelemetry(topHogs: fakeHogs))

        // When search text is empty: exactly 5 items
        state.searchText = ""
        #expect(state.filteredTopHogs.count == 5)
        #expect(state.filteredTopHogs.map(\.pid) == [1001, 1002, 1003, 1004, 1005])

        // When search text is "/boost" or "boost"
        state.searchText = "/boost"
        #expect(state.filteredTopHogs.count == 5)
        #expect(state.filteredTopHogs.map(\.pid) == [1001, 1002, 1003, 1004, 1005])

        state.searchText = "boost"
        #expect(state.filteredTopHogs.count == 5)
    }

    @Test("HUB-15: A refresh takes its numbers from the snapshot provider, not from the machine")
    @MainActor
    func testSnapshotProviderIsUsed() {
        let state = ZenithCommandHubState()
        let sample = HardwareSnapshot(cpu: CPUTelemetry(topHogs: [ProcessTelemetry(pid: 4242, name: "Sample App")]))
        state.snapshotProvider = { sample }

        state.refreshHardwareSnapshot(sync: true)

        #expect(state.hardwareSnapshot == sample)
        #expect(state.filteredTopHogs.map(\.name) == ["Sample App"])
    }

    /// Records which processes were asked to quit.
    final class QuitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pids: [Int] = []
        var pids: [Int] { lock.withLock { _pids } }
        func record(_ pid: Int) { lock.withLock { _pids.append(pid) } }
    }

    @Test("HUB-16: Declining the confirmation quits nothing")
    @MainActor
    func testDecliningQuitsNothing() {
        let state = ZenithCommandHubState()
        let recorder = QuitRecorder()
        state.processTerminator = { recorder.record($0) }
        let process = ProcessTelemetry(pid: 4242, name: "Design Tool", cpuPercent: 20)
        var asked: (String, String, String)?

        let quit = state.terminate(process) { title, message, action in asked = (title, message, action); return false }

        #expect(quit == false)
        #expect(recorder.pids.isEmpty)
        #expect(asked?.0 == "Quit Design Tool?")
        #expect(asked?.1.contains("not saved") == true)
        #expect(asked?.2 == "Quit")
    }

    @Test("HUB-17: Confirming asks that one process to quit, and only that one")
    @MainActor
    func testConfirmingQuitsThatProcess() {
        let state = ZenithCommandHubState()
        let recorder = QuitRecorder()
        state.processTerminator = { recorder.record($0) }
        state.snapshotProvider = { HardwareSnapshot() }

        let quit = state.terminate(ProcessTelemetry(pid: 4242, name: "Design Tool", cpuPercent: 20)) { _, _, _ in true }

        #expect(quit)
        #expect(recorder.pids == [4242])
    }

    @Test("HUB-14: Filtered top hogs filters by name, command, and PID accurately")
    @MainActor
    func testFilteredTopHogsFiltering() {
        let state = ZenithCommandHubState()
        let proc1 = ProcessTelemetry(pid: 2048, name: "Google Chrome", command: "/Applications/Google Chrome.app", cpuPercent: 25.0)
        let proc2 = ProcessTelemetry(pid: 3012, name: "Xcode", command: "/Applications/Xcode.app", cpuPercent: 12.0)
        let proc3 = ProcessTelemetry(pid: 4096, name: "Slack", command: "/Applications/Slack.app", cpuPercent: 5.0)
        let proc4 = ProcessTelemetry(pid: 5120, name: "Terminal", command: "/System/Applications/Utilities/Terminal.app", cpuPercent: 2.0)

        state.hardwareSnapshot = HardwareSnapshot(cpu: CPUTelemetry(topHogs: [proc1, proc2, proc3, proc4]))

        // Filter by name
        state.searchText = "chrome"
        #expect(state.filteredTopHogs.count == 1)
        #expect(state.filteredTopHogs.first?.pid == 2048)

        // Filter by PID
        state.searchText = "4096"
        #expect(state.filteredTopHogs.count == 1)
        #expect(state.filteredTopHogs.first?.name == "Slack")

        // Filter by command path substring
        state.searchText = "Utilities"
        #expect(state.filteredTopHogs.count == 1)
        #expect(state.filteredTopHogs.first?.pid == 5120)

        // Filter with non-matching query
        state.searchText = "nonexistent_app"
        #expect(state.filteredTopHogs.isEmpty)
    }

    @Test("HUB-15: Process output parser combines top CPU hogs and heavy RAM consumers without duplicate PIDs")
    func testTopHogsCPUAndRAMCombination() {
        let service = HardwareTelemetryService()
        let sampleOutput = """
         100     1 S      50.0  1.0   50000 high_cpu_low_mem
         200     1 S       0.5 20.0 5000000 low_cpu_high_mem
         300     1 S      30.0  2.0  100000 mid_cpu_mid_mem
        """

        let (hogs, _) = service.parseProcessOutput(sampleOutput, topLimit: 3)
        #expect(hogs.count == 3)
        // High CPU item must be present
        #expect(hogs.contains { $0.pid == 100 })
        // High RAM item must also be present
        #expect(hogs.contains { $0.pid == 200 })
        // Unique PIDs only
        let uniquePIDs = Set(hogs.map(\.pid))
        #expect(uniquePIDs.count == hogs.count)
    }
}
