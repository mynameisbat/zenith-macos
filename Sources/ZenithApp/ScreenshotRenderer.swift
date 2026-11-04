import SwiftUI
import AppKit
import ZenithCore

/// Draws the app's own views with made-up data into PNG files (`Zenith --render-screenshots DIR`).
/// The website uses these, so they come from the code that ships and never show a real clipboard, track or process.
@MainActor
enum ScreenshotRenderer {
    static func run(outputDirectory: URL) -> Int32 {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("Cannot create \(outputDirectory.path): \(error.localizedDescription)")
            return 1
        }

        var failures = 0
        func save<V: View>(_ name: String, _ view: V, size: CGSize? = nil, dark: Bool = true) {
            if write(view, size: size, dark: dark, to: outputDirectory.appendingPathComponent(name + ".png")) {
                print("wrote \(name).png")
            } else {
                print("FAILED \(name).png")
                failures += 1
            }
        }

        // The island, expanded, for Apple Music and for browser audio.
        let geometry = ZenithIslandGeometry()
        let island = ZenithIslandState.shared
        island.isExpanded = true
        island.activeTab = .nowPlaying

        island.nowPlayingTrack = NowPlayingTrack(
            app: .appleMusic, title: "Dawn Chorus", artist: "Example Band", album: "Field Notes",
            duration: 215, position: 84, isPlaying: true
        )
        save("island-now-playing", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedHeight))

        island.nowPlayingTrack = NowPlayingTrack(
            app: .youtube, title: "Lo-fi beats to study to", artist: "YouTube", duration: 0, position: 0, isPlaying: true
        )
        save("island-browser", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedHeight))

        // The Command Hub, with an invented process list.
        let hogs = [
            ProcessTelemetry(pid: 4101, name: "Video Editor", cpuPercent: 38.5, memoryBytes: 2_400_000_000),
            ProcessTelemetry(pid: 4102, name: "Design Tool", cpuPercent: 21.0, memoryBytes: 1_300_000_000),
            ProcessTelemetry(pid: 4103, name: "Chat App", cpuPercent: 9.5, memoryBytes: 820_000_000),
            ProcessTelemetry(pid: 4104, name: "Notes", cpuPercent: 3.2, memoryBytes: 310_000_000),
            ProcessTelemetry(pid: 4105, name: "Code Editor", cpuPercent: 2.1, memoryBytes: 1_100_000_000)
        ]
        let sampleSnapshot = HardwareSnapshot(
            disk: DiskTelemetry(totalBytes: 500_000_000_000, freeBytes: 212_000_000_000, usedBytes: 288_000_000_000, usedPercent: 57.6),
            cpu: CPUTelemetry(totalUsagePercent: 31, topHogs: hogs),
            memory: MemoryTelemetry(
                totalBytes: 16_000_000_000, usedBytes: 10_400_000_000, freeBytes: 5_600_000_000,
                activeBytes: 5_800_000_000, wiredBytes: 2_100_000_000, compressedBytes: 1_200_000_000, usedPercent: 65
            )
        )
        // The hub refreshes itself when it appears: make that return the invented numbers, not this machine's.
        ZenithCommandHubState.shared.snapshotProvider = { sampleSnapshot }
        ZenithCommandHubState.shared.hardwareSnapshot = sampleSnapshot
        // The clipboard panel, with invented items.
        let samples: [(String, Bool)] = [
            ("https://example.com/docs/getting-started", false),
            ("Meeting notes: ship the island fix on Friday", false),
            ("#0F62FE", true),
            ("swift build -c release", false),
            ("Invoice 2026-114, due 30 November", false),
            ("brew install --cask example-app", false)
        ]
        // A plain loop: one long closure with many arguments is more than Swift 6.1's type checker likes.
        var items: [ClipboardItem] = []
        for (index, sample) in samples.enumerated() {
            let age: TimeInterval = Double(index) * 420
            items.append(ClipboardItem(
                timestamp: Date().addingTimeInterval(-age),
                itemType: .plainText,
                payload: .plainText(sample.0),
                previewText: sample.0,
                byteSize: sample.0.utf8.count,
                isPinned: sample.1
            ))
        }
        let viewModel = ClipboardHistoryViewModel(items: items)

        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let background = scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
            save("command-hub-\(suffix)",
                 ZenithCommandHubView()
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)),
                 dark: scheme == .dark)
            save("clipboard-\(suffix)",
                 ClipboardHistoryView(viewModel: viewModel)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)),
                 dark: scheme == .dark)
        }
        return failures == 0 ? 0 : 1
    }

    /// Draws the view in an off-screen window, so AppKit-backed parts (text fields, scroll views) are drawn for real;
    /// `ImageRenderer` replaces them with a "prohibited" placeholder or leaves them empty.
    private static func write<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        let size = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Lazy lists and text fields fill in on the next run-loop turns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
