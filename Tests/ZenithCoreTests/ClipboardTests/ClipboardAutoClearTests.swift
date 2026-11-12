import Testing
import Foundation
import AppKit
@testable import ZenithCore

@MainActor
@Suite("Clipboard auto-clear")
struct ClipboardAutoClearTests {

    private struct Fixture {
        let settings: ClipboardPrivacySettings
        let pasteboard: MockPasteboardService
        let scheduler: ManualClipboardScheduler
        let lock: MockSessionLockEventSource
        let controller: ClipboardAutoClearController
    }

    private func makeFixture(delay: ClipboardAutoClearDelay = .thirtySeconds, clearOnLock: Bool = false) -> Fixture {
        let settings = ClipboardPrivacySettings(userDefaults: TestDefaults.make("clipboard-autoclear-\(UUID().uuidString)")!, monitor: nil)
        settings.autoClearDelay = delay
        settings.clearOnLock = clearOnLock
        let pasteboard = MockPasteboardService()
        let scheduler = ManualClipboardScheduler()
        let lock = MockSessionLockEventSource()
        let controller = ClipboardAutoClearController(settings: settings, pasteboard: pasteboard, scheduler: scheduler, lockEvents: lock)
        controller.start()
        return Fixture(settings: settings, pasteboard: pasteboard, scheduler: scheduler, lock: lock, controller: controller)
    }

    /// An outside copy on the mock pasteboard, reported as the monitor would.
    private func copy(_ text: String, in fixture: Fixture) {
        fixture.pasteboard.simulateExternalCopy(.text(text))
        fixture.controller.noteChange(changeCount: fixture.pasteboard.changeCount)
    }

    @Test("Clears the clipboard once the delay has passed, not before")
    func testClearsAfterDelay() {
        let f = makeFixture(delay: .thirtySeconds)
        copy("token", in: f)
        f.scheduler.advance(by: 29)
        #expect(f.pasteboard.items.count == 1)
        f.scheduler.advance(by: 1)
        #expect(f.pasteboard.items.isEmpty)
        #expect(f.controller.lastClearedChangeCount == f.pasteboard.changeCount)
    }

    @Test("Never clears something copied later: a newer copy restarts the wait")
    func testNewerCopyRestartsWait() {
        let f = makeFixture(delay: .oneMinute)
        copy("first", in: f)
        f.scheduler.advance(by: 50)
        copy("second", in: f)
        f.scheduler.advance(by: 20) // 70 s after the first, 20 s after the second
        #expect(f.pasteboard.items.first?.plainTextContent == "second")
        #expect(f.scheduler.pendingCount == 1)
        f.scheduler.advance(by: 40)
        #expect(f.pasteboard.items.isEmpty)
    }

    @Test("A change the controller was not told about stops the clear (change counts differ)")
    func testChangedCountIsNotCleared() {
        let f = makeFixture(delay: .thirtySeconds)
        copy("first", in: f)
        // Something changed the clipboard without the monitor reporting it.
        f.pasteboard.simulateExternalCopy(.text("unseen"))
        f.scheduler.advance(by: 30)
        #expect(f.pasteboard.items.first?.plainTextContent == "unseen")
        #expect(f.controller.lastClearedChangeCount == nil)
    }

    @Test("Off: nothing is scheduled; turning it off meanwhile cancels the clear")
    func testOffAndTurnedOff() {
        let f = makeFixture(delay: .never)
        copy("kept", in: f)
        #expect(f.scheduler.pendingCount == 0)

        f.settings.autoClearDelay = .thirtySeconds
        copy("also kept", in: f)
        f.settings.autoClearDelay = .never
        f.scheduler.advance(by: 600)
        #expect(f.pasteboard.items.first?.plainTextContent == "also kept")
    }

    @Test("Clearing the system clipboard leaves the history alone")
    func testHistoryUntouched() {
        let f = makeFixture(delay: .thirtySeconds)
        let store = ClipboardStore(pasteboardService: f.pasteboard, initialItems: [], maxTotalBytes: ClipboardLimits.maxTotalBytes)
        store.startMonitoring()
        copy("in history", in: f)
        f.scheduler.advance(by: 30)
        #expect(f.pasteboard.items.isEmpty)
        #expect(store.items.map(\.plainTextContent) == ["in history"])
        store.stopMonitoring()
    }

    @Test("Lock or sleep clears the clipboard only when that setting is on")
    func testLockClears() {
        let off = makeFixture(delay: .never, clearOnLock: false)
        copy("stays", in: off)
        off.lock.trigger()
        #expect(off.pasteboard.items.count == 1)

        let on = makeFixture(delay: .tenMinutes, clearOnLock: true)
        #expect(on.lock.isStarted)
        copy("goes", in: on)
        on.lock.trigger()
        #expect(on.pasteboard.items.isEmpty)
        // The pending timed clear was called off, and a second lock does not clear an already empty clipboard again.
        #expect(on.scheduler.pendingCount == 0)
        let count = on.pasteboard.changeCount
        on.lock.trigger()
        #expect(on.pasteboard.changeCount == count)
    }

    @Test("Stop stops listening to lock events and cancels a pending clear")
    func testStop() {
        let f = makeFixture(delay: .thirtySeconds, clearOnLock: true)
        copy("x", in: f)
        f.controller.stop()
        #expect(!f.lock.isStarted)
        #expect(f.scheduler.pendingCount == 0)
        f.scheduler.advance(by: 60)
        #expect(f.pasteboard.items.count == 1)
    }

    @Test("Attached to a real monitor (private pasteboard): an outside copy is cleared after the delay")
    func testWithMonitor() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: board, pollingInterval: 3_600)
        let settings = ClipboardPrivacySettings(userDefaults: TestDefaults.make("clipboard-autoclear-\(UUID().uuidString)")!, monitor: monitor)
        settings.autoClearDelay = .thirtySeconds
        let scheduler = ManualClipboardScheduler()
        let controller = ClipboardAutoClearController(settings: settings, pasteboard: monitor, scheduler: scheduler, lockEvents: MockSessionLockEventSource())
        controller.start(observing: monitor)
        monitor.startMonitoring { _ in }
        defer { monitor.stopMonitoring(); controller.stop(observing: monitor) }

        board.clearContents()
        board.setString("one-time code 123456", forType: .string)
        monitor.checkForChanges()
        #expect(controller.pendingChangeCount == board.changeCount)
        scheduler.advance(by: 30)
        #expect(board.string(forType: .string) == nil)
        // Clearing is Zenith's own write: the monitor does not report it as a copy.
        monitor.checkForChanges()
        #expect(scheduler.pendingCount == 0)
    }
}
