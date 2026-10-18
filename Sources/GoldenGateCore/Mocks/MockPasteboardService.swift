#if DEBUG
import Foundation
import CoreGraphics

/// Thread-safe in-memory pasteboard mock for headless testing.
public final class MockPasteboardService: PasteboardServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ClipboardItem] = []
    private var _copiedItems: [ClipboardItem] = []
    private var _copiedImages: [CGImage] = []
    private var _isMonitoring: Bool = false
    private var _onChangeHandler: (@Sendable (ClipboardItem) -> Void)?
    private var _changeCount: Int = 0

    public init(initialItems: [ClipboardItem] = []) {
        self._items = initialItems
        self._changeCount = initialItems.count
    }

    public var items: [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        return _items
    }

    public var copiedItems: [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }
        return _copiedItems
    }

    public var copiedImages: [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return _copiedImages
    }

    public var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoring
    }

    public var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _changeCount
    }

    public func startMonitoring(onChange: @escaping @Sendable (ClipboardItem) -> Void) {
        lock.lock()
        _isMonitoring = true
        _onChangeHandler = onChange
        lock.unlock()
    }

    public func stopMonitoring() {
        lock.lock()
        _isMonitoring = false
        _onChangeHandler = nil
        lock.unlock()
    }

    public func copyItemToPasteboard(_ item: ClipboardItem) {
        lock.lock()
        _changeCount += 1
        _copiedItems.append(item)
        _items.insert(item, at: 0)
        let handler = _onChangeHandler
        let monitoring = _isMonitoring
        lock.unlock()

        if monitoring {
            handler?(item)
        }
    }

    public func writeImageToPasteboard(_ image: CGImage) {
        lock.lock()
        _changeCount += 1
        _copiedImages.append(image)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        _changeCount += 1
        _items.removeAll()
        lock.unlock()
    }

    /// Simulates an external application copying content to the macOS pasteboard.
    public func simulateExternalCopy(_ item: ClipboardItem) {
        lock.lock()
        _changeCount += 1
        _items.insert(item, at: 0)
        let handler = _onChangeHandler
        let monitoring = _isMonitoring
        lock.unlock()

        if monitoring {
            handler?(item)
        }
    }

    /// Resets all mock recording state.
    public func reset() {
        lock.lock()
        _items.removeAll()
        _copiedItems.removeAll()
        _copiedImages.removeAll()
        _isMonitoring = false
        _onChangeHandler = nil
        _changeCount = 0
        lock.unlock()
    }
}
#endif
