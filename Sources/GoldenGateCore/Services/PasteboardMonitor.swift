import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Concrete implementation of PasteboardServiceProtocol monitoring NSPasteboard.
public final class PasteboardMonitor: PasteboardServiceProtocol, @unchecked Sendable {
    public static let shared = PasteboardMonitor()

    private let queue = DispatchQueue(label: "com.goldengate.pasteboard.monitor", qos: .utility)
    private let lock = NSLock()

    private let pasteboard: NSPasteboard
    public let pollingInterval: TimeInterval

    private var timer: DispatchSourceTimer?
    private var isMonitoringInternal: Bool = false
    private var onChangeHandler: (@Sendable (ClipboardItem) -> Void)?

    private var lastObservedChangeCount: Int = 0
    private var lastSuppressedChangeCount: Int = -1

    public init(pasteboard: NSPasteboard = .general, pollingInterval: TimeInterval = 0.3) {
        self.pasteboard = pasteboard
        self.pollingInterval = pollingInterval
        self.lastObservedChangeCount = pasteboard.changeCount
    }

    public var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isMonitoringInternal
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func startMonitoring(onChange: @escaping @Sendable (ClipboardItem) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        self.onChangeHandler = onChange
        guard !isMonitoringInternal else { return }
        isMonitoringInternal = true
        lastObservedChangeCount = pasteboard.changeCount

        // Main thread polling per AppKit NSPasteboard thread-safety rules (MED-05)
        let timerSource = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timerSource.schedule(
            deadline: .now() + pollingInterval,
            repeating: pollingInterval,
            leeway: .milliseconds(50)
        )
        timerSource.setEventHandler { [weak self] in
            self?.pollPasteboard()
        }
        self.timer = timerSource
        timerSource.resume()
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard isMonitoringInternal else { return }
        isMonitoringInternal = false
        onChangeHandler = nil
        timer?.cancel()
        timer = nil
    }

    public func copyItemToPasteboard(_ item: ClipboardItem) {
        lock.lock()
        defer { lock.unlock() }

        autoreleasepool {
            pasteboard.clearContents()
            switch item.payload {
            case .plainText(let text):
                pasteboard.setString(text, forType: .string)
            case .richText(let rtfData, let plainText):
                pasteboard.setData(rtfData, forType: .rtf)
                if !plainText.isEmpty {
                    pasteboard.setString(plainText, forType: .string)
                }
            case .image(let data, _, _):
                pasteboard.setData(data, forType: .png)
            }

            let newCount = pasteboard.changeCount
            lastSuppressedChangeCount = newCount
            lastObservedChangeCount = newCount
        }
    }

    public func writeImageToPasteboard(_ image: CGImage) {
        lock.lock()
        defer { lock.unlock() }

        autoreleasepool {
            pasteboard.clearContents()
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                pasteboard.setData(pngData, forType: .png)
            }

            let newCount = pasteboard.changeCount
            lastSuppressedChangeCount = newCount
            lastObservedChangeCount = newCount
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        autoreleasepool {
            pasteboard.clearContents()
            let newCount = pasteboard.changeCount
            lastSuppressedChangeCount = newCount
            lastObservedChangeCount = newCount
        }
    }

    // MARK: - Polling & Ingestion (MED-05 & HIGH-18)

    private func pollPasteboard() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.pollPasteboard()
            }
            return
        }

        autoreleasepool {
            // Step 1: Check changeCount on Main Thread (< 1 µs)
            let currentCount = pasteboard.changeCount

            lock.lock()
            guard isMonitoringInternal else {
                lock.unlock()
                return
            }

            if currentCount == lastObservedChangeCount || currentCount == lastSuppressedChangeCount {
                lock.unlock()
                return
            }

            lastObservedChangeCount = currentCount
            let handler = onChangeHandler
            lock.unlock()

            // Step 2: Read raw data snapshot on Main Thread within autoreleasepool
            guard let types = pasteboard.types, !types.isEmpty else { return }

            if SensitivePasteboardMarker.containsSensitiveType(in: types) {
                return
            }
            if let pbItems = pasteboard.pasteboardItems {
                for pbItem in pbItems {
                    if SensitivePasteboardMarker.containsSensitiveType(in: pbItem.types) {
                        return
                    }
                }
            }

            let pngData = types.contains(.png) ? pasteboard.data(forType: .png) : nil
            let tiffData = (pngData == nil && types.contains(.tiff)) ? pasteboard.data(forType: .tiff) : nil
            let rtfData = types.contains(.rtf) ? pasteboard.data(forType: .rtf) : nil
            let plainText = (types.contains(.string) || rtfData != nil) ? pasteboard.string(forType: .string) : nil

            // Step 3: Offload heavy text/image parsing and thumbnail creation to background queue
            queue.async { [weak self] in
                guard let self = self else { return }
                autoreleasepool {
                    if let item = self.processRawPasteboardSnapshot(
                        types: types,
                        pngData: pngData,
                        tiffData: tiffData,
                        rtfData: rtfData,
                        plainText: plainText
                    ) {
                        handler?(item)
                    }
                }
            }
        }
    }

    private func processRawPasteboardSnapshot(
        types: [NSPasteboard.PasteboardType],
        pngData: Data?,
        tiffData: Data?,
        rtfData: Data?,
        plainText: String?
    ) -> ClipboardItem? {
        // 1. PNG Image
        if let pngData = pngData, !pngData.isEmpty {
            let (w, h) = extractDimensions(from: pngData)
            return ClipboardItem.image(data: pngData, width: w, height: h)
        }

        // 2. TIFF Image
        if let tiffData = tiffData, !tiffData.isEmpty {
            if let rep = NSBitmapImageRep(data: tiffData),
               let converted = rep.representation(using: .png, properties: [:]) {
                let w = rep.pixelsWide > 0 ? rep.pixelsWide : Int(rep.size.width)
                let h = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(rep.size.height)
                return ClipboardItem.image(data: converted, width: w, height: h)
            } else {
                let (w, h) = extractDimensions(from: tiffData)
                return ClipboardItem.image(data: tiffData, width: w, height: h)
            }
        }

        // 3. Rich Text (RTF)
        if let rtfData = rtfData, !rtfData.isEmpty {
            return ClipboardItem.richText(rtfData: rtfData, plainText: plainText ?? "")
        }

        // 4. Plain Text
        if let text = plainText, !text.isEmpty {
            return ClipboardItem.text(text)
        }

        return nil
    }

    public func extractClipboardItem(from pb: NSPasteboard) -> ClipboardItem? {
        autoreleasepool {
            guard let types = pb.types, !types.isEmpty else { return nil }

            // 1. Sensitive filtering
            if SensitivePasteboardMarker.containsSensitiveType(in: types) {
                return nil
            }
            if let pbItems = pb.pasteboardItems {
                for pbItem in pbItems {
                    if SensitivePasteboardMarker.containsSensitiveType(in: pbItem.types) {
                        return nil
                    }
                }
            }

            let pngData = types.contains(.png) ? pb.data(forType: .png) : nil
            let tiffData = (pngData == nil && types.contains(.tiff)) ? pb.data(forType: .tiff) : nil
            let rtfData = types.contains(.rtf) ? pb.data(forType: .rtf) : nil
            let plainText = (types.contains(.string) || rtfData != nil) ? pb.string(forType: .string) : nil

            return processRawPasteboardSnapshot(
                types: types,
                pngData: pngData,
                tiffData: tiffData,
                rtfData: rtfData,
                plainText: plainText
            )
        }
    }

    private func extractDimensions(from data: Data) -> (Int, Int) {
        autoreleasepool {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                if w > 0 && h > 0 { return (w, h) }
            }
            if let img = NSImage(data: data) {
                return (Int(img.size.width), Int(img.size.height))
            }
            return (0, 0)
        }
    }
}
