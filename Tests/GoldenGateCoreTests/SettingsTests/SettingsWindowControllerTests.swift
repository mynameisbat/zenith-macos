import Testing
import AppKit
import Foundation
import SwiftUI
@testable import GoldenGateCore

@Suite("SettingsWindowController Lifecycle & Presentation Suite")
struct SettingsWindowControllerTests {

    @Test("SW-01: Window Creation and Styling Invariants")
    @MainActor
    func testWindowCreationAndStyling() {
        let controller = SettingsWindowController()
        let window = controller.createWindow()

        #expect(controller.window != nil)
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.isReleasedWhenClosed == false)
        #expect(window.title == "Zenith Settings")
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titleVisibility == .hidden)
        #expect(window.isMovableByWindowBackground == true)
        #expect(window.isOpaque == false)
        #expect(window.backgroundColor == .clear)

        controller.dismiss()
    }

    @Test("SW-09: Direct Close Button and Multi-Zone Dismissal Verification")
    @MainActor
    func testDirectCloseButtonAndMultiZoneDismissal() {
        let controller = SettingsWindowController()
        controller.viewControllerProvider = {
            NSHostingController(rootView: Text("Preferences Body").frame(width: 680, height: 490))
        }
        guard let window = controller.createWindow() as? SettingsWindow else {
            Issue.record("Window is not SettingsWindow")
            return
        }

        // 1. Verify performClose directly dismisses window
        controller.show()
        #expect(controller.isVisible == true)
        window.performClose(nil)
        #expect(controller.isVisible == false)

        // 2. Verify performClick on close button dismisses window
        controller.show()
        #expect(controller.isVisible == true)
        if let closeBtn = window.standardWindowButton(.closeButton) {
            #expect(closeBtn.isEnabled == true)
            #expect(closeBtn.isHidden == false)
            closeBtn.performClick(nil)
            #expect(controller.isVisible == false)
        }

        // 3. Verify leftMouseUp in close zone dismisses window
        controller.show()
        #expect(controller.isVisible == true)
        let upEvt = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 16, y: 474),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
        )!
        window.sendEvent(upEvt)
        #expect(controller.isVisible == false)

        // 4. Verify clicks in content area do NOT dismiss window
        controller.show()
        #expect(controller.isVisible == true)
        let contentEvt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 340, y: 245),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1.0
        )!
        window.sendEvent(contentEvt)
        #expect(controller.isVisible == true)

        controller.dismiss()
    }

    @Test("SW-02: Window Frame Dimensions and Centering Constraints")
    @MainActor
    func testWindowFrameDimensions() {
        let controller = SettingsWindowController()
        let window = controller.createWindow()

        #expect(window.frame.width == 680)
        #expect(window.frame.height == 490)
        #expect(window.minSize.width == 680)
        #expect(window.minSize.height == 490)
        #expect(window.maxSize.width == 680)
        #expect(window.maxSize.height == 490)

        controller.dismiss()
    }

    @Test("SW-03: Singleton Reuse Idempotency and Zero Duplicate Window Leak")
    @MainActor
    func testSingletonReuseIdempotency() {
        let controller = SettingsWindowController.shared
        controller.show()

        guard let firstWindow = controller.window else {
            Issue.record("First window was nil")
            return
        }

        controller.show()
        guard let secondWindow = controller.window else {
            Issue.record("Second window was nil")
            return
        }

        #expect(firstWindow === secondWindow)
        controller.dismiss()
    }

    @Test("SW-04: Visibility and Dismissal Lifecycle")
    @MainActor
    func testVisibilityAndDismissal() {
        let controller = SettingsWindowController()
        controller.show()
        #expect(controller.isVisible == true)

        controller.dismiss()
        #expect(controller.isVisible == false)

        controller.show()
        #expect(controller.isVisible == true)

        controller.close()
        #expect(controller.isVisible == false)
    }

    @Test("SW-05: Custom View Controller Provider Injection")
    @MainActor
    func testViewControllerProviderInjection() {
        let controller = SettingsWindowController()
        let customVC = NSViewController()
        customVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 490))

        controller.viewControllerProvider = { customVC }
        let window = controller.createWindow()

        #expect(window.contentViewController === customVC)
        controller.dismiss()
    }

    @Test("SW-06: Close Button Direct Action and Delegate Routing")
    @MainActor
    func testCloseButtonActionAndDelegate() {
        let controller = SettingsWindowController()
        let window = controller.createWindow()
        controller.show()
        #expect(controller.isVisible == true)

        // Verify handleCloseButtonAction dismisses window
        controller.handleCloseButtonAction()
        #expect(controller.isVisible == false)

        controller.show()
        #expect(controller.isVisible == true)

        // Verify windowShouldClose dismisses window
        let shouldClose = controller.windowShouldClose(window)
        #expect(shouldClose == true)
        #expect(controller.isVisible == false)
    }

    @Test("SW-07: Key Equivalent Dismissal for ⌘W and Escape")
    @MainActor
    func testKeyEquivalentDismissal() {
        let controller = SettingsWindowController()
        guard let window = controller.createWindow() as? SettingsWindow else {
            Issue.record("Window is not SettingsWindow")
            return
        }

        #expect(window.canBecomeKey == true)
        #expect(window.canBecomeMain == true)

        // 1. Test cancelOperation (Escape)
        controller.show()
        #expect(controller.isVisible == true)
        window.cancelOperation(nil)
        #expect(controller.isVisible == false)

        // 2. Test sendEvent with Escape key (keyCode 53)
        controller.show()
        #expect(controller.isVisible == true)
        if let escEvt = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) {
            window.sendEvent(escEvt)
            #expect(controller.isVisible == false)
        }

        // 3. Test sendEvent with ⌘W
        controller.show()
        #expect(controller.isVisible == true)
        if let cmdWEvt = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ) {
            window.sendEvent(cmdWEvt)
            #expect(controller.isVisible == false)
        }

        // 4. Test keyDown directly with Escape
        controller.show()
        #expect(controller.isVisible == true)
        if let escEvt = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) {
            window.keyDown(with: escEvt)
            #expect(controller.isVisible == false)
        }

        // 5. Test performKeyEquivalent with ⌘W
        controller.show()
        #expect(controller.isVisible == true)
        if let cmdWEvt = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ) {
            let handled = window.performKeyEquivalent(with: cmdWEvt)
            #expect(handled == true)
            #expect(controller.isVisible == false)
        }
    }

    @Test("SW-08: Traffic Light Zone Mouse Event Dismissal")
    @MainActor
    func testTrafficLightZoneMouseEvent() {
        let controller = SettingsWindowController()
        guard let window = controller.createWindow() as? SettingsWindow else {
            Issue.record("Window is not SettingsWindow")
            return
        }

        controller.show()
        #expect(controller.isVisible == true)

        // Simulate click in top-left traffic light zone (x: 14, y: 476)
        let evt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 14, y: 476),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        window.sendEvent(evt)
        #expect(controller.isVisible == false)
    }
}


