import Foundation
import CoreGraphics

// Scrolling capture joins screenshots of the same area taken while its content scrolls. Each new frame is compared
// with the previous one to find how far the content moved (the vertical overlap), and only the rows that are new are
// added. A header or footer that stays put while the content scrolls (a toolbar, a sticky bar) is recognised and kept
// once. All of it is pure image arithmetic, tested with synthetic images.

/// A grayscale copy of a frame used only for matching: full height (offsets must be exact to the pixel) and at most
/// `maxWidth` columns.
public struct LumaImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(_ image: CGImage, maxWidth: Int = 256) {
        let w = max(1, min(image.width, maxWidth))
        let h = image.height
        guard h > 0, let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        // Nearest neighbour: the same columns are sampled in every frame and rows are never blended.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h)
        self.init(width: w, height: h, pixels: Array(buffer))
    }

    /// One number per row (top row first) that changes when any sampled pixel of the row changes noticeably.
    public func rowSignatures() -> [RowSignature] {
        (0..<height).map { row in
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var low: UInt8 = 255
            var high: UInt8 = 0
            let base = row * width
            for x in 0..<width {
                let value = pixels[base + x]
                low = min(low, value)
                high = max(high, value)
                // Ignore the lowest bits so tiny rendering noise does not break a match.
                hash = (hash ^ UInt64(value >> 3)) &* 0x100_0000_01b3
            }
            return RowSignature(hash: hash, isDistinctive: high - low > 12)
        }
    }
}

public struct RowSignature: Equatable, Sendable {
    public var hash: UInt64
    /// Whether the row has visible detail. Blank rows match anything and say nothing about the offset.
    public var isDistinctive: Bool
}

/// How a new frame relates to the previous one.
public struct ScrollMatch: Equatable, Sendable {
    /// How many rows the content moved up: row `r` of the new frame shows what row `r + offset` of the previous one
    /// showed.
    public var offset: Int
    /// Rows at the top that did not move (a toolbar).
    public var fixedTop: Int
    /// Rows at the bottom that did not move (a sticky footer).
    public var fixedBottom: Int
}

public enum ScrollOverlapMatcher {
    /// Identical frames: nothing scrolled.
    public static func isUnchanged(_ previous: [RowSignature], _ next: [RowSignature]) -> Bool {
        previous.count == next.count && zip(previous, next).allSatisfy { $0.hash == $1.hash }
    }

    /// Finds how far the content moved between two frames of the same size, or `nil` when no offset fits (the
    /// content jumped further than one frame, or changed). `expectedOffset` breaks ties for repeating content.
    public static func match(previous: [RowSignature], next: [RowSignature], expectedOffset: Int? = nil) -> ScrollMatch? {
        let height = previous.count
        guard height == next.count, height >= 8 else { return nil }
        if isUnchanged(previous, next) { return ScrollMatch(offset: 0, fixedTop: 0, fixedBottom: 0) }

        // A band that stays the same at the top or bottom is a fixed bar, at most a third of the frame each.
        let cap = height / 3
        var fixedTop = 0
        while fixedTop < cap, previous[fixedTop].hash == next[fixedTop].hash { fixedTop += 1 }
        var fixedBottom = 0
        while fixedBottom < cap, previous[height - 1 - fixedBottom].hash == next[height - 1 - fixedBottom].hash { fixedBottom += 1 }

        let bandEnd = height - fixedBottom
        let bandHeight = bandEnd - fixedTop
        let minimumOverlap = max(4, bandHeight / 10)
        guard bandHeight > minimumOverlap else { return nil }

        var best: (offset: Int, score: Double, compared: Int)?
        for offset in 1...(bandHeight - minimumOverlap) {
            var compared = 0
            var matched = 0
            var row = fixedTop
            while row + offset < bandEnd {
                let old = previous[row + offset]
                if old.isDistinctive || next[row].isDistinctive {
                    compared += 1
                    if old.hash == next[row].hash { matched += 1 }
                }
                row += 1
            }
            guard compared >= 3 else { continue }
            let score = Double(matched) / Double(compared)
            guard score >= 0.97 else { continue }
            if let current = best {
                let better: Bool
                if abs(score - current.score) > 0.0001 {
                    better = score > current.score
                } else if let expectedOffset {
                    better = abs(offset - expectedOffset) < abs(current.offset - expectedOffset)
                } else {
                    better = false  // keep the smaller offset: the larger overlap
                }
                if better { best = (offset, score, compared) }
            } else {
                best = (offset, score, compared)
            }
        }
        guard let best else { return nil }
        return ScrollMatch(offset: best.offset, fixedTop: fixedTop, fixedBottom: fixedBottom)
    }
}

/// Adds frames one by one and builds the tall picture.
public struct ScrollStitcher {
    public enum AddResult: Equatable, Sendable {
        case first
        /// New rows were added (the count, in frame pixels).
        case appended(Int)
        /// The frame shows exactly what the previous one showed.
        case unchanged
        /// The frame could not be placed: it moved too far or changed. It is skipped.
        case noMatch
        /// The picture reached `maxHeight`; nothing more is added.
        case reachedLimit
    }

    /// The tallest picture, in pixels.
    public let maxHeight: Int
    public private(set) var frameWidth = 0
    public private(set) var frameHeight = 0
    /// Height of the picture so far, the last frame's fixed footer included.
    public var height: Int { contentEnd + lastFooterHeight }
    public private(set) var frameCount = 0

    /// Slices of frames, top to bottom.
    private var slices: [CGImage] = []
    private var lastFrame: CGImage?
    private var lastSignatures: [RowSignature] = []
    /// Where the last frame's top row sits in the picture.
    private var lastPosition = 0
    /// The picture's rows end here (the last frame's footer is not part of it yet).
    private var contentEnd = 0
    private var lastFooterHeight = 0

    public init(maxHeight: Int = 30_000) {
        self.maxHeight = max(1, maxHeight)
    }

    public mutating func add(_ frame: CGImage, expectedOffset: Int? = nil) -> AddResult {
        guard let luma = LumaImage(frame) else { return .noMatch }
        let signatures = luma.rowSignatures()

        guard let previous = lastFrame else {
            frameWidth = frame.width
            frameHeight = frame.height
            lastFrame = frame
            lastSignatures = signatures
            lastPosition = 0
            contentEnd = frame.height
            lastFooterHeight = 0
            frameCount = 1
            slices = Self.copyRows(of: frame, from: 0, count: frame.height).map { [$0] } ?? [frame]
            return .first
        }
        guard frame.width == previous.width, frame.height == previous.height else { return .noMatch }
        if height >= maxHeight { return .reachedLimit }

        guard let match = ScrollOverlapMatcher.match(previous: lastSignatures, next: signatures, expectedOffset: expectedOffset) else {
            return .noMatch
        }
        if match.offset == 0 { return .unchanged }

        // Rows at the bottom of the previous frame that turn out not to move are a footer: take them off the
        // picture, it is added once, at the very bottom.
        let previousUsableEnd = lastPosition + frameHeight - match.fixedBottom
        if contentEnd > previousUsableEnd {
            contentEnd = previousUsableEnd
            trimSlices(to: contentEnd)
        }

        let position = lastPosition + match.offset
        let usableEnd = frameHeight - match.fixedBottom          // rows of the new frame above its footer
        var firstNewRow = contentEnd - position                  // rows above this are already in the picture
        firstNewRow = max(firstNewRow, match.fixedTop)
        var added = 0
        if usableEnd > firstNewRow {
            var rows = usableEnd - firstNewRow
            let room = maxHeight - contentEnd - match.fixedBottom
            if rows > room { rows = max(0, room) }
            if rows > 0, let slice = Self.copyRows(of: frame, from: firstNewRow, count: rows) {
                slices.append(slice)
                contentEnd += rows
                added = rows
            }
        }
        lastFrame = frame
        lastSignatures = signatures
        lastPosition = position
        lastFooterHeight = match.fixedBottom
        frameCount += 1
        if added == 0 && height >= maxHeight { return .reachedLimit }
        return .appended(added)
    }

    /// The picture: the first frame, every new stretch, then the last frame's footer.
    public func makeImage() -> CGImage? {
        guard let last = lastFrame, frameWidth > 0 else { return nil }
        var parts = slices
        if lastFooterHeight > 0, let footer = Self.copyRows(of: last, from: frameHeight - lastFooterHeight, count: lastFooterHeight) {
            parts.append(footer)
        }
        let total = parts.reduce(0) { $0 + $1.height }
        guard total > 0, let context = CGContext(
            data: nil, width: frameWidth, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        var top = 0
        for part in parts {
            // CoreGraphics puts y = 0 at the bottom.
            context.draw(part, in: CGRect(x: 0, y: total - top - part.height, width: part.width, height: part.height))
            top += part.height
        }
        return context.makeImage()
    }

    // MARK: - Slices

    /// Cuts the picture back to `height` rows (used when a footer turns out to be fixed).
    private mutating func trimSlices(to height: Int) {
        var remaining = height
        var kept: [CGImage] = []
        for slice in slices {
            if remaining <= 0 { break }
            if slice.height <= remaining {
                kept.append(slice)
                remaining -= slice.height
            } else if let cut = Self.copyRows(of: slice, from: 0, count: remaining) {
                kept.append(cut)
                remaining = 0
            }
        }
        slices = kept
    }

    /// A copy (not a view) of `count` rows starting at `from`, top-down, so the frame itself can be released.
    static func copyRows(of image: CGImage, from: Int, count: Int) -> CGImage? {
        guard count > 0, from >= 0, from + count <= image.height,
              let cropped = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: count)),
              let context = CGContext(
                data: nil, width: image.width, height: count, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: count))
        return context.makeImage()
    }
}
