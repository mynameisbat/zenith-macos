import Foundation
import Combine

// Cleaning Mode blocks the keyboard, trackpad and mouse for a short while so the screen and keys can be wiped.
//
// The rule that shapes everything here: the user must never be locked out. Input comes back
//  - when the time limit runs out (checked by a timer AND by every blocked event, so a stalled timer cannot keep it on),
//  - when the exit gesture is held (⌃⌥⌘ together, nothing else, for 2 seconds),
//  - when macOS disables the event tap (it does that to a tap that is too slow, or on the user's secure-input request),
//  - when the app quits (and an event tap dies with its process anyway).
// The event tap, the timer and the full-screen windows sit behind seams, so tests never block real input.

/// Modifier keys, as Cleaning Mode reads them from an event. Caps Lock, Fn and the numeric-pad bit are ignored.
public struct CleaningModeModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = CleaningModeModifiers(rawValue: 1 << 0)
    public static let option = CleaningModeModifiers(rawValue: 1 << 1)
    public static let command = CleaningModeModifiers(rawValue: 1 << 2)
    public static let shift = CleaningModeModifiers(rawValue: 1 << 3)
}

/// One input event, reduced to what Cleaning Mode needs to know about it.
public enum CleaningModeInputEvent: Sendable, Equatable {
    case keyDown(keyCode: UInt16)
    case keyUp(keyCode: UInt16)
    /// The set of modifier keys held changed (a modifier went down or up). Carries the modifiers held now.
    case modifiersChanged(CleaningModeModifiers)
    /// A click, drag or pointer move.
    case pointer
    case scroll
    /// Media, volume and brightness keys, which arrive as system-defined events.
    case systemDefined
    /// Trackpad gestures (pinch, rotate, swipe, smart zoom, Force Touch pressure).
    case gesture
}

/// Why macOS switched the event tap off.
public enum CleaningModeTapDisableReason: Sendable, Equatable {
    /// The tap's callback took too long.
    case timeout
    /// The user (or secure input) asked for it.
    case userInput
}

public enum CleaningModeEndReason: Sendable, Equatable {
    case timeLimit
    case exitGesture
    case tapDisabled(CleaningModeTapDisableReason)
    case appQuit
    /// Something in the app ended it (an error, or a caller that wanted it off).
    case stopped
}

/// The deliberate way out: hold Control, Option and Command together, and no other key, for two seconds.
/// Pressing any other key, or adding or releasing a modifier, starts the wait over. Feeding the same modifiers
/// twice (the tap and the overlay window can both see one change) does not restart it.
public struct CleaningModeExitGesture: Sendable, Equatable {
    public static let requiredModifiers: CleaningModeModifiers = [.control, .option, .command]
    public static let holdDuration: TimeInterval = 2
    /// The keys as the overlay shows them.
    public static let keysText = "⌃ ⌥ ⌘"

    public private(set) var holdStartedAt: Date?

    public init() {}

    public mutating func observe(_ event: CleaningModeInputEvent, at now: Date) {
        switch event {
        case .modifiersChanged(let modifiers):
            if modifiers == Self.requiredModifiers {
                if holdStartedAt == nil { holdStartedAt = now }
            } else {
                holdStartedAt = nil
            }
        case .keyDown:
            holdStartedAt = nil
        case .keyUp, .pointer, .scroll, .systemDefined, .gesture:
            break
        }
    }

    /// 0 when the keys are not held, 1 when they have been held long enough.
    public func progress(at now: Date) -> Double {
        guard let start = holdStartedAt else { return 0 }
        return min(max(now.timeIntervalSince(start) / Self.holdDuration, 0), 1)
    }

    public func isComplete(at now: Date) -> Bool {
        progress(at: now) >= 1
    }

    public mutating func reset() {
        holdStartedAt = nil
    }
}

// MARK: - Seams

/// Installs and removes the system-wide event tap. The real one is `SystemCleaningModeEventTap`; tests use
/// `MockCleaningModeEventTap`, which never touches real input.
@MainActor
public protocol CleaningModeEventTapping: AnyObject {
    /// Starts blocking. `onEvent` returns `true` to swallow the event, `false` to let it through.
    /// - Throws: when the tap cannot be created (usually: no Accessibility permission).
    func install(
        onEvent: @escaping @MainActor (CleaningModeInputEvent) -> Bool,
        onDisabled: @escaping @MainActor (CleaningModeTapDisableReason) -> Void
    ) throws
    /// Stops blocking. Safe to call when nothing is installed, and from inside `onEvent`.
    func remove()
}

/// Shows and hides the full-screen windows. The app supplies the real one.
@MainActor
public protocol CleaningModePresenting: AnyObject {
    func present(appearance: CleaningModeAppearance)
    func dismiss()
}

/// A repeating timer on the main thread.
@MainActor
public protocol CleaningModeTicking: AnyObject {
    func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void)
    func stop()
}

/// The real timer: a main-run-loop `Timer` in the common modes, so it keeps running while a menu is open.
@MainActor
public final class TimerCleaningModeTicker: CleaningModeTicking {
    private var timer: Timer?

    public init() {}

    public func start(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}

public enum CleaningModeError: Error, Equatable, LocalizedError {
    case tapUnavailable

    public var errorDescription: String? {
        String(localized: "macOS did not let Zenith block the keyboard and trackpad.")
    }
}

// MARK: - Controller

/// The Cleaning Mode state machine: idle → active → idle. `@MainActor`; the event tap delivers on the main run loop.
@MainActor
public final class CleaningModeController: ObservableObject {
    public static let shared = CleaningModeController()

    public enum StartResult: Sendable, Equatable {
        case started
        case alreadyActive
        /// Accessibility is not granted. Nothing was blocked; explain it and open the Permissions page.
        case needsAccessibility
        /// The tap could not be created although the permission looked granted.
        case tapUnavailable
    }

    /// How often the countdown and the exit-hold progress are refreshed.
    public static let tickInterval: TimeInterval = 0.1

    @Published public private(set) var isActive = false
    @Published public private(set) var endsAt: Date?
    @Published public private(set) var remainingSeconds = 0
    /// How far the exit gesture has been held, 0…1.
    @Published public private(set) var exitHoldProgress: Double = 0
    @Published public private(set) var lastEndReason: CleaningModeEndReason?
    @Published public private(set) var appearance: CleaningModeAppearance = .black

    /// Events swallowed since the last start (tests read it).
    public private(set) var swallowedEventCount = 0

    /// The full-screen windows. Set by the app at launch; nil in tests that do not need it.
    public var presenter: CleaningModePresenting?
    /// Called after Cleaning Mode ended, with the reason.
    public var onEnd: ((CleaningModeEndReason) -> Void)?

    private let settings: CleaningModeSettings
    private let permissions: PermissionsServiceProtocol
    private let tap: CleaningModeEventTapping
    private let ticker: CleaningModeTicking
    private let now: () -> Date
    private let announce: (String) -> Void
    private var exitGesture = CleaningModeExitGesture()

    public init(
        settings: CleaningModeSettings = .shared,
        permissions: PermissionsServiceProtocol = SystemPermissionsService.shared,
        tap: CleaningModeEventTapping = SystemCleaningModeEventTap(),
        ticker: CleaningModeTicking = TimerCleaningModeTicker(),
        now: @escaping () -> Date = Date.init,
        announce: @escaping (String) -> Void = { AccessibilityAnnouncer.announce($0) }
    ) {
        self.settings = settings
        self.permissions = permissions
        self.tap = tap
        self.ticker = ticker
        self.now = now
        self.announce = announce
    }

    /// Starts blocking input, or says why it did not.
    @discardableResult
    public func start() -> StartResult {
        guard !isActive else { return .alreadyActive }
        guard permissions.checkAccessibilityPermission() else { return .needsAccessibility }

        do {
            try tap.install(
                onEvent: { [weak self] event in self?.handle(event) ?? false },
                onDisabled: { [weak self] reason in self?.end(.tapDisabled(reason)) }
            )
        } catch {
            tap.remove()
            return .tapUnavailable
        }

        let duration = CleaningModeSettings.clamp(settings.durationSeconds)
        let startedAt = now()
        exitGesture.reset()
        swallowedEventCount = 0
        appearance = settings.appearance
        endsAt = startedAt.addingTimeInterval(TimeInterval(duration))
        remainingSeconds = duration
        exitHoldProgress = 0
        lastEndReason = nil
        isActive = true

        presenter?.present(appearance: appearance)
        ticker.start(interval: Self.tickInterval) { [weak self] in self?.tick() }
        announce(String(localized: "Cleaning Mode on. The keyboard and trackpad are blocked for \(CleaningModeSettings.durationText(duration)). To stop early, hold Control, Option and Command for 2 seconds."))
        return .started
    }

    /// Decides what happens to one blocked event. Returns `true` to swallow it.
    /// Also checks the time limit, so input comes back on time even if the timer stalls.
    public func handle(_ event: CleaningModeInputEvent) -> Bool {
        guard isActive, let endsAt else { return false }
        let time = now()
        if time >= endsAt {
            end(.timeLimit)
            return false
        }
        exitGesture.observe(event, at: time)
        if exitGesture.isComplete(at: time) {
            end(.exitGesture)
            return true
        }
        let progress = exitGesture.progress(at: time)
        if progress != exitHoldProgress { exitHoldProgress = progress }
        swallowedEventCount += 1
        return true
    }

    /// Called by the timer: moves the countdown and ends Cleaning Mode when time is up or the exit keys were held.
    public func tick() {
        guard isActive, let endsAt else { return }
        let time = now()
        if time >= endsAt {
            end(.timeLimit)
            return
        }
        if exitGesture.isComplete(at: time) {
            end(.exitGesture)
            return
        }
        let remaining = Int(endsAt.timeIntervalSince(time).rounded(.up))
        if remaining != remainingSeconds { remainingSeconds = remaining }
        let progress = exitGesture.progress(at: time)
        if progress != exitHoldProgress { exitHoldProgress = progress }
    }

    /// Ends Cleaning Mode and gives input back. Does nothing when it is not on.
    public func end(_ reason: CleaningModeEndReason) {
        guard isActive else { return }
        isActive = false
        ticker.stop()
        tap.remove()
        presenter?.dismiss()
        endsAt = nil
        remainingSeconds = 0
        exitHoldProgress = 0
        exitGesture.reset()
        lastEndReason = reason
        announce(Self.endMessage(for: reason))
        onEnd?(reason)
    }

    public static func endMessage(for reason: CleaningModeEndReason) -> String {
        switch reason {
        case .timeLimit:
            return String(localized: "Cleaning Mode off: time is up. The keyboard and trackpad work again.")
        case .tapDisabled:
            return String(localized: "Cleaning Mode stopped because macOS turned off input blocking. The keyboard and trackpad work again.")
        case .exitGesture, .appQuit, .stopped:
            return String(localized: "Cleaning Mode off. The keyboard and trackpad work again.")
        }
    }
}
