import Foundation
import CoreGraphics
import Combine

/// Thread-safe reversible command stack managing vector annotation undo/redo history.
/// An `ObservableObject`: SwiftUI views hold it with `@ObservedObject`, AppKit code subscribes to `objectWillChange`.
public final class AnnotationCommandStack: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()

    private var _commands: [AnnotationCommand] = []

    private var _redoStack: [AnnotationCommand] = []

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
        lock.lock()
        defer { lock.unlock() }
        return _commands
    }

    public var canUndo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_commands.isEmpty
    }

    public var canRedo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_redoStack.isEmpty
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _commands.count
    }

    public var undoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _commands.count
    }

    public var redoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _redoStack.count
    }

    public var activeCrop: CropAnnotationCommand? {
        lock.lock()
        defer { lock.unlock() }
        return _commands.compactMap { $0 as? CropAnnotationCommand }.last
    }

    public var version: Int {
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

    // MARK: - Change Notification Helper

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
            }
        }
    }
}
