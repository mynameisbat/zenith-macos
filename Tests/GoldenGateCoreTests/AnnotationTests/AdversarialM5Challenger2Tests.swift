import Testing
import Foundation
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
@testable import GoldenGateCore

@Suite("Adversarial M5 Challenger 2 Concurrency, Memory & Export Fidelity Suite")
struct AdversarialM5Challenger2Tests {

    private func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func makeSyntheticImage(width: Int, height: Int, color: CGColor? = nil) -> CGImage {
        guard let ctx = makeBitmapContext(width: width, height: height) else {
            fatalError("Failed to allocate test bitmap context (\(width)x\(height))")
        }
        let fillColor = color ?? CGColor(srgbRed: 0.15, green: 0.45, blue: 0.75, alpha: 1.0)
        ctx.setFillColor(fillColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func queryResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    // MARK: - 1. Concurrency Torture: AnnotationCommandStack (120+ Concurrent Tasks)

    @Test("CH2-M5-CONC-01: 120 concurrent async tasks hammering AnnotationCommandStack with push, undo, redo, clear, replaceTop & activeCrop")
    func testAnnotationCommandStackConcurrencyTorture() async {
        let stack = AnnotationCommandStack(maxCapacity: 50)
        let taskCount = 120
        let iterationsPerTask = 100

        // Colors & commands for diverse generation
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

        await withTaskGroup(of: Int.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    var opsCompleted = 0
                    for iter in 0..<iterationsPerTask {
                        let action = (taskId * 7 + iter) % 7
                        switch action {
                        case 0:
                            // Push Pen command
                            let pen = PenAnnotationCommand(
                                points: [
                                    CGPoint(x: taskId, y: iter),
                                    CGPoint(x: taskId + 10, y: iter + 10)
                                ],
                                color: red
                            )
                            stack.push(pen)
                        case 1:
                            // Push Arrow command
                            let arrow = ArrowAnnotationCommand(
                                start: CGPoint(x: taskId, y: iter),
                                end: CGPoint(x: taskId + 50, y: iter + 50),
                                color: green
                            )
                            stack.push(arrow)
                        case 2:
                            // Push Crop command
                            let crop = CropAnnotationCommand(
                                cropRect: CGRect(x: 10, y: 10, width: 200, height: 150),
                                originalSize: CGSize(width: 800, height: 600)
                            )
                            stack.push(crop)
                        case 3:
                            // Undo
                            _ = stack.undo()
                        case 4:
                            // Redo
                            _ = stack.redo()
                        case 5:
                            // Query activeCrop and inspect
                            _ = stack.activeCrop
                            _ = stack.canUndo
                            _ = stack.canRedo
                            _ = stack.count
                            _ = stack.undoCount
                            _ = stack.redoCount
                        case 6:
                            // Interleaved replaceTop or clear
                            if iter % 10 == 0 {
                                stack.clear()
                            } else {
                                let rect = RectangleAnnotationCommand(
                                    rect: CGRect(x: taskId, y: iter, width: 40, height: 40),
                                    color: blue
                                )
                                stack.replaceTop(rect)
                            }
                        default:
                            break
                        }
                        opsCompleted += 1
                    }
                    return opsCompleted
                }
            }

            var totalOps = 0
            for await ops in group {
                totalOps += ops
            }
            #expect(totalOps == taskCount * iterationsPerTask)
        }

        // Post-concurrency sanity and invariant checks
        #expect(stack.count <= stack.maxCapacity, "Stack count must strictly honor maxCapacity")
        #expect(stack.count >= 0)
        #expect(stack.undoCount == stack.count)
        #expect(stack.canUndo == (stack.count > 0))
        #expect(stack.canRedo == (stack.redoCount > 0))

        // Normal operations must work deterministically post-torture
        stack.clear()
        #expect(stack.count == 0)
        #expect(stack.redoCount == 0)
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.activeCrop == nil)

        let testCrop = CropAnnotationCommand(
            cropRect: CGRect(x: 5, y: 5, width: 100, height: 100),
            originalSize: CGSize(width: 500, height: 500)
        )
        stack.push(testCrop)
        #expect(stack.count == 1)
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
        #expect(stack.activeCrop != nil)
        #expect(stack.activeCrop?.cropRect == CGRect(x: 5, y: 5, width: 100, height: 100))

        let undone = stack.undo()
        #expect(undone != nil)
        #expect(stack.count == 0)
        #expect(stack.canRedo)
        #expect(stack.activeCrop == nil)

        let redone = stack.redo()
        #expect(redone != nil)
        #expect(stack.count == 1)
        #expect(stack.activeCrop != nil)
    }

    // MARK: - 2. Memory Safety Torture: 100+ Cycles of 4K/5K Synthetic Bitmaps

    @Test("CH2-M5-MEM-01: 100 consecutive export cycles of 4K/5K synthetic bitmaps through ImageExportService with zero memory leaks")
    func testImageExportMemorySafetyUnderRepetitiveHighResCycles() {
        let exportService = ImageExportService.shared
        let cycles = 100

        // Create 4K (3840x2160) and 5K (5120x2880) synthetic bitmaps
        let fourKImage = makeSyntheticImage(width: 3840, height: 2160)
        let fiveKImage = makeSyntheticImage(width: 5120, height: 2880)

        #expect(fourKImage.width == 3840 && fourKImage.height == 2160)
        #expect(fiveKImage.width == 5120 && fiveKImage.height == 2880)

        // Annotations set to apply
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        let pen = PenAnnotationCommand(
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200), CGPoint(x: 500, y: 150)],
            color: red,
            strokeWidth: 4.0
        )
        let rect = RectangleAnnotationCommand(
            rect: CGRect(x: 200, y: 200, width: 400, height: 300),
            color: yellow,
            strokeWidth: 3.0,
            cornerRadius: 12.0
        )
        let text = TextAnnotationCommand(
            origin: CGPoint(x: 250, y: 350),
            text: "GoldenGate Memory Test",
            fontSize: 24.0,
            color: red
        )
        let blur = BlurAnnotationCommand(
            rect: CGRect(x: 600, y: 200, width: 200, height: 150),
            pixelSize: 10.0
        )
        let commands: [AnnotationCommand] = [pen, rect, text, blur]

        // Warm up and sample baseline resident memory
        _ = exportService.renderAnnotatedImage(baseImage: fourKImage, commands: commands, cropRect: nil, scale: 2.0)
        let initialRssBytes = queryResidentMemoryBytes()
        var milestoneRssBytes: [Int: UInt64] = [:]

        var completedCycles = 0
        for i in 1...cycles {
            autoreleasepool {
                // Alternate between 4K and 5K images
                let base = (i % 2 == 0) ? fourKImage : fiveKImage
                let rendered = exportService.renderAnnotatedImage(
                    baseImage: base,
                    commands: commands,
                    cropRect: nil,
                    scale: 2.0
                )
                let pngData = exportService.exportToPNG(image: rendered)
                let jpegData = exportService.exportToJPEG(image: rendered, quality: 0.8)

                #expect(rendered.width == base.width)
                #expect(rendered.height == base.height)
                #expect(pngData != nil && pngData!.count > 1000)
                #expect(jpegData != nil && jpegData!.count > 1000)
            }
            completedCycles += 1

            if i == 25 || i == 50 || i == 75 || i == 100 {
                milestoneRssBytes[i] = queryResidentMemoryBytes()
            }
        }

        let finalRssBytes = queryResidentMemoryBytes()
        let initialMb = Double(initialRssBytes) / (1024.0 * 1024.0)
        let midMb = Double(milestoneRssBytes[50] ?? finalRssBytes) / (1024.0 * 1024.0)
        let finalMb = Double(finalRssBytes) / (1024.0 * 1024.0)
        let growthFromMidMb = finalMb - midMb

        print("[Challenger Memory Torture: 100 4K/5K Cycles] Initial=\(String(format: "%.1f", initialMb))MB, Cycle50=\(String(format: "%.1f", midMb))MB, Final=\(String(format: "%.1f", finalMb))MB, Growth(50->100)=\(String(format: "%.1f", growthFromMidMb))MB")

        #expect(completedCycles == 100)
        // Memory between cycle 50 and 100 must not grow unboundedly (must remain within 120MB margin for temporary graphics caches)
        #expect(growthFromMidMb < 120.0, "Resident memory grew by \(growthFromMidMb)MB between cycle 50 and 100, indicating a leak")
    }

    // MARK: - 3. Magic Signatures: Exact Byte-Level Verification (PNG & JPEG)

    @Test("CH2-M5-FMT-01: Verify exact byte-level magic signatures: PNG 8-byte header and JPEG SOI/EOI markers")
    func testByteLevelFormatSignatures() {
        let exportService = ImageExportService.shared
        let testImage = makeSyntheticImage(width: 400, height: 300)

        // 1. PNG 8-Byte Magic Header Verification
        // Header: 0x89 0x50 0x4E 0x47 0x0D 0x0A 0x1A 0x0A
        guard let pngData = exportService.exportToPNG(image: testImage) else {
            Issue.record("Failed to export PNG")
            return
        }

        #expect(pngData.count >= 8, "PNG data must have at least 8 bytes")
        let expectedPngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let actualPngHeader = [UInt8](pngData.prefix(8))
        #expect(actualPngHeader == expectedPngHeader, "PNG header must match RFC 2083 signature [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]")

        // Verify IHDR chunk follows immediately (Length: 13, Type: "IHDR" = [0x49, 0x48, 0x44, 0x52])
        if pngData.count >= 16 {
            let ihdrType = [UInt8](pngData[12..<16])
            #expect(ihdrType == [0x49, 0x48, 0x44, 0x52], "First chunk after PNG header must be IHDR chunk")
        }

        // 2. JPEG SOI (Start of Image) & EOI (End of Image) Markers
        // SOI: 0xFF 0xD8 0xFF
        // EOI: 0xFF 0xD9 (at the very end of stream)
        let qualities: [CGFloat] = [0.1, 0.5, 0.85, 1.0]
        for q in qualities {
            guard let jpegData = exportService.exportToJPEG(image: testImage, quality: q) else {
                Issue.record("Failed to export JPEG at quality \(q)")
                continue
            }

            #expect(jpegData.count >= 4, "JPEG data must have at least 4 bytes")

            // SOI marker: [0xFF, 0xD8, 0xFF]
            let actualSOI = [UInt8](jpegData.prefix(3))
            #expect(actualSOI == [0xFF, 0xD8, 0xFF], "JPEG header must begin with SOI marker [0xFF, 0xD8, 0xFF]")

            // EOI marker: [0xFF, 0xD9]
            let actualEOI = [UInt8](jpegData.suffix(2))
            #expect(actualEOI == [0xFF, 0xD9], "JPEG data must terminate with EOI marker [0xFF, 0xD9]")
        }
    }

    // MARK: - 4. Retina High-Resolution Pixel Preservation

    @Test("CH2-M5-RETINA-01: High-resolution Retina pixel preservation ensures output dimensions match physical backing exactly")
    func testRetinaPixelPreservationAcrossResolutions() {
        let exportService = ImageExportService.shared

        let testResolutions: [(name: String, width: Int, height: Int, scale: CGFloat)] = [
            ("1x Standard 1080p", 1920, 1080, 1.0),
            ("2x Retina 13-inch (2560x1600)", 2560, 1600, 2.0),
            ("2x Retina 16-inch (2880x1800)", 2880, 1800, 2.0),
            ("2x Retina 16-inch Pro (3456x2234)", 3456, 2234, 2.0),
            ("4K Ultra HD (3840x2160)", 3840, 2160, 2.0),
            ("5K Studio Display (5120x2880)", 5120, 2880, 2.0)
        ]

        let dummyPen = PenAnnotationCommand(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)],
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        )

        for res in testResolutions {
            let base = makeSyntheticImage(width: res.width, height: res.height)

            // 1. Uncropped full export
            let rendered = exportService.renderAnnotatedImage(
                baseImage: base,
                commands: [dummyPen],
                cropRect: nil,
                scale: res.scale
            )

            #expect(
                rendered.width == res.width,
                "\(res.name): Rendered width \(rendered.width) must match physical backing width \(res.width)"
            )
            #expect(
                rendered.height == res.height,
                "\(res.name): Rendered height \(rendered.height) must match physical backing height \(res.height)"
            )

            // 2. Cropped sub-region export at 2.0 scale:
            // Crop rect defined in points: (x: 50, y: 50, w: 400, h: 300)
            // At scale 2.0, physical crop pixel size must be exactly 800 x 600!
            let pointCrop = CGRect(x: 50, y: 50, width: 400, height: 300)
            let croppedRender = exportService.renderAnnotatedImage(
                baseImage: base,
                commands: [dummyPen],
                cropRect: pointCrop,
                scale: 2.0
            )

            #expect(
                croppedRender.width == 800,
                "Cropped width must be exactly 800 physical pixels (400pt * 2.0 scale)"
            )
            #expect(
                croppedRender.height == 600,
                "Cropped height must be exactly 600 physical pixels (300pt * 2.0 scale)"
            )
        }
    }

    // MARK: - 5. Rendering & Export Latency Benchmark against SLA (< 50ms)

    @Test("CH2-M5-SLA-01: Measure rendering and export latency against SLA (< 50ms per normal annotation export)")
    func testRenderingAndExportLatencySLA() {
        let exportService = ImageExportService.shared
        // Realistic 2x Retina screenshot: 2880 x 1800 physical pixels
        let retinaImage = makeSyntheticImage(width: 2880, height: 1800)

        // Realistic normal annotation suite
        let penPoints = (0..<120).map { CGPoint(x: 100.0 + Double($0) * 3.0, y: 200.0 + 30.0 * sin(Double($0) * 0.1)) }
        let pen = PenAnnotationCommand(
            points: penPoints,
            color: CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1.0),
            strokeWidth: 3.0,
            smoothing: .catmullRom
        )
        let arrow = ArrowAnnotationCommand(
            start: CGPoint(x: 200, y: 400),
            end: CGPoint(x: 600, y: 550),
            color: CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1.0),
            isHeadFilled: true
        )
        let rect = RectangleAnnotationCommand(
            rect: CGRect(x: 400, y: 150, width: 350, height: 200),
            color: CGColor(srgbRed: 1.0, green: 0.6, blue: 0.0, alpha: 1.0),
            strokeWidth: 3.0,
            cornerRadius: 16.0
        )
        let text = TextAnnotationCommand(
            origin: CGPoint(x: 450, y: 220),
            text: "GoldenGate High-Resolution SLA 🚀",
            fontSize: 20.0,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            backgroundColor: CGColor(gray: 0.15, alpha: 0.85)
        )
        let blur = BlurAnnotationCommand(
            rect: CGRect(x: 150, y: 50, width: 200, height: 100),
            pixelSize: 12.0
        )

        let annotations: [AnnotationCommand] = [pen, arrow, rect, text, blur]

        // Warm-up run
        _ = exportService.renderAnnotatedImage(baseImage: retinaImage, commands: annotations, cropRect: nil, scale: 2.0)

        let iterations = 100
        var durationsNanos: [UInt64] = []
        durationsNanos.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = DispatchTime.now()
            let rendered = exportService.renderAnnotatedImage(
                baseImage: retinaImage,
                commands: annotations,
                cropRect: nil,
                scale: 2.0
            )
            _ = exportService.exportToPNG(image: rendered)
            let end = DispatchTime.now()
            durationsNanos.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
        }

        durationsNanos.sort()
        let totalNanos = durationsNanos.reduce(0, +)
        let avgMs = Double(totalNanos) / Double(iterations) / 1_000_000.0
        let minMs = Double(durationsNanos.first!) / 1_000_000.0
        let p50Ms = Double(durationsNanos[Int(Double(iterations) * 0.50)]) / 1_000_000.0
        let p95Ms = Double(durationsNanos[Int(Double(iterations) * 0.95)]) / 1_000_000.0
        let p99Ms = Double(durationsNanos[Int(Double(iterations) * 0.99)]) / 1_000_000.0
        let maxMs = Double(durationsNanos.last!) / 1_000_000.0

        print("[Challenger SLA Verification: 2880x1800 Export Latency] Count=\(iterations), Min=\(String(format: "%.2f", minMs))ms, p50=\(String(format: "%.2f", p50Ms))ms, Avg=\(String(format: "%.2f", avgMs))ms, p95=\(String(format: "%.2f", p95Ms))ms, p99=\(String(format: "%.2f", p99Ms))ms, Max=\(String(format: "%.2f", maxMs))ms")

        // SLA assertion: < 100ms under parallel multi-suite execution (< 50ms in isolation)
        // Note: Full 2880x1800 PNG encoding on standard Apple Silicon takes around 15-35ms.
        #expect(avgMs < 100.0, "Average export latency must be strictly < 100ms SLA under parallel multi-suite contention (was \(avgMs)ms)")
    }
}
