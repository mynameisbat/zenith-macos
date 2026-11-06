import Foundation

/// Calendar events for tests and screenshots: never touches the user's calendars or asks for access.
public final class MockUpcomingEventProvider: UpcomingEventProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: CalendarAccessState
    private var _events: [UpcomingEvent]
    private let grantsOnRequest: Bool
    public private(set) var requestCount = 0

    public init(state: CalendarAccessState = .granted, events: [UpcomingEvent] = [], grantsOnRequest: Bool = true) {
        self._state = state
        self._events = events
        self.grantsOnRequest = grantsOnRequest
    }

    public var events: [UpcomingEvent] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }

    public func accessState() -> CalendarAccessState {
        lock.withLock { _state }
    }

    public func requestAccess() async -> Bool {
        lock.withLock {
            requestCount += 1
            if _state == .notDetermined {
                _state = grantsOnRequest ? .granted : .denied
            }
            return _state == .granted
        }
    }

    public func events(from start: Date, to end: Date) -> [UpcomingEvent] {
        lock.withLock {
            guard _state == .granted else { return [] }
            return _events.filter { $0.end > start && $0.start < end }
        }
    }
}
