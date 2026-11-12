import Testing
import CoreGraphics
@testable import ZenithCore

@Suite("Fullscreen Window Probe Suite")
struct FullscreenWindowProbeTests {
    /// The built-in display of a 14" MacBook Pro, top-left origin; the menu bar / notch strip is 33 pt tall.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// An external display to the right of it.
    private let external = CGRect(x: 1512, y: -100, width: 2560, height: 1440)
    private let game: pid_t = 501
    private let other: pid_t = 777
    private let zenith: pid_t = 42

    private func covers(_ windows: [FullscreenWindowProbe.Window], frontmost: pid_t? = 501,
                        display: CGRect? = nil) -> Bool {
        FullscreenWindowProbe.frontmostAppCoversDisplay(
            windows: windows, frontmostPID: frontmost, ownPID: zenith, displayBounds: display ?? builtIn)
    }

    @Test("FWP-01: A window of the frontmost app over the whole display, menu bar included, covers it")
    func testCoveringWindow() {
        #expect(covers([.init(pid: game, layer: 0, bounds: builtIn)]))
        // Games often use a raised level, and a frame a fraction of a point off still counts.
        #expect(covers([.init(pid: game, layer: 25, bounds: CGRect(x: -0.5, y: 0.5, width: 1512.5, height: 981.5))]))
        #expect(covers([.init(pid: game, layer: 0, bounds: builtIn.insetBy(dx: -10, dy: -10))]))
    }

    @Test("FWP-02: A zoomed window that starts below the menu bar does not count")
    func testZoomedWindow() {
        #expect(!covers([.init(pid: game, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949))]))
        #expect(!covers([.init(pid: game, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1500, height: 982))]))
    }

    @Test("FWP-03: A covering window of an app that is not in front does not count")
    func testNonFrontmostApp() {
        #expect(!covers([.init(pid: other, layer: 0, bounds: builtIn)]))
        #expect(!covers([.init(pid: game, layer: 0, bounds: builtIn)], frontmost: nil))
    }

    @Test("FWP-04: A transparent window, or one below the normal layer (Finder's desktop), does not count")
    func testTransparentAndDesktopWindows() {
        #expect(!covers([.init(pid: game, layer: 0, bounds: builtIn, alpha: 0)]))
        #expect(!covers([.init(pid: game, layer: -2147483603, bounds: builtIn, ownerName: "Finder")]))
    }

    @Test("FWP-05: A covering window on another display does not hide the island on this one")
    func testOtherDisplay() {
        let onExternal = FullscreenWindowProbe.Window(pid: game, layer: 0, bounds: external)
        #expect(!covers([onExternal]))
        #expect(covers([onExternal], display: external))
    }

    @Test("FWP-06: Zenith's own windows and the system's never count, even when they are in front")
    func testOwnAndSystemWindows() {
        #expect(!covers([.init(pid: zenith, layer: 0, bounds: builtIn)], frontmost: zenith))
        #expect(!covers([.init(pid: zenith, layer: 1000, bounds: builtIn)]))
        for owner in ["Dock", "Window Server", "WindowManager"] {
            #expect(!covers([.init(pid: game, layer: 20, bounds: builtIn, ownerName: owner)]), "\(owner)")
        }
    }

    @Test("FWP-07: Among many windows, one covering window of the frontmost app is enough")
    func testMixedList() {
        let windows: [FullscreenWindowProbe.Window] = [
            .init(pid: 1, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), ownerName: "Window Server"),
            .init(pid: game, layer: 0, bounds: CGRect(x: 100, y: 100, width: 400, height: 300)),
            .init(pid: other, layer: 0, bounds: builtIn),
            .init(pid: game, layer: 0, bounds: builtIn)
        ]
        #expect(covers(windows))
        #expect(!covers(Array(windows.dropLast())))
    }
}
