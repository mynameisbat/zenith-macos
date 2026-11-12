import Testing
import Foundation
@testable import ZenithCore

@Suite("Island Scroll Gesture Suite")
struct IslandScrollGestureTests {

    /// Feeds a swipe as a touch that begins, moves in equal steps and lifts; returns every action it produced.
    private func swipe(
        _ gesture: inout IslandScrollGesture,
        right: Double = 0, down: Double = 0, steps: Int = 8,
        isExpanded: Bool, allowsTrackChange: Bool = true, at start: TimeInterval = 0
    ) -> [IslandScrollGesture.Action] {
        var actions: [IslandScrollGesture.Action] = []
        func feed(_ sample: IslandScrollGesture.Sample) {
            if let action = gesture.handle(sample, isExpanded: isExpanded, allowsTrackChange: allowsTrackChange) {
                actions.append(action)
            }
        }
        feed(.init(fingersRight: 0, fingersDown: 0, phase: .began, timestamp: start))
        for step in 1...steps {
            feed(.init(fingersRight: right / Double(steps), fingersDown: down / Double(steps), phase: .changed,
                       timestamp: start + Double(step) * 0.01))
        }
        feed(.init(fingersRight: 0, fingersDown: 0, phase: .ended, timestamp: start + 0.2))
        return actions
    }

    @Test("ISG-01: Pulling down opens a closed island and pushing up closes an open one, once per swipe")
    func testVerticalSwipes() {
        var gesture = IslandScrollGesture()
        #expect(swipe(&gesture, down: 120, isExpanded: false) == [.open])
        #expect(swipe(&gesture, down: -120, isExpanded: true) == [.close])
        // The wrong way round does nothing.
        #expect(swipe(&gesture, down: -120, isExpanded: false).isEmpty)
        #expect(swipe(&gesture, down: 120, isExpanded: true).isEmpty)
    }

    @Test("ISG-02: Sideways changes track: fingers left is next, right is previous")
    func testHorizontalSwipes() {
        var gesture = IslandScrollGesture()
        #expect(swipe(&gesture, right: -90, isExpanded: false) == [.nextTrack])
        #expect(swipe(&gesture, right: 90, isExpanded: true) == [.previousTrack])
        #expect(swipe(&gesture, right: -90, isExpanded: true, allowsTrackChange: false).isEmpty)
    }

    @Test("ISG-03: A short movement is not a swipe, and a diagonal one follows the axis it started on")
    func testThresholdsAndAxisLock() {
        var gesture = IslandScrollGesture()
        #expect(swipe(&gesture, down: 12, isExpanded: false).isEmpty)
        #expect(swipe(&gesture, right: -20, isExpanded: false).isEmpty)
        // Mostly sideways with some drift down: a track change, never an opening.
        #expect(swipe(&gesture, right: -90, down: 40, isExpanded: false) == [.nextTrack])
        // Mostly down with sideways drift: an opening only.
        #expect(swipe(&gesture, right: 50, down: 120, isExpanded: false) == [.open])
    }

    @Test("ISG-04: The inertia after a swipe never acts")
    func testMomentumIsIgnored() {
        var gesture = IslandScrollGesture()
        #expect(swipe(&gesture, down: 120, isExpanded: false) == [.open])
        for step in 0..<20 {
            let sample = IslandScrollGesture.Sample(fingersRight: 0, fingersDown: -30, phase: .momentum,
                                                    timestamp: 1 + Double(step) * 0.01)
            #expect(gesture.handle(sample, isExpanded: true, allowsTrackChange: true) == nil)
        }
    }

    @Test("ISG-05: A wheel without touch phases acts once per burst, and again after a pause")
    func testWheelWithoutPhases() {
        var gesture = IslandScrollGesture()
        var actions: [IslandScrollGesture.Action] = []
        for notch in 0..<6 {
            let sample = IslandScrollGesture.Sample(fingersRight: 0, fingersDown: 10, phase: .none,
                                                    timestamp: Double(notch) * 0.05)
            if let action = gesture.handle(sample, isExpanded: false, allowsTrackChange: true) { actions.append(action) }
        }
        #expect(actions == [.open])

        // Later, rolled the other way on the island that is now open.
        for notch in 0..<6 {
            let sample = IslandScrollGesture.Sample(fingersRight: 0, fingersDown: -10, phase: .none,
                                                    timestamp: 2 + Double(notch) * 0.05)
            if let action = gesture.handle(sample, isExpanded: true, allowsTrackChange: true) { actions.append(action) }
        }
        #expect(actions == [.open, .close])
    }
}
