import Foundation

/// Errors that can occur during history persistence operations.
public enum StorageError: Error, Sendable, Equatable {
    case encodingFailed(reason: String)
    case decodingFailed(reason: String)
    case ioError(reason: String)
    case fileNotFound
}

/// Service protocol for persisting and reading clipboard history entries.
public protocol StorageServiceProtocol: Sendable {
    /// Persists the list of clipboard items to durable storage.
    /// - Parameter items: The array of clipboard items to save.
    /// - Throws: `StorageError` if serialization or disk write fails.
    func saveItems(_ items: [ClipboardItem]) throws
    
    /// Loads previously saved clipboard items from durable storage.
    /// - Returns: An array of clipboard items in recency order.
    /// - Throws: `StorageError` if file read or deserialization fails.
    func loadItems() throws -> [ClipboardItem]
    
    /// Purges all stored items from storage.
    /// - Throws: `StorageError` if deletion fails.
    func clearItems() throws
}
