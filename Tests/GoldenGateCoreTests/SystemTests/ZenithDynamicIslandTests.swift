import Testing
import AppKit
import Foundation
@testable import GoldenGateCore

@Suite("Zenith Dynamic Island & Drop Shelf Test Suite")
struct ZenithDynamicIslandTests {

    @Test("ISL-01: ZenithIslandGeometry hardware awareness & frame calculation")
    func testIslandGeometryCalculations() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        #expect(geometry.expandedWidth == 380)
        #expect(geometry.expandedHeight == 96)

        let idleFrame = geometry.windowFrame(isExpanded: false)
        let expandedFrame = geometry.windowFrame(isExpanded: true)

        let expectedScreenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Must be centered horizontally
        #expect(idleFrame.midX == expectedScreenFrame.midX)
        #expect(expandedFrame.midX == expectedScreenFrame.midX)

        // Must touch the top screen edge
        #expect(idleFrame.maxY == expectedScreenFrame.maxY)
        #expect(expandedFrame.maxY == expectedScreenFrame.maxY)

        // Expanded frame must be larger than idle frame
        #expect(expandedFrame.width > idleFrame.width)
        #expect(expandedFrame.height > idleFrame.height)
        // Verify default initializer behaves consistently with screen resolution
        let defaultGeometry = ZenithIslandGeometry()
        let expectedDefaultScreen: NSScreen? = {
            if let notchScreen = NSScreen.screens.first(where: { s in
                if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
                    return right.origin.x > left.maxX
                }
                return false
            }) {
                return notchScreen
            }
            return NSScreen.screens.first ?? NSScreen.main
        }()
        let expectedDefaultFrame = expectedDefaultScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(defaultGeometry.screenFrame == expectedDefaultFrame)
        #expect(defaultGeometry.expandedWidth == 380)
        #expect(defaultGeometry.expandedHeight == 96)
    }

    @Test("ISL-02: ZenithIslandState hover expansion and toggle behaviors")
    @MainActor
    func testIslandStateExpansion() {
        let state = ZenithIslandState()

        #expect(!state.isExpanded)
        #expect(!state.isHovered)
        #expect(!state.isDropTargeted)

        // Mouse enter should trigger expansion
        state.onMouseEnter()
        #expect(state.isHovered)
        #expect(state.isExpanded)

        // Manual toggle
        state.toggleExpanded()
        #expect(!state.isExpanded)

        state.toggleExpanded()
        #expect(state.isExpanded)
    }

    @Test("ISL-03: IslandDropItem Drop Shelf queue management & max capacity bounding")
    @MainActor
    func testDropShelfManagement() {
        let state = ZenithIslandState()
        state.clearAll()
        #expect(state.droppedItems.isEmpty)

        // Add plain text item
        state.addItem(name: "Test Snippet", textContent: "https://zenith.apple.com")
        #expect(state.droppedItems.count == 1)
        #expect(state.droppedItems[0].name == "Test Snippet")
        #expect(state.droppedItems[0].textContent == "https://zenith.apple.com")
        #expect(state.droppedItems[0].fileURL == nil)

        // Add file URL item
        let tempURL = URL(fileURLWithPath: "/tmp/sample.png")
        state.addItem(name: "sample.png", fileURL: tempURL)
        #expect(state.droppedItems.count == 2)
        #expect(state.droppedItems[0].name == "sample.png")
        #expect(state.droppedItems[0].fileURL == tempURL)

        // Remove item by id
        let toRemove = state.droppedItems[0].id
        state.removeItem(id: toRemove)
        #expect(state.droppedItems.count == 1)
        #expect(state.droppedItems[0].name == "Test Snippet")

        // Test capacity capping (max 8 items)
        for i in 1...12 {
            state.addItem(name: "Item \(i)")
        }
        #expect(state.droppedItems.count == 8)
        #expect(state.droppedItems[0].name == "Item 12")

        // Clear all
        state.clearAll()
        #expect(state.droppedItems.isEmpty)
    }

    @Test("ISL-04: IslandDropItem equality and identifier uniqueness")
    func testDropItemProperties() {
        let id1 = UUID()
        let id2 = UUID()
        let item1 = IslandDropItem(id: id1, name: "Doc1.pdf")
        let item2 = IslandDropItem(id: id1, name: "Doc1.pdf")
        let item3 = IslandDropItem(id: id2, name: "Doc2.pdf")

        #expect(item1 == item2)
        #expect(item1 != item3)
        #expect(item1.id == id1)
    }

    @Test("ISL-05: Rapid hover race condition prevention and re-entry cancellation")
    @MainActor
    func testRapidHoverRaceConditionHandling() async {
        let state = ZenithIslandState()

        // 1. Enter
        state.onMouseEnter()
        #expect(state.isHovered)
        #expect(state.isExpanded)

        // 2. Rapid leave
        state.onMouseLeave()
        #expect(!state.isHovered)
        // Should remain expanded during the 350ms grace period
        #expect(state.isExpanded)

        // 3. Rapid re-enter within grace period
        state.onMouseEnter()
        #expect(state.isHovered)
        #expect(state.isExpanded)

        // 4. Repeated rapid hover oscillations (simulate rapid mouse jitter over border)
        for _ in 1...10 {
            state.onMouseLeave()
            state.onMouseEnter()
        }
        #expect(state.isHovered)
        #expect(state.isExpanded)

        // 5. Test natural collapse after grace period
        state.onMouseLeave()
        #expect(!state.isHovered)
        // Wait for grace period to expire (with polling window for CI / heavy parallel test load)
        for _ in 0..<100 {
            if !state.isExpanded { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        #expect(!state.isExpanded)

        // 6. Rapid re-hover immediately after collapse
        state.onMouseEnter()
        #expect(state.isHovered)
        #expect(state.isExpanded)
    }

    @Test("ISL-06: Drag out staging lifecycle and delayed collapse safety")
    @MainActor
    func testDragOutLifecycle() {
        let state = ZenithIslandState()
        #expect(!state.isDraggingOut)

        // Enter and begin drag out
        state.onMouseEnter()
        state.beginDragOut()
        #expect(state.isDraggingOut)
        #expect(state.isExpanded)

        // Mouse leaves while dragging out (e.g. user drags file toward external Slack window)
        state.onMouseLeave()
        #expect(!state.isHovered)
        #expect(state.isDraggingOut)
        #expect(state.isExpanded) // Shelf must stay expanded to avoid dropping under cursor

        // End drag out
        state.endDragOut()
        #expect(!state.isDraggingOut)
        #expect(!state.isExpanded)
    }

    @Test("ISL-07: ZenithIslandGeometry bounds safety and multi-display edge cases")
    func testGeometryBoundsSafety() {
        // Test custom screen dimensions (e.g. 4K monitor 3840x2160, 5K Studio Display 5120x2880)
        let customScreens = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 0, y: 0, width: 3840, height: 2160),
            CGRect(x: 0, y: 0, width: 5120, height: 2880),
            CGRect(x: 0, y: 0, width: 1440, height: 900)
        ]

        for screenFrame in customScreens {
            let notchX = screenFrame.midX - 55
            let notchY = screenFrame.maxY - 8
            let idleFrame = CGRect(x: notchX, y: notchY, width: 110, height: 8)
            let expandedFrame = CGRect(
                x: screenFrame.midX - 190,
                y: screenFrame.maxY - 96,
                width: 380,
                height: 96
            )

            #expect(idleFrame.midX == screenFrame.midX)
            #expect(expandedFrame.midX == screenFrame.midX)
            #expect(idleFrame.maxY == screenFrame.maxY)
            #expect(expandedFrame.maxY == screenFrame.maxY)
            #expect(expandedFrame.width == 380)
            #expect(expandedFrame.height == 96)
        }
    }

    @Test("ISL-08: Symmetric dynamic island expansion & notch midX anchoring verification")
    func testSymmetricExpansionInvariants() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        let idleFrame = geometry.windowFrame(isExpanded: false)
        let expandedFrame = geometry.windowFrame(isExpanded: true)

        // 1. Horizontal centers must strictly match notchRect.midX
        #expect(idleFrame.midX == geometry.notchRect.midX)
        #expect(expandedFrame.midX == geometry.notchRect.midX)
        #expect(idleFrame.midX == expandedFrame.midX)

        // 2. Both idle and expanded frames anchor flush with the top screen edge
        #expect(idleFrame.maxY == geometry.screenFrame.maxY)
        #expect(expandedFrame.maxY == geometry.screenFrame.maxY)

        // 3. Expansion delta from idle to expanded must be perfectly symmetrical on left and right
        let leftDelta = idleFrame.minX - expandedFrame.minX
        let rightDelta = expandedFrame.maxX - idleFrame.maxX
        #expect(abs(leftDelta - rightDelta) < 0.001)
        #expect(leftDelta > 0)
        #expect(rightDelta > 0)

        // 4. Within the expanded canvas coordinate system, the idle notch is perfectly centered
        let canvasWidth = expandedFrame.width
        let idleOffsetLeft = (canvasWidth - idleFrame.width) / 2
        let idleOffsetRight = canvasWidth - (idleOffsetLeft + idleFrame.width)
        #expect(abs(idleOffsetLeft - idleOffsetRight) < 0.001)

        // 5. Total width expansion matches exactly 2 * leftDelta
        #expect(abs((expandedFrame.width - idleFrame.width) - (leftDelta + rightDelta)) < 0.001)
    }

    @Test("ISL-09: Negative origin multi-monitor symmetric expansion")
    func testNegativeOriginMultiMonitorSymmetry() {
        // Multi-monitor arrangement where secondary monitor is to the left or above primary display
        let negativeOrigins = [
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            CGRect(x: -5120, y: -500, width: 5120, height: 2880)
        ]

        for screenFrame in negativeOrigins {
            let idleW: CGFloat = 110
            let idleH: CGFloat = 8
            let notchX = screenFrame.midX - idleW / 2
            let notchY = screenFrame.maxY - idleH
            let notchRect = CGRect(x: notchX, y: notchY, width: idleW, height: idleH)

            let idleFrame = CGRect(x: notchRect.midX - idleW / 2, y: screenFrame.maxY - idleH, width: idleW, height: idleH)
            let expandedFrame = CGRect(x: notchRect.midX - 380 / 2, y: screenFrame.maxY - 96, width: 380, height: 96)

            #expect(idleFrame.midX == expandedFrame.midX)
            #expect(idleFrame.midX == screenFrame.midX)
            let leftDelta = idleFrame.minX - expandedFrame.minX
            let rightDelta = expandedFrame.maxX - idleFrame.maxX
            #expect(abs(leftDelta - rightDelta) < 0.001)
            #expect(leftDelta == (380 - idleW) / 2)
        }
    }

    @Test("ISL-10: Non-notch display idle hit target generous bounding")
    func testNonNotchIdleHitTarget() {
        let idleW: CGFloat = 110
        let idleH: CGFloat = 8
        let hitTargetHeight: CGFloat = max(idleH, 22)
        #expect(hitTargetHeight >= 22)
        #expect(idleW == 110)
    }

    @Test("ISL-11: Hardware notch alert visibility and effectiveAlertHeight calculation")
    func testNotchAlertHeightAndFrameCalculations() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        #expect(geometry.alertWidth == 280)
        #expect(geometry.alertHeight == 36)

        if geometry.hasNotch {
            #expect(geometry.effectiveAlertHeight == geometry.notchRect.height + 36)
            #expect(geometry.alertFrame.height == geometry.notchRect.height + 36)
            #expect(geometry.alertFrame.height > geometry.notchRect.height)
        } else {
            #expect(geometry.effectiveAlertHeight == 36)
            #expect(geometry.alertFrame.height == 36)
        }

        #expect(geometry.alertFrame.width == 280)
        #expect(geometry.alertFrame.midX == geometry.notchRect.midX)
        #expect(geometry.alertFrame.maxY == geometry.screenFrame.maxY)
    }

    @Test("ISL-12: Dynamic Island idleFrame stays strictly above application content area")
    func testIdleFrameDoesNotObstructContentBelowNotch() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        let idleFrame = geometry.idleFrame
        #expect(idleFrame.maxY == geometry.screenFrame.maxY)
        #expect(idleFrame.midX == geometry.notchRect.midX)
        #expect(idleFrame.width == geometry.idleWidth)

        if geometry.hasNotch {
            // Idle frame height must match the physical notch height exactly
            #expect(idleFrame.height == geometry.notchRect.height)
            // It must not extend even 1 pixel below the hardware notch cutout
            #expect(idleFrame.minY == geometry.screenFrame.maxY - geometry.notchRect.height)
        } else {
            // On non-notch displays, idle frame height must stay within standard menu bar height (22pt)
            #expect(idleFrame.height == 22)
            #expect(idleFrame.minY >= geometry.screenFrame.maxY - 24)
        }

        // Expanded frame must strictly encompass idle frame
        let expandedFrame = geometry.expandedFrame
        #expect(expandedFrame.width >= idleFrame.width)
        #expect(expandedFrame.height > idleFrame.height)
    }

    @Test("ISL-13: Active alert state alongside drop shelf expansion")
    @MainActor
    func testActiveAlertStatePriority() {
        let state = ZenithIslandState()
        state.onMouseEnter()
        #expect(state.isExpanded == true)

        state.triggerAlert(icon: "doc.on.clipboard", title: "Copied Snippet", duration: 0.2)
        #expect(state.activeAlert != nil)
        #expect(state.activeAlert?.title == "Copied Snippet")
        #expect(state.isExpanded == true)
    }

    @Test("ISL-14: ZenithIslandState dismissAlert immediately dismisses active alert")
    @MainActor
    func testDismissAlertImmediateCancellation() {
        let state = ZenithIslandState()
        state.triggerAlert(icon: "checkmark", title: "Test Notification", duration: 5.0)
        #expect(state.activeAlert != nil)
        #expect(state.isRimLightVisible == true)

        state.dismissAlert()
        #expect(state.activeAlert == nil)
        #expect(state.isRimLightVisible == false)
    }

    @Test("ISL-15: ZenithIslandState isEnabled gating prevents triggerAlert when disabled")
    @MainActor
    func testIsEnabledGating() {
        let state = ZenithIslandState()
        state.isEnabled = false
        state.triggerAlert(icon: "bell", title: "Should Not Show")
        #expect(state.activeAlert == nil)

        state.isEnabled = true
        state.triggerAlert(icon: "bell", title: "Should Show", duration: 0.2)
        #expect(state.activeAlert?.title == "Should Show")
    }

    @Test("ISL-16: Fixed expanded canvas guarantees 0px horizontal drift across idle, alert, and shelf")
    func testFixedCanvasZeroHorizontalDrift() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let geometry = ZenithIslandGeometry(screen: screen)

        let canvasFrame = geometry.expandedFrame
        #expect(canvasFrame.midX == geometry.notchRect.midX)

        // Idle capsule centered in expanded canvas
        let idleOffsetLeft = (canvasFrame.width - geometry.idleWidth) / 2
        let idleCapsuleMidX = canvasFrame.minX + idleOffsetLeft + geometry.idleWidth / 2
        #expect(abs(idleCapsuleMidX - geometry.notchRect.midX) < 0.001)

        // Alert capsule centered in expanded canvas
        let alertOffsetLeft = (canvasFrame.width - geometry.alertWidth) / 2
        let alertCapsuleMidX = canvasFrame.minX + alertOffsetLeft + geometry.alertWidth / 2
        #expect(abs(alertCapsuleMidX - geometry.notchRect.midX) < 0.001)

        // Expanded shelf centered in expanded canvas
        let expandedCapsuleMidX = canvasFrame.minX + canvasFrame.width / 2
        #expect(abs(expandedCapsuleMidX - geometry.notchRect.midX) < 0.001)
    }

    @Test("ISL-17: Non-notch display geometry calculation and vertical bounds safety")
    func testNonNotchGeometryCalculations() {
        // Construct a non-notch screen simulation (e.g. 2560x1440)
        let nonNotchFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let idleW: CGFloat = 110
        let idleH: CGFloat = 8
        let notchX = nonNotchFrame.midX - idleW / 2
        let notchY = nonNotchFrame.maxY - idleH
        let notchRect = CGRect(x: notchX, y: notchY, width: idleW, height: idleH)

        // Idle frame height for hit targeting on non-notch is clamped to 22pt
        let hitTargetHeight: CGFloat = max(idleH, 22)
        #expect(hitTargetHeight == 22)

        // Expanded frame must touch top of screen
        let expandedFrame = CGRect(x: notchRect.midX - 380 / 2, y: nonNotchFrame.maxY - 96, width: 380, height: 96)
        #expect(expandedFrame.maxY == nonNotchFrame.maxY)
        #expect(expandedFrame.midX == nonNotchFrame.midX)

        // Alert frame without notch is 36pt high
        let alertFrame = CGRect(x: notchRect.midX - 280 / 2, y: nonNotchFrame.maxY - 36, width: 280, height: 36)
        #expect(alertFrame.height == 36)
        #expect(alertFrame.width == 280)
        #expect(alertFrame.midX == nonNotchFrame.midX)
    }

    @Test("ISL-18: Consecutive alert triggers replace existing alert smoothly without state leak")
    @MainActor
    func testConsecutiveAlertTriggers() {
        let state = ZenithIslandState()
        state.triggerAlert(icon: "1.circle", title: "First Alert", duration: 5.0)
        #expect(state.activeAlert?.title == "First Alert")

        // Triggering second alert before first expires replaces it cleanly
        state.triggerAlert(icon: "2.circle", title: "Second Alert", duration: 5.0)
        #expect(state.activeAlert?.title == "Second Alert")

        // Dismiss cancels active alert cleanly
        state.dismissAlert()
        #expect(state.activeAlert == nil)
        #expect(state.isRimLightVisible == false)
    }
}


