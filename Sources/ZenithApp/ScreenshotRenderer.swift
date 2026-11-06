import SwiftUI
import AppKit
import ImageIO
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

        // The island widgets: a focus timer part-way through and an invented meeting. Load the widget settings first,
        // or they would replace the flags set here with this Mac's when the timer card first reads them.
        _ = IslandWidgetSettings.shared
        island.nowPlayingTrack = NowPlayingTrack(
            app: .appleMusic, title: "Dawn Chorus", artist: "Example Band", album: "Field Notes",
            duration: 215, position: 84, isPlaying: true
        )
        island.showsTimerWidget = true
        island.showsCalendarWidget = true
        island.focusTimer = FocusTimerSnapshot(mode: .focus, isPaused: false, duration: 1_500, remaining: 1_122)
        island.calendarAccess = .granted
        island.upcomingEvent = UpcomingEvent(
            id: "sample", title: "Design review", start: Date().addingTimeInterval(14 * 60 + 30),
            end: Date().addingTimeInterval(45 * 60), colorComponents: [0.35, 0.55, 1.0]
        )
        island.activeTab = .widgets
        island.isExpanded = true
        save("island-widgets", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedHeight))
        island.isExpanded = false
        save("island-timer", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: 40))
        island.focusTimer = nil
        island.upcomingEvent = nil
        island.showsTimerWidget = false
        island.showsCalendarWidget = false

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
        // Made-up PIDs can belong to real apps on this machine: never draw their icons.
        ProcessIconProvider.symbolsOnly = true
        ZenithCommandHubState.shared.hardwareSnapshot = sampleSnapshot
        // The clipboard panel, with invented items of every kind, spread over three days.
        let samples: [(text: String, age: TimeInterval, pinned: Bool)] = [
            ("https://example.com/docs/getting-started", 60, false),
            ("Meeting notes: ship the island fix on Friday.\nAgenda: review the clipboard panel, then the island timer.", 420, false),
            ("#0F62FE", 840, true),
            ("", 1_500, false), // the image
            ("swift build -c release", 26 * 3_600, false),
            ("Invoice 2026-114, due 30 November", 27 * 3_600, false),
            ("brew install --cask example-app", 3 * 86_400, false)
        ]
        // A plain loop: one long closure with many arguments is more than Swift 6.1's type checker likes.
        var items: [ClipboardItem] = []
        for sample in samples {
            let timestamp = Date().addingTimeInterval(-sample.age)
            if sample.text.isEmpty, let png = sampleImagePNG() {
                items.append(ClipboardItem.image(data: png, width: 1280, height: 720, timestamp: timestamp))
            } else {
                items.append(ClipboardItem.text(sample.text, timestamp: timestamp, isPinned: sample.pinned))
            }
        }
        let viewModel = ClipboardHistoryViewModel(items: items)

        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let background = scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
            save("command-hub-\(suffix)",
                 ZenithCommandHubView()
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)),
                 dark: scheme == .dark)
            // Light shows a text item's preview, dark the image's.
            viewModel.selectedIndex = scheme == .dark ? 3 : 1
            save("clipboard-\(suffix)",
                 ClipboardHistoryView(viewModel: viewModel)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)),
                 dark: scheme == .dark)
        }

        // The annotation editor on the made-up picture.
        if let png = sampleImagePNG(),
           let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let editor = AnnotationEditorViewModel(baseImage: image, canvasSize: CGSize(width: 640, height: 360), imageScaleFactor: 2, soundService: nil)
            editor.selectedTool = .arrow
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                save("annotation-\(suffix)",
                     AnnotationEditorView(viewModel: editor)
                        .frame(width: EditorWindowGeometryCalculator.toolbarWidth, height: 360 + 60 + EditorWindowGeometryCalculator.toolbarReserve),
                     dark: scheme == .dark)
            }
        }

        // Outside the app bundle the process has no icon; Settings shows it, so use the one the bundle gets.
        if let icon = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/AppIcon.icns") {
            NSApp.applicationIconImage = icon
        }

        // Settings panes that only show settings (Cleaner and Privacy Shield read this Mac, so they are left out).
        // Permissions and login item are stand-ins, so the picture does not depend on this Mac either.
        let settingsModel = SettingsViewModel(
            launchAtLoginService: ScreenshotLoginItem(),
            permissionsService: ScreenshotPermissions()
        )
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for tab in [SettingsTab.general, .shortcuts, .island, .permissions] {
                settingsModel.selectedTab = tab
                let name = tab == .island ? "island" : tab.rawValue.lowercased()
                save("settings-\(name)-\(suffix)",
                     ZenithPreferencesView(viewModel: settingsModel)
                        .frame(width: SettingsWindowController.defaultWidth, height: SettingsWindowController.defaultHeight)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)),
                     dark: scheme == .dark)
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// A made-up 1280×720 picture (a gradient with a few shapes) for the clipboard's image item.
    private static func sampleImagePNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: 1280, height: 720)
        NSGradient(colors: [NSColor.systemIndigo, NSColor.systemTeal])?.draw(in: bounds, angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 140, y: 200, width: 520, height: 320), xRadius: 28, yRadius: 28).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 760, y: 220, width: 280, height: 280)).fill()
        NSColor.systemIndigo.withAlphaComponent(0.55).setFill()
        for row in 0..<4 {
            NSBezierPath(roundedRect: NSRect(x: 190, y: 430 - row * 60, width: row == 3 ? 240 : 420, height: 22), xRadius: 11, yRadius: 11).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
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

/// Stand-ins so the Settings pictures look the same on every Mac. (Core's mocks exist only in debug builds, and the
/// renderer must also build in release.)
private struct ScreenshotPermissions: PermissionsServiceProtocol {
    func checkScreenRecordingPermission() -> Bool { true }
    func checkAccessibilityPermission() -> Bool { false }
    func requestScreenRecordingPermission() -> Bool { true }
    func requestAccessibilityPermission() -> Bool { false }
    func openScreenRecordingSettings() -> Bool { false }
    func openAccessibilitySettings() -> Bool { false }
}

private struct ScreenshotLoginItem: LaunchAtLoginServiceProtocol {
    var isEnabled: Bool { true }
    var status: LaunchAtLoginStatus { .enabled }
    func enable() throws {}
    func disable() throws {}
}
