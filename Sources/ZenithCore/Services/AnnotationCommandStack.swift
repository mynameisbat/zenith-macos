import Foundation
import CoreGraphics
import Observation
import Combine

/// Thread-safe reversible command stack managing vector annotation undo/redo history.
/// Conforms to `@Observable` (SwiftUI) and `ObservableObject` (Combine/AppKit).
@Observable
public final class AnnotationCommandStack: ObservableObject, @unchecked Sendable {
    @ObservationIgnored
    private let lock = NSLock()

    @ObservationIgnored
    private var _commands: [AnnotationCommand] = []

    @ObservationIgnored
    private var _redoStack: [AnnotationCommand] = []

    @ObservationIgnored
    private var _version: Int = 0

    public let maxCapacity: Int

    // MARK: - Initializer

    public init(maxCapacity: Int = 50, initialCommands: [AnnotationCommand] = []) {
        self.maxCapacity = max(1, maxCapacity)
        self._commands = Array(initialCommands.suffix(self.maxCapacity))
        self._redoStack = []
        self._version = 0
    }

    // MARK: - Public State (Thread-Safe & Observable)

    public var commands: [AnnotationCommand] {
        access(keyPath: \.commands)
        lock.lock()
        defer { lock.unlock() }
        return _commands
    }

    public var canUndo: Bool {
        access(keyPath: \.canUndo)
        lock.lock()
        defer { lock.unlock() }
        return !_commands.isEmpty
    }

    public var canRedo: Bool {
        access(keyPath: \.canRedo)
        lock.lock()
        defer { lock.unlock() }
        return !_redoStack.isEmpty
    }

    public var count: Int {
        access(keyPath: \.count)
        lock.lock()
        defer { lock.unlock() }
        return _commands.count
    }

    public var undoCount: Int {
        access(keyPath: \.undoCount)
        lock.lock()
        defer { lock.unlock() }
        return _commands.count
    }

    public var redoCount: Int {
        access(keyPath: \.redoCount)
        lock.lock()
        defer { lock.unlock() }
        return _redoStack.count
    }

    public var activeCrop: CropAnnotationCommand? {
        access(keyPath: \.activeCrop)
        lock.lock()
        defer { lock.unlock() }
        return _commands.compactMap { $0 as? CropAnnotationCommand }.last
    }

    public var version: Int {
        access(keyPath: \.version)
        lock.lock()
        defer { lock.unlock() }
        return _version
    }

    // MARK: - Mutating Actions

    public func push(_ command: AnnotationCommand) {
        lock.lock()
        _commands.append(command)
        _redoStack.removeAll()

        while _commands.count > maxCapacity {
            _commands.removeFirst()
        }
        _version &+= 1
        lock.unlock()
        notifyChange()
    }

    @discardableResult
    public func undo() -> AnnotationCommand? {
        lock.lock()
        guard let last = _commands.popLast() else {
            lock.unlock()
            return nil
        }
        _redoStack.append(last)
        _version &+= 1
        lock.unlock()
        notifyChange()
        return last
    }

    @discardableResult
    public func redo() -> AnnotationCommand? {
        lock.lock()
        guard let next = _redoStack.popLast() else {
            lock.unlock()
            return nil
        }
        _commands.append(next)
        _version &+= 1
        lock.unlock()
        notifyChange()
        return next
    }

    public func replaceTop(_ command: AnnotationCommand) {
        lock.lock()
        if !_commands.isEmpty {
            _commands[_commands.count - 1] = command
        } else {
            _commands.append(command)
        }
        _version &+= 1
        lock.unlock()
        notifyChange()
    }

    public func clear() {
        lock.lock()
        _commands.removeAll()
        _redoStack.removeAll()
        _version &+= 1
        lock.unlock()
        notifyChange()
    }

    // MARK: - Observation Notification Helper

    private func notifyChange() {
        if Thread.isMainThread {
            withMutation(keyPath: \.commands) {}
            withMutation(keyPath: \.canUndo) {}
            withMutation(keyPath: \.canRedo) {}
            withMutation(keyPath: \.count) {}
            withMutation(keyPath: \.undoCount) {}
            withMutation(keyPath: \.redoCount) {}
            withMutation(keyPath: \.activeCrop) {}
            withMutation(keyPath: \.version) {}
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.withMutation(keyPath: \.commands) {}
                self.withMutation(keyPath: \.canUndo) {}
                self.withMutation(keyPath: \.canRedo) {}
                self.withMutation(keyPath: \.count) {}
                self.withMutation(keyPath: \.undoCount) {}
                self.withMutation(keyPath: \.redoCount) {}
                self.withMutation(keyPath: \.activeCrop) {}
                self.withMutation(keyPath: \.version) {}
                self.objectWillChange.send()
            }
        }
    }
}
