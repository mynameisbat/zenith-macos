import Foundation
import CoreGraphics

/// Service protocol abstracting system pasteboard monitoring and write operations.
public protocol PasteboardServiceProtocol: Sendable {
    /// Starts polling or observing the system pasteboard for changes.
    /// - Parameter onChange: Closure invoked when a new unique item is detected.
    func startMonitoring(onChange: @escaping @Sendable (ClipboardItem) -> Void)
    
    /// Stops pasteboard monitoring and releases any active timer or dispatch source.
    func stopMonitoring()
    
    /// Restores a historical clipboard item back to the system pasteboard.
    /// - Parameter item: The clipboard item to restore.
    func copyItemToPasteboard(_ item: ClipboardItem)
    
    /// Writes a rendered raster image directly to the system pasteboard.
    /// - Parameter image: The CoreGraphics image to copy.
    func writeImageToPasteboard(_ image: CGImage)
    
    /// Clears all contents from the system pasteboard.
    func clear()
    
    /// Current change count reported by the system pasteboard.
    var changeCount: Int { get }
}

public extension PasteboardServiceProtocol {
    func clear() {}
    var changeCount: Int { 0 }
}
