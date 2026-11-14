import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

// Scrolling capture with synthetic pictures: a tall image is cut into overlapping frames at known offsets, and the
// stitcher must rebuild it exactly. The session runs against a fake screen and a fake scroll wheel.

@Suite("ScrollingCaptureTests")
struct ScrollingCaptureTests {

    // MARK: - Synthetic images

    /// A tall picture whose every row is different (pseudo-random colour blocks).
    static func tallImage(width: Int = 64, height: Int, seed: UInt64 = 7) -> CGImage {
        var state = seed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            var x = 0
            while x < width {
                let (r, g, b) = (next(), next(), next())
                for dx in 0..<min(8, width - x) {
                    let i = (y * width + x + dx) * 4
                    bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = 255
                }
                x += 8
            }
        }
        return image(width: width, height: height, bytes: bytes)
    }

    static func image(width: Int, height: Int, bytes: [UInt8]) -> CGImage {
        let data = CFDataCreate(nil, bytes, bytes.count)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Rows `from..<from+count` of `image`.
    static func rows(_ image: CGImage, _ from: Int, _ count: Int) -> CGImage {
        ScrollStitcher.copyRows(of: image, from: from, count: count)!
    }

    /// Stacks pictures of the same width top to bottom.
    static func stack(_ parts: [CGImage]) -> CGImage {
        let width = parts[0].width
        let total = parts.reduce(0) { $0 + $1.height }
        let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        var top = 0
        for part in parts {
            ctx.draw(part, in: CGRect(x: 0, y: total - top - part.height, width: width, height: part.height))
            top += part.height
        }
        return ctx.makeImage()!
    }

    /// Pixels in one fixed format, for exact comparisons.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    static func signatures(_ image: CGImage) -> [RowSignature] {
        LumaImage(image)!.rowSignatures()
    }

    // MARK: - Matching

    @Test("SCR-01: the matcher finds the exact offset between two frames")
    func matcherOffset() {
        let tall = Self.tallImage(height: 600)
        for offset in [1, 17, 80, 150] {
            let a = Self.rows(tall, 100, 200)
            let b = Self.rows(tall, 100 + offset, 200)
            let match = ScrollOverlapMatcher.match(previous: Self.signatures(a), next: Self.signatures(b))
            #expect(match?.offset == offset, "offset \(offset)")
            #expect(match?.fixedTop == 0 && match?.fixedBottom == 0)
        }
        let same = Self.rows(tall, 0, 200)
        #expect(ScrollOverlapMatcher.match(previous: Self.signatures(same), next: Self.signatures(same))?.offset == 0)
        // Moved further than the frame: no overlap, no match.
        let far = Self.rows(tall, 300, 200)
        #expect(ScrollOverlapMatcher.match(previous: Self.signatures(same), next: Self.signatures(far)) == nil)
    }

    @Test("SCR-02: frames at known offsets rebuild the tall picture pixel for pixel")
    func stitchExact() {
        let tall = Self.tallImage(height: 900)
        let frameHeight = 240
        let offsets = [0, 100, 230, 400, 520, 660]
        var stitcher = ScrollStitcher()
        #expect(stitcher.add(Self.rows(tall, 0, frameHeight)) == .first)
        for (previous, offset) in zip(offsets, offsets.dropFirst()) {
            #expect(stitcher.add(Self.rows(tall, offset, frameHeight)) == .appended(offset - previous))
        }
        let result = stitcher.makeImage()!
        #expect(result.height == 660 + frameHeight)
        #expect(stitcher.height == result.height)
        #expect(stitcher.frameCount == offsets.count)
        #expect(Self.pixels(result) == Self.pixels(Self.rows(tall, 0, 900)))
    }

    @Test("SCR-03: a toolbar and a footer that stay put appear once, at the top and the bottom")
    func stitchFixedBars() {
        let content = Self.tallImage(height: 1000, seed: 3)
        let header = Self.rows(Self.tallImage(height: 40, seed: 11), 0, 40)
        let footer = Self.rows(Self.tallImage(height: 30, seed: 19), 0, 30)
        let contentHeight = 200
        func frame(at offset: Int) -> CGImage {
            Self.stack([header, Self.rows(content, offset, contentHeight), footer])
        }
        var stitcher = ScrollStitcher()
        let offsets = [0, 120, 240, 360]
        for offset in offsets {
            _ = stitcher.add(frame(at: offset))
        }
        let result = stitcher.makeImage()!
        let expected = Self.stack([header, Self.rows(content, 0, 360 + contentHeight), footer])
        #expect(result.height == expected.height)
        #expect(Self.pixels(result) == Self.pixels(expected))
    }

    @Test("SCR-04: an unchanged frame adds nothing; a frame that cannot be placed is skipped")
    func stitchUnchangedAndLost() {
        let tall = Self.tallImage(height: 800)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(Self.rows(tall, 0, 200))
        #expect(stitcher.add(Self.rows(tall, 0, 200)) == .unchanged)
        #expect(stitcher.add(Self.rows(tall, 500, 200)) == .noMatch)
        #expect(stitcher.height == 200)
        // After a lost frame the next one is matched against the last good frame.
        #expect(stitcher.add(Self.rows(tall, 150, 200)) == .appended(150))
        // A frame of another size never fits.
        #expect(stitcher.add(Self.rows(tall, 0, 100)) == .noMatch)
    }

    @Test("SCR-05: repeating content uses the offset the scroll asked for")
    func stitchRepeating() {
        // Rows repeat every 50 pixels, so 30 and 80 both fit perfectly; the scroll asked for about 80.
        let unit = Self.tallImage(height: 50, seed: 5)
        let tall = Self.stack(Array(repeating: unit, count: 12))
        let a = Self.rows(tall, 0, 200)
        let b = Self.rows(tall, 80, 200)
        #expect(ScrollOverlapMatcher.match(previous: Self.signatures(a), next: Self.signatures(b), expectedOffset: 78)?.offset == 80)
        #expect(ScrollOverlapMatcher.match(previous: Self.signatures(a), next: Self.signatures(b), expectedOffset: 25)?.offset == 30)
    }

    @Test("SCR-06: the picture stops growing at the height limit")
    func stitchLimit() {
        let tall = Self.tallImage(height: 1200)
        var stitcher = ScrollStitcher(maxHeight: 500)
        _ = stitcher.add(Self.rows(tall, 0, 200))
        #expect(stitcher.add(Self.rows(tall, 150, 200)) == .appended(150))
        #expect(stitcher.add(Self.rows(tall, 300, 200)) == .appended(150))
        #expect(stitcher.height == 500)
        #expect(stitcher.add(Self.rows(tall, 450, 200)) == .reachedLimit)
        #expect(stitcher.makeImage()?.height == 500)
    }

    @Test("SCR-07: blank areas do not decide the offset")
    func blankRows() {
        let white = Self.image(width: 64, height: 400, bytes: [UInt8](repeating: 255, count: 64 * 400 * 4))
        let a = Self.rows(white, 0, 200)
        let b = Self.rows(white, 100, 200)
        // Identical blank frames read as "nothing moved", never as a made-up offset.
        #expect(ScrollOverlapMatcher.match(previous: Self.signatures(a), next: Self.signatures(b))?.offset == 0)
    }

    // MARK: - Session with a fake screen

    /// A page of `tall` seen through a window of `frameHeight` pixels; the fake wheel moves it.
    final class FakePage: ScrollFrameGrabbing, ScrollEventPosting, @unchecked Sendable {
        let tall: CGImage
        let frameHeight: Int
        let scale: Int
        let canPost: Bool
        private let lock = NSLock()
        private var offset = 0
        private(set) var scrolls: [Int] = []
        private(set) var grabs = 0

        init(tall: CGImage, frameHeight: Int, scale: Int, canPost: Bool = true) {
            self.tall = tall
            self.frameHeight = frameHeight
            self.scale = scale
            self.canPost = canPost
        }

        func grab() async throws -> CGImage {
            let o = lock.withLock { grabs += 1; return offset }
            return ScrollStitcher.copyRows(of: tall, from: o, count: frameHeight)!
        }

        func scrollDown(points: Int, at point: CGPoint) {
            lock.withLock {
                scrolls.append(points)
                offset = min(tall.height - frameHeight, offset + points * scale)
            }
        }

        /// The user scrolls by hand (manual mode).
        func userScrolls(pixels: Int) {
            lock.withLock { offset = min(tall.height - frameHeight, offset + pixels) }
        }

        var scrollCount: Int { lock.withLock { scrolls.count } }
        var grabCount: Int { lock.withLock { grabs } }
    }

    @MainActor
    @Test("SCR-08: automatic mode scrolls to the end of the page and returns the whole page")
    func sessionAutomatic() async {
        let tall = Self.tallImage(height: 1000)
        let page = FakePage(tall: tall, frameHeight: 200, scale: 2)
        let session = ScrollingCaptureSession(
            mode: .automatic, grabber: page, poster: page, scrollPoint: CGPoint(x: 10, y: 10),
            areaHeightPoints: 100, pixelScale: 2, sleep: { _ in }
        )
        let image = await session.run()
        #expect(session.phase == .finished)
        #expect(page.scrolls.allSatisfy { $0 == ScrollingCaptureSession.stepPoints(forAreaHeight: 100) })
        #expect(page.scrollCount >= 7)
        guard let result = image else {
            Issue.record("no picture")
            return
        }
        #expect(result.height == 1000)
        #expect(Self.pixels(result) == Self.pixels(tall))
        #expect(session.capturedHeight == 1000)
    }

    @MainActor
    @Test("SCR-09: manual mode follows the user's scrolling until Done")
    func sessionManual() async {
        let tall = Self.tallImage(height: 700)
        let page = FakePage(tall: tall, frameHeight: 200, scale: 2, canPost: false)
        let box = SessionBox()
        let ticks = Counter()
        let session = ScrollingCaptureSession(
            mode: .manual, grabber: page, poster: page, scrollPoint: .zero,
            areaHeightPoints: 100, pixelScale: 2,
            sleep: { _ in
                let n = ticks.value
                ticks.increment()
                if n < 5 {
                    page.userScrolls(pixels: 100)
                } else {
                    await MainActor.run { box.session?.finish() }
                }
            }
        )
        box.session = session
        let image = await session.run()
        #expect(page.scrollCount == 0, "manual mode never posts scroll events")
        #expect(image?.height == 700)
        if let image {
            #expect(Self.pixels(image) == Self.pixels(tall))
        }
    }

    @MainActor
    @Test("SCR-10: cancel throws the capture away; a too-fast scroll is reported")
    func sessionCancelAndLost() async {
        let tall = Self.tallImage(height: 2000)
        let page = FakePage(tall: tall, frameHeight: 200, scale: 2, canPost: false)
        let box = SessionBox()
        let ticks = Counter()
        let session = ScrollingCaptureSession(
            mode: .manual, grabber: page, poster: page, scrollPoint: .zero,
            areaHeightPoints: 100, pixelScale: 2,
            sleep: { _ in
                let n = ticks.value
                ticks.increment()
                if n == 0 {
                    page.userScrolls(pixels: 600)   // more than a frame at once
                } else {
                    await MainActor.run {
                        #expect(box.session?.lostTrack == true)
                        box.session?.cancel()
                    }
                }
            }
        )
        box.session = session
        let image = await session.run()
        #expect(image == nil)
        #expect(session.phase == .cancelled)
    }
}

@MainActor
final class SessionBox {
    var session: ScrollingCaptureSession?
}
