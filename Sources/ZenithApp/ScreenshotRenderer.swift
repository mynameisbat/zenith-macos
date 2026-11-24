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
            duration: 215, position: 84, isPlaying: true, artworkData: Self.sampleCover(), canSeek: true
        )
        save("island-now-playing", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedSize(page: nil, showsDock: island.showsToolsTab).height))

        island.nowPlayingTrack = NowPlayingTrack(
            app: .youtube, title: "Lo-fi beats to study to", artist: "YouTube", duration: 0, position: 0, isPlaying: true
        )
        save("island-browser", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedSize(page: nil, showsDock: island.showsToolsTab).height))

        // The island widgets: a focus timer part-way through and an invented meeting. Load the widget settings first,
        // or they would replace the flags set here with this Mac's when the timer card first reads them.
        _ = IslandWidgetSettings.shared
        // The speed is invented too: never draw this Mac's real traffic.
        NetworkSpeedMonitor.shared.pin(NetworkSpeed(downloadBytesPerSecond: 2_400_000, uploadBytesPerSecond: 180_000))
        island.nowPlayingTrack = NowPlayingTrack(
            app: .appleMusic, title: "Dawn Chorus", artist: "Example Band", album: "Field Notes",
            duration: 215, position: 84, isPlaying: true, artworkData: Self.sampleCover(), canSeek: true
        )
        island.showsTimerWidget = true
        island.showsCalendarWidget = true
        island.showsNetworkWidget = true
        island.focusTimer = FocusTimerSnapshot(mode: .focus, isPaused: false, duration: 1_500, remaining: 1_122)
        island.calendarAccess = .granted
        island.upcomingEvent = UpcomingEvent(
            id: "sample", title: "Design review", start: Date().addingTimeInterval(14 * 60 + 30),
            end: Date().addingTimeInterval(45 * 60), colorComponents: [0.35, 0.55, 1.0]
        )
        island.activeTab = .widgets
        island.isExpanded = true
        save("island-widgets", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedSize(page: nil, showsDock: island.showsToolsTab).height))
        island.isExpanded = false
        save("island-timer", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: 40))
        // The same closed island with the pointer on it, before it opens.
        island.isHoverEmphasized = true
        save("island-timer-hover", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: 40))
        island.isHoverEmphasized = false
        island.focusTimer = nil
        save("recording-picker", RecordingPickerBar(model: RecordingPickerModel()).padding(20).background(Color.gray))
        island.dismissAlert()
        island.focusTimer = nil
        island.upcomingEvent = nil
        island.showsTimerWidget = false
        island.showsCalendarWidget = false
        island.showsNetworkWidget = false

        // The AI tab and the closed island while an agent works: invented sessions, never this Mac's logs.
        let agentNow = Date()
        let sampleClaude = AIAgentSnapshot(
            kind: .claudeCode, isWorking: true, projectName: "example-app", model: "claude-sonnet-5-5",
            workingSince: agentNow.addingTimeInterval(-260), lastActivity: agentNow.addingTimeInterval(-4),
            todayUsage: AIAgentTokenUsage(input: 48_000, output: 312_000, cacheRead: 9_400_000, cacheWrite: 1_100_000),
            sessionUsage: AIAgentTokenUsage(input: 12_000, output: 96_000, cacheRead: 2_800_000, cacheWrite: 340_000),
            sessionsToday: 3
        )
        let sampleCodex = AIAgentSnapshot(
            kind: .codex, projectName: "website", model: "gpt-5-codex", lastActivity: agentNow.addingTimeInterval(-1_500),
            todayUsage: AIAgentTokenUsage(input: 410_000, output: 52_000, cacheRead: 1_900_000),
            sessionUsage: AIAgentTokenUsage(input: 120_000, output: 18_000, cacheRead: 640_000),
            rateLimits: [
                AIAgentRateLimit(windowMinutes: 300, usedPercent: 38, resetsAt: agentNow.addingTimeInterval(7_400)),
                AIAgentRateLimit(windowMinutes: 10_080, usedPercent: 12, resetsAt: agentNow.addingTimeInterval(4 * 86_400))
            ],
            sessionsToday: 1
        )
        island.nowPlayingTrack = nil
        AIAgentMonitor.shared.pin([sampleClaude, sampleCodex], now: agentNow)
        island.activeTab = .aiAgents
        island.isExpanded = true
        save("island-ai-agents", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedSize(page: nil, showsDock: island.showsToolsTab).height))
        AIAgentMonitor.shared.pin([sampleCodex], now: agentNow)
        save("island-ai-agent-single", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: geometry.expandedSize(page: nil, showsDock: island.showsToolsTab).height))
        AIAgentMonitor.shared.pin([sampleClaude, sampleCodex], now: agentNow)
        island.isExpanded = false
        save("island-ai-working", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: 40))

        // The island as it opens: what is going on with the dock of tools under it, with every tab there is (four
        // share the strips beside the notch), then with nothing going on. Then the Tools page.
        island.showsToolsTab = true
        island.showsTimerWidget = true
        island.nowPlayingTrack = NowPlayingTrack(
            app: .appleMusic, title: "Dawn Chorus", artist: "Example Band", album: "Field Notes",
            duration: 215, position: 84, isPlaying: true, artworkData: Self.sampleCover(), canSeek: true
        )
        island.droppedItems = [IslandDropItem(name: "Notes.txt", textContent: "Agenda for Friday")]
        island.activeTab = .nowPlaying
        island.isExpanded = true
        let homeSize = geometry.expandedSize(page: nil, showsDock: true)
        save("island-home", ZenithDynamicIslandView(geometry: geometry).frame(width: homeSize.width, height: homeSize.height))
        // The closed island while that track plays: the cover in a small tile on one side, the equalizer on the other.
        island.isExpanded = false
        save("island-now-playing-closed", ZenithDynamicIslandView(geometry: geometry).frame(width: geometry.expandedWidth, height: 40))
        island.isExpanded = true
        // On a display with a notch (`ZENITH_RENDER_NOTCH=1`, for checking a layout): the notch, in red, must have
        // nothing under it. This Mac's own display decides the default geometry; this one is a 14-inch MacBook Pro's.
        let notchedGeometry = ZenithIslandGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: CGRect(x: 663, y: 950, width: 186, height: 32)
        )
        let showsNotchVariants = ProcessInfo.processInfo.environment["ZENITH_RENDER_NOTCH"] == "1"
        if showsNotchVariants {
            let size = notchedGeometry.expandedSize(page: nil, showsDock: true)
            let plain = ZenithIslandGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: nil)
            save("island-home-plain", ZenithDynamicIslandView(geometry: plain).frame(width: size.width, height: size.height))
            save("island-home-notch", ZStack(alignment: .top) {
                ZenithDynamicIslandView(geometry: notchedGeometry)
                Rectangle().fill(Color.red.opacity(0.4)).frame(width: 186, height: 32)
            }.frame(width: size.width, height: size.height))
        }
        // The same island with the solid-colour dock icons.
        let savedStyle = IslandWidgetSettings.shared.dockIconStyle
        defer { IslandWidgetSettings.shared.dockIconStyle = savedStyle }
        IslandWidgetSettings.shared.dockIconStyle = .color
        save("island-home-color", ZenithDynamicIslandView(geometry: geometry).frame(width: homeSize.width, height: homeSize.height))
        IslandWidgetSettings.shared.dockIconStyle = .tinted
        island.droppedItems = []
        island.nowPlayingTrack = nil
        island.showsTimerWidget = false
        AIAgentMonitor.shared.stop()
        save("island-home-idle", ZenithDynamicIslandView(geometry: geometry).frame(width: homeSize.width, height: homeSize.height))
        // Keep Awake being turned on: the dock asks for how long.
        IslandKeepAwakePrompt.shared.isShowing = true
        save("island-home-keep-awake", ZenithDynamicIslandView(geometry: geometry).frame(width: homeSize.width, height: homeSize.height))
        IslandKeepAwakePrompt.shared.isShowing = false
        // The default dock, whatever arrangement is saved on this Mac; that one is put back when the renderer is done.
        let savedDock = IslandWidgetSettings.shared.dockLayout
        defer { IslandWidgetSettings.shared.dockLayout = savedDock }
        IslandWidgetSettings.shared.dockLayout = IslandDockLayout()
        island.openPage(.tools)
        IslandWidgetSettings.shared.dockIconStyle = .tinted
        let toolsPageSize = geometry.expandedSize(page: .tools, showsDock: true)
        save("island-page-tools", ZenithDynamicIslandView(geometry: geometry).frame(width: toolsPageSize.width, height: toolsPageSize.height))
        if showsNotchVariants {
            let size = notchedGeometry.expandedSize(page: .tools, showsDock: true)
            save("island-page-tools-notch", ZStack(alignment: .top) {
                ZenithDynamicIslandView(geometry: notchedGeometry)
                Rectangle().fill(Color.red.opacity(0.4)).frame(width: 186, height: 32)
            }.frame(width: size.width, height: size.height))
        }
        if showsNotchVariants {
            // No notch: the header has room for the page's name.
            let plain = ZenithIslandGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: nil)
            let size = plain.expandedSize(page: .tools, showsDock: true)
            save("island-page-tools-plain", ZenithDynamicIslandView(geometry: plain).frame(width: size.width, height: size.height))
        }
        IslandDockEditor.shared.isEditing = true
        save("island-page-tools-editing", ZenithDynamicIslandView(geometry: geometry).frame(width: toolsPageSize.width, height: toolsPageSize.height))
        IslandDockEditor.shared.isEditing = false
        island.close()

        // The Command Hub, with an invented process list.
        let hogs = [
            ProcessTelemetry(pid: 4101, name: "Video Editor", cpuPercent: 155.5, memoryBytes: 2_400_000_000),
            ProcessTelemetry(pid: 4102, name: "Design Tool", cpuPercent: 21.0, memoryBytes: 1_300_000_000),
            ProcessTelemetry(pid: 4103, name: "Chat App", cpuPercent: 9.5, memoryBytes: 820_000_000),
            ProcessTelemetry(pid: 4104, name: "Notes", cpuPercent: 3.2, memoryBytes: 310_000_000),
            ProcessTelemetry(pid: 4105, name: "Code Editor", cpuPercent: 2.1, memoryBytes: 1_100_000_000)
        ]
        let sampleSnapshot = HardwareSnapshot(
            disk: DiskTelemetry(totalBytes: 1_000_000_000_000, freeBytes: 389_080_000_000, usedBytes: 610_920_000_000, usedPercent: 61.1),
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
        // The hub's port count must not read this Mac's sockets either.
        let ownProcess = { (path: String) in ProcessIdentity(uid: getuid(), executablePath: path, startTime: 0) }
        PortManagerModel.shared.pin([
            ListeningPort(pid: 4321, processName: "node", uid: nil, user: nil, proto: .tcp, address: "127.0.0.1", port: 3000, identity: ownProcess("/opt/homebrew/bin/node")),
            ListeningPort(pid: 4380, processName: "postgres", uid: nil, user: nil, proto: .tcp, address: "127.0.0.1", port: 5432, identity: ownProcess("/opt/homebrew/bin/postgres")),
            ListeningPort(pid: 4410, processName: "python3", uid: nil, user: nil, proto: .tcp, address: "*", port: 8000, identity: ownProcess("/opt/homebrew/bin/python3")),
            ListeningPort(pid: 612, processName: "ControlCenter", uid: nil, user: nil, proto: .tcp, address: "*", port: 7000, identity: ownProcess("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")),
        ])
        ZenithCommandHubState.shared.hardwareSnapshot = sampleSnapshot
        // The clipboard strip, with invented items of every kind, spread over three days. The apps are system apps
        // every Mac has, only so the cards show real icons; nothing is read from this Mac's clipboard.
        let samples: [(text: String, age: TimeInterval, pinned: Bool, app: String)] = [
            ("https://example.com/docs/getting-started", 120, false, "com.apple.Safari"),
            ("Meeting notes: ship the island fix on Friday, then review the dock layout together.", 360, false, "com.apple.Notes"),
            ("#0F62FE", 720, true, "com.apple.Preview"),
            ("", 1_260, false, "com.apple.Preview"), // the image
            ("swift build -c release\n./scripts/bundle_app.sh", 26 * 3_600, false, "com.apple.Terminal"),
            ("Invoice 2026-114, due 30 November", 27 * 3_600, false, "com.apple.mail"),
            ("brew install --cask example-app", 3 * 86_400, false, "com.apple.Terminal"),
            ("https://example.org/blog/a-long-address/with/several/parts?ref=newsletter", 4 * 86_400, false, "com.apple.Safari")
        ]
        // A plain loop: one long closure with many arguments is more than Swift 6.1's type checker likes.
        var items: [ClipboardItem] = []
        for sample in samples {
            let timestamp = Date().addingTimeInterval(-sample.age)
            if sample.text.isEmpty, let png = sampleImagePNG() {
                items.append(ClipboardItem.image(data: png, width: 1280, height: 720, timestamp: timestamp, sourceBundleID: sample.app))
            } else {
                items.append(ClipboardItem.text(sample.text, timestamp: timestamp, isPinned: sample.pinned, sourceBundleID: sample.app))
            }
        }
        let viewModel = ClipboardHistoryViewModel(items: items)

        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            // The popover's own glass is not there off screen: a flat stand-in in its colour, with its large radius.
            let popoverBackground = scheme == .dark ? Color(white: 0.17) : Color(white: 0.9)
            save("command-hub-\(suffix)",
                 ZenithCommandHubView()
                    .background(popoverBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous)),
                 dark: scheme == .dark)
            // Light selects a text card, dark the image's.
            viewModel.selectedIndex = scheme == .dark ? 3 : 1
            // Glass has nothing to refract off screen: a desktop of soft colour blobs behind a flat stand-in.
            let desktop = ZStack(alignment: .bottom) {
                ClipboardPictureBackdrop(isDark: scheme == .dark)
                ClipboardHistoryView(viewModel: viewModel, drawsGlass: false)
                    .frame(width: ClipboardHistoryView.panelSize.width, height: ClipboardHistoryView.panelSize.height)
                    .padding(.bottom, 32)
            }
            .frame(width: 1280, height: 520)
            save("clipboard-\(suffix)", desktop, dark: scheme == .dark)

            // The snippet menu (⌃⌥S), on the same kind of stand-in, with made-up snippets in a private library.
            let snippetLibrary = SnippetLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("zenith-render-snippets-\(UUID().uuidString)"))
            // (A new library starts with the two example snippets: today's date and an email signature.)
            snippetLibrary.add(Snippet(name: "Meeting link", trigger: ";meet", body: "https://example.com/meet/design-review"))
            snippetLibrary.add(Snippet(name: "Out of office", trigger: "", body: "Thanks for your message. I am away until Monday and will reply then."))
            let snippetModel = SnippetPickerModel(library: snippetLibrary)
            snippetModel.moveSelection(by: 1)
            let snippetDesktop = ZStack {
                ClipboardPictureBackdrop(isDark: scheme == .dark)
                SnippetPickerView(model: snippetModel, drawsGlass: false, onInsert: { _ in }, onDismiss: {})
            }
            .frame(width: 560, height: 440)
            save("snippet-picker-\(suffix)", snippetDesktop, dark: scheme == .dark)
        }

        // The island grown into its System page: the hub's content (same invented numbers). (Settings, Cleaner, Ports
        // and Homebrew are too wide for the island and open in the Settings window.)
        island.openPage(.system)
        let systemPageSize = geometry.expandedSize(page: .system, showsDock: true)
        save("island-page-system", ZenithDynamicIslandView(geometry: geometry).frame(width: systemPageSize.width, height: systemPageSize.height))
        if showsNotchVariants {
            let size = notchedGeometry.expandedSize(page: .system, showsDock: true)
            save("island-page-system-notch", ZStack(alignment: .top) {
                ZenithDynamicIslandView(geometry: notchedGeometry)
                Rectangle().fill(Color.red.opacity(0.4)).frame(width: 186, height: 32)
            }.frame(width: size.width, height: size.height))
        }
        island.close()

        // The Displays page, with made-up displays: a laptop's own, a monitor that takes brightness and volume over DDC,
        // and one that can only be dimmed in software. Never this Mac's displays.
        let displaysService = DisplayBrightnessService(previewDisplays: [
            ControlledDisplay(id: 1, name: "Built-in Retina Display", isBuiltIn: true, backend: .appleNative, brightness: 0.62),
            ControlledDisplay(id: 2, name: "Studio Monitor 27", isBuiltIn: false, backend: .ddc, brightness: 0.7, volume: 0.3),
            ControlledDisplay(id: 3, name: "Projector", isBuiltIn: false, backend: .gamma, brightness: 0.85)
        ])
        IslandDisplaysPage.serviceProvider = { displaysService }
        defer { IslandDisplaysPage.serviceProvider = { .shared } }
        island.openPage(.displays)
        let displaysPageSize = geometry.expandedSize(page: .displays, showsDock: true)
        save("island-page-displays", ZenithDynamicIslandView(geometry: geometry).frame(width: displaysPageSize.width, height: displaysPageSize.height))
        if showsNotchVariants {
            let size = notchedGeometry.expandedSize(page: .displays, showsDock: true)
            save("island-page-displays-notch", ZStack(alignment: .top) {
                ZenithDynamicIslandView(geometry: notchedGeometry)
                Rectangle().fill(Color.red.opacity(0.4)).frame(width: 186, height: 32)
            }.frame(width: size.width, height: size.height))
        }
        island.close()

        // The annotation editor on the made-up picture.
        if let png = sampleImagePNG(),
           let source = CGImageSourceCreateWithData(png as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let editor = AnnotationEditorViewModel(baseImage: image, canvasSize: CGSize(width: 640, height: 360), imageScaleFactor: 2, soundService: nil)
            editor.selectedTool = .arrow
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                save("annotation-\(suffix)",
                     AnnotationEditorView(viewModel: editor)
                        .frame(width: 700, height: 360 + 60 + EditorWindowGeometryCalculator.compactToolbarReserve),
                     dark: scheme == .dark)
            }
            // A wide capture: the toolbar in one row.
            let wideEditor = AnnotationEditorViewModel(baseImage: image, canvasSize: CGSize(width: 900, height: 400), imageScaleFactor: 2, soundService: nil)
            save("annotation-wide",
                 AnnotationEditorView(viewModel: wideEditor)
                    .frame(width: 900, height: 400 + EditorWindowGeometryCalculator.toolbarReserve),
                 dark: false)
        }

        // Outside the app bundle the process has no icon; Settings shows it, so use the one the bundle gets.
        if let icon = NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/AppIcon.icns") {
            NSApp.applicationIconImage = icon
        }

        // Settings panes that only show settings (Cleaner and Privacy Shield read this Mac, so they are left out).
        // Permissions and login item are stand-ins, so the picture does not depend on this Mac either.
        // Clipboard privacy is a setting too, but its list of ignored apps is this Mac's: show the built-in defaults
        // from a throwaway store that is never saved and has no pasteboard monitor behind it.
        // `removePersistentDomain` below empties the store's file but leaves it in ~/Library/Preferences (cfprefsd
        // writes it back after this process), so each run first removes what earlier runs left.
        let renderDefaultsPrefix = "zenith.render-screenshots."
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        where name.hasPrefix(renderDefaultsPrefix) && name.hasSuffix(".plist") {
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
        }
        let renderDefaultsName = renderDefaultsPrefix + UUID().uuidString
        let renderDefaults = UserDefaults(suiteName: renderDefaultsName) ?? .standard
        defer { renderDefaults.removePersistentDomain(forName: renderDefaultsName) }
        let renderClipboardPrivacy = ClipboardPrivacySettings(userDefaults: renderDefaults, monitor: nil)
        ClipboardPrivacySettingsSection.settingsProvider = { renderClipboardPrivacy }
        // AI agents: switched on in the throwaway store, with invented "found" states instead of this Mac's tools.
        let renderAIAgents = AIAgentSettings(userDefaults: renderDefaults)
        renderAIAgents.isEnabled = true
        AIAgentsSettingsSection.settingsProvider = { renderAIAgents }
        AIAgentsSettingsSection.installedProvider = { $0 != .antigravity }
        // Updates: a made-up newer release, a feed and an installer that never touch the network or this Mac, and
        // settings in the throwaway store (so "Check Automatically" shows its default).
        let renderUpdater = ZenithUpdater(
            settings: UpdateSettings(userDefaults: renderDefaults),
            feed: ScreenshotUpdateFeed(),
            installer: ScreenshotUpdateInstaller(),
            autoSchedule: false
        )
        renderUpdater.presentForScreenshot(
            release: ScreenshotUpdateFeed.sampleRelease, refusal: nil, checkedAt: Date().addingTimeInterval(-2 * 60 * 60)
        )
        UpdatesSettingsSection.updaterProvider = { renderUpdater }

        let settingsModel = SettingsViewModel(
            launchAtLoginService: ScreenshotLoginItem(),
            permissionsService: ScreenshotPermissions()
        )
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for tab in [SettingsTab.general, .shortcuts, .island, .ports, .permissions] {
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
        island.close()
        return failures == 0 ? 0 : 1
    }

    /// A made-up 300×300 album cover (an orange-to-pink-to-violet gradient) for the Now Playing card.
    private static func sampleCover() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 300)
        NSGradient(colors: [
            NSColor(red: 1.0, green: 0.70, blue: 0.42, alpha: 1),
            NSColor(red: 1.0, green: 0.24, blue: 0.43, alpha: 1),
            NSColor(red: 0.42, green: 0.17, blue: 1.0, alpha: 1)
        ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?
            .draw(in: bounds, relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
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
    func calendarAccess() -> CalendarAccessState { .granted }
    func microphoneAccess() -> MicrophoneAccess { .notDetermined }
}

private struct ScreenshotLoginItem: LaunchAtLoginServiceProtocol {
    var isEnabled: Bool { true }
    var status: LaunchAtLoginStatus { .enabled }
    func enable() throws {}
    func disable() throws {}
}

/// Never asks GitHub: the renderer only shows `sampleRelease`.
private struct ScreenshotUpdateFeed: UpdateFeed {
    static let sampleRelease = UpdateRelease(
        version: AppVersion("9.9.0")!,
        tag: "v9.9.0",
        assetName: "Zenith-9.9.0.dmg",
        downloadURL: URL(string: "https://github.com/mynameisbat/zenith-macos/releases/download/v9.9.0/Zenith-9.9.0.dmg")!,
        assetSize: 4_000_000,
        sha256: nil
    )

    func latestRelease() async throws -> UpdateRelease? { Self.sampleRelease }
}

/// Installs nothing and reads nothing: the picture always shows the Install button.
private struct ScreenshotUpdateInstaller: UpdateInstalling {
    struct NotAvailable: Error {}

    func install(_ release: UpdateRelease, progress: @escaping @Sendable (UpdateInstallProgress) -> Void) async throws -> URL {
        throw NotAvailable()
    }

    func downloadForManualInstall(_ release: UpdateRelease, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        throw NotAvailable()
    }

    func automaticInstallRefusal() -> UpdateInstallRefusal? { nil }
}


/// The desktop behind the clipboard strip in `--render-screenshots`: three soft colour blobs, so the translucent
/// stand-in has something to show through.
private struct ClipboardPictureBackdrop: View {
    let isDark: Bool

    var body: some View {
        ZStack {
            (isDark ? Color(red: 0.04, green: 0.05, blue: 0.09) : Color(red: 0.93, green: 0.94, blue: 0.97))
            Circle().fill(isDark ? Color(red: 0.17, green: 0.23, blue: 0.56) : Color(red: 0.55, green: 0.65, blue: 1.0))
                .frame(width: 560, height: 480).blur(radius: 110).offset(x: -300, y: -120)
            Circle().fill(isDark ? Color(red: 0.42, green: 0.17, blue: 0.48) : Color(red: 1.0, green: 0.62, blue: 0.80))
                .frame(width: 500, height: 440).blur(radius: 110).offset(x: 330, y: -60).opacity(0.8)
            Circle().fill(isDark ? Color(red: 0.05, green: 0.37, blue: 0.43) : Color(red: 0.50, green: 0.88, blue: 0.85))
                .frame(width: 560, height: 380).blur(radius: 110).offset(x: 0, y: 190).opacity(0.8)
        }
    }
}
