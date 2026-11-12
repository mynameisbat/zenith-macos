import Testing
import Foundation
@testable import ZenithCore

@Suite("Island Hover Suite")
struct IslandHoverTests {

    @MainActor
    private func makeState(delay: TimeInterval = 0.02, reducedMotion: Bool = false) -> ZenithIslandState {
        let state = ZenithIslandState()
        state.hoverOpenDelay = delay
        state.prefersReducedMotion = { reducedMotion }
        return state
    }

    @Test("IH-01: The pointer arriving swells the closed island at once and opens it only after the delay")
    @MainActor
    func testHoverOpensAfterDelay() async {
        let state = makeState()
        state.onMouseEnter()
        #expect(state.isHovered && state.isHoverEmphasized)
        #expect(!state.isExpanded)

        await state.waitForHoverOpening()
        #expect(state.isExpanded)
        #expect(!state.isHoverEmphasized)
    }

    @Test("IH-02: A pointer that only passes over never opens the island")
    @MainActor
    func testPassingPointerDoesNotOpen() async throws {
        let state = makeState(delay: 0.05)
        state.onMouseEnter()
        state.onMouseLeave()
        #expect(!state.isHovered && !state.isHoverEmphasized)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(!state.isExpanded)
    }

    @Test("IH-03: Repeated reports of the same pointer do not push the opening back")
    @MainActor
    func testRepeatedEnterKeepsTheFirstDeadline() async throws {
        let state = makeState(delay: 0.1)
        state.onMouseEnter()
        try await Task.sleep(nanoseconds: 60_000_000)
        state.onMouseEnter()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(state.isExpanded)       // 140 ms after the first report; a restarted wait would end at 160 ms
    }

    @Test("IH-04: A click, a dragged file and a zero delay open the island without waiting")
    @MainActor
    func testImmediateOpenings() {
        let clicked = makeState(delay: 5)
        clicked.onMouseEnter()
        clicked.open()
        #expect(clicked.isExpanded && !clicked.isHoverEmphasized)

        let dragged = makeState(delay: 5)
        dragged.isDropTargeted = true
        dragged.onMouseEnter()
        #expect(dragged.isExpanded)

        let instant = makeState(delay: 0)
        instant.onMouseEnter()
        #expect(instant.isExpanded && !instant.isHoverEmphasized)
    }

    @Test("IH-05: With Reduce Motion the island does not swell, and still opens after the delay")
    @MainActor
    func testReducedMotion() async {
        let state = makeState(reducedMotion: true)
        state.onMouseEnter()
        #expect(!state.isHoverEmphasized && !state.isExpanded)
        await state.waitForHoverOpening()
        #expect(state.isExpanded)
    }

    @Test("IH-06: Returning to an open island keeps it open and never swells it")
    @MainActor
    func testReenteringAnOpenIsland() async {
        let state = makeState()
        state.open()
        state.onMouseLeave()
        state.onMouseEnter()        // back within the 300 ms before it would close
        #expect(state.isExpanded && state.isHovered && !state.isHoverEmphasized)
    }

    @Test("IH-07: An island closed by hand under the pointer stays closed until the pointer has left and come back")
    @MainActor
    func testCloseSuppressesHover() async throws {
        let state = makeState(delay: 0.02)
        state.open()
        state.close()
        #expect(!state.isExpanded && state.isHoverSuppressed)

        state.onMouseEnter()                    // the pointer never left
        #expect(!state.isHoverEmphasized)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(!state.isExpanded)

        state.onMouseLeave()
        state.pointerLeft()
        state.onMouseEnter()
        await state.waitForHoverOpening()
        #expect(state.isExpanded)
    }

    @Test("IH-08: Closing by hand does nothing to an island holding a dragged file, and opening by hand always works")
    @MainActor
    func testCloseGuardsAndExplicitOpen() {
        let state = makeState()
        state.open()
        state.isDropTargeted = true
        state.close()
        #expect(state.isExpanded)

        state.isDropTargeted = false
        state.close()
        #expect(!state.isExpanded && state.isHoverSuppressed)
        state.open()                            // a swipe down while hover is still suppressed
        #expect(state.isExpanded && !state.isHoverSuppressed)
    }

    @Test("IH-09: A click on the closed island while it waits to open opens it at once and is kept")
    @MainActor
    func testClickOpensEmphasizedIsland() {
        let state = makeState(delay: 5)
        state.onMouseEnter()
        #expect(state.isHoverEmphasized && !state.isExpanded)

        #expect(state.handleClick(pointerOnIsland: true))
        #expect(state.isExpanded && !state.isHoverEmphasized)
        #expect(!state.handleClick(pointerOnIsland: true))      // already open: the click belongs to the open island
    }

    @Test("IH-10: A click off the island, or on an island that is hidden, showing a notice or not under the pointer, is let through")
    @MainActor
    func testClickPassesThroughOtherwise() {
        let off = makeState(delay: 5)
        off.onMouseEnter()
        #expect(!off.handleClick(pointerOnIsland: false))       // the pointer is beside the drawn island
        #expect(!off.isExpanded)

        let notHovered = makeState(delay: 5)
        #expect(!notHovered.handleClick(pointerOnIsland: true))
        #expect(!notHovered.isExpanded)

        let hidden = makeState(delay: 5)
        hidden.onMouseEnter()
        hidden.setHiddenForFullscreen(true)
        #expect(!hidden.handleClick(pointerOnIsland: true))
        #expect(!hidden.isExpanded)

        let alert = makeState(delay: 5)
        alert.onMouseEnter()
        alert.activeAlert = IslandAlert(icon: "bolt.fill", title: "Charging")
        #expect(!alert.handleClick(pointerOnIsland: true))
        #expect(!alert.isExpanded)

        let disabled = makeState(delay: 5)
        disabled.onMouseEnter()
        disabled.isEnabled = false
        #expect(!disabled.opensOnClick(pointerOnIsland: true))
    }

    @Test("IH-11: A click opens an island that was closed by hand under the pointer, though hover would not")
    @MainActor
    func testClickOverridesHoverSuppression() {
        let state = makeState(delay: 5)
        state.open()
        state.close()
        state.onMouseEnter()                    // the pointer never left: hover stays quiet
        #expect(!state.isExpanded && state.isHoverSuppressed)
        #expect(state.handleClick(pointerOnIsland: true))
        #expect(state.isExpanded)
    }
}
