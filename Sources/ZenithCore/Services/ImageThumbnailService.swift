import Foundation
import CoreGraphics
import ImageIO

/// Concurrency-safe service for high-performance image thumbnail generation and in-memory caching.
/// Prevents main-thread UI stalling by using ImageIO hardware-accelerated downsampled decoding.
public final class ImageThumbnailService: @unchecked Sendable {
    public static let shared = ImageThumbnailService()

    private let cache = NSCache<NSUUID, CGImage>()
    public let defaultMaxPixelDimension: Int

    public init(maxCacheCount: Int = 80, defaultMaxPixelDimension: Int = 128) {
        self.defaultMaxPixelDimension = defaultMaxPixelDimension
        self.cache.countLimit = maxCacheCount
        // 128x128 RGBA thumbnail ≈ 64KB. 80 items ≈ 5.1MB. Safety limit at 10MB.
        self.cache.totalCostLimit = 10 * 1024 * 1024
    }

    /// Fast synchronous memory cache lookup (< 0.01ms). Completely safe to call on MainActor.
    public func cachedThumbnail(for id: UUID) -> CGImage? {
        cache.object(forKey: id as NSUUID)
    }

    /// Stores a thumbnail in the in-memory cache.
    public func storeThumbnail(_ image: CGImage, for id: UUID) {
        let cost = image.bytesPerRow * image.height
        cache.setObject(image, forKey: id as NSUUID, cost: cost)
    }

    /// Purges all cached thumbnails from memory.
    public func clearCache() {
        cache.removeAllObjects()
    }

    /// Generates a downsampled thumbnail directly from raw image bytes via ImageIO.
    /// Does NOT allocate full-resolution image buffers in memory.
    public func generateThumbnail(from data: Data, maxPixelDimension: Int? = nil) -> CGImage? {
        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Generates a downsampled thumbnail directly from a file URL via ImageIO without loading full file into RAM.
    public func generateThumbnail(from url: URL, maxPixelDimension: Int? = nil) -> CGImage? {
        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Retrieves cached thumbnail or generates one asynchronously on a background thread.
    public func thumbnail(for id: UUID, data: Data, maxPixelDimension: Int? = nil) async -> CGImage? {
        if let cached = cachedThumbnail(for: id) {
            return cached
        }

        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        return await Task.detached(priority: .userInitiated) { [weak self] () -> CGImage? in
            guard let self = self else { return nil }
            guard let thumb = self.generateThumbnail(from: data, maxPixelDimension: dimension) else {
                return nil
            }
            self.storeThumbnail(thumb, for: id)
            return thumb
        }.value
    }

    /// Retrieves cached thumbnail or generates one asynchronously from a file URL on a background thread.
    public func thumbnail(for id: UUID, url: URL, maxPixelDimension: Int? = nil) async -> CGImage? {
        if let cached = cachedThumbnail(for: id) {
            return cached
        }

        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        return await Task.detached(priority: .userInitiated) { [weak self] () -> CGImage? in
            guard let self = self else { return nil }
            guard let thumb = self.generateThumbnail(from: url, maxPixelDimension: dimension) else {
                return nil
            }
            self.storeThumbnail(thumb, for: id)
            return thumb
        }.value
    }

    /// Asynchronously pre-warms thumbnail cache from a file URL in the background at utility priority.
    public func preloadThumbnail(for id: UUID, url: URL, maxPixelDimension: Int? = nil) {
        if cachedThumbnail(for: id) != nil { return }
        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            if let thumb = self.generateThumbnail(from: url, maxPixelDimension: dimension) {
                self.storeThumbnail(thumb, for: id)
            }
        }
    }

    /// Asynchronously pre-warms thumbnail cache in the background at utility priority.
    public func preloadThumbnail(for id: UUID, data: Data, maxPixelDimension: Int? = nil) {
        if cachedThumbnail(for: id) != nil { return }
        let dimension = maxPixelDimension ?? defaultMaxPixelDimension
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            if let thumb = self.generateThumbnail(from: data, maxPixelDimension: dimension) {
                self.storeThumbnail(thumb, for: id)
            }
        }
    }
}
