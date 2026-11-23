import SwiftUI
import AppKit
import ZenithCore

/// The Command Hub: the popover under Zenith's menu bar icon.
///
/// Laid out like Control Center: a search capsule, two big tiles (Privacy Shield, Keep Awake), a module of ring gauges,
/// the running apps that use the most CPU (each can be quit, after a confirmation), and a footer with the listening
/// ports and round Settings / Quit buttons. Each group is a rounded, translucent module (`HubSurface`).
public struct ZenithCommandHubView: View {
    @ObservedObject public var hubState: ZenithCommandHubState = .shared
    @ObservedObject public var privacyController: PrivacyShieldController = .shared
    @ObservedObject public var cleaner: SystemCleanerService = .shared
    @ObservedObject public var historyTracker: SystemCleaningHistoryTracker = .shared
    @ObservedObject private var settings: SettingsStore = .shared

    @FocusState private var isSearchFocused: Bool

    public var onAreaCapture: () -> Void
    public var onFullscreenCapture: () -> Void
    public var onScreenOCR: () -> Void
    public var onOpenClipboard: () -> Void
    public var onOpenPreferences: () -> Void
    public var onQuit: () -> Void
    public var onClose: () -> Void
    /// Drawn as the island's System page: what the machine is doing (running apps and the meters) and nothing else.
    /// Ports, Privacy Shield, Keep Awake, Homebrew, Settings and Quit have their own places on the island (or open
    /// Settings), so they are left out.
    public var inIsland: Bool

    public init(
        onAreaCapture: @escaping () -> Void = {},
        onFullscreenCapture: @escaping () -> Void = {},
        onScreenOCR: @escaping () -> Void = {},
        onOpenClipboard: @escaping () -> Void = {},
        onOpenPreferences: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        inIsland: Bool = false
    ) {
        self.onAreaCapture = onAreaCapture
        self.onFullscreenCapture = onFullscreenCapture
        self.onScreenOCR = onScreenOCR
        self.onOpenClipboard = onOpenClipboard
        self.onOpenPreferences = onOpenPreferences
        self.onQuit = onQuit
        self.onClose = onClose
        self.inIsland = inIsland
    }

    /// The popover's content width. The island's System page is as wide as the island (380 pt) and shows the same column.
    public static let width: CGFloat = 392
    private static let spacing: CGFloat = 10

    public var body: some View {
        // No stack spacing: the ports list and the Homebrew capsule are empty most of the time, and an empty row
        // would still get its gap. Every row below the search field carries its own 10 pt above it instead.
        VStack(spacing: 0) {
            searchBar

            // While the island has a dock the grid is there; a search still brings the matching actions up here.
            if !inIsland && !matchingActions.isEmpty && hubState.showsActionGrid(query: trimmedQuery) {
                actionGrid
                    .padding(.top, Self.spacing)
            }

            if !inIsland {
                HStack(spacing: Self.spacing) {
                    HubPrivacyShieldTile(controller: privacyController)
                    HubKeepAwakeTile()
                }
                .padding(.top, Self.spacing)

                // Clean and Boost are on the island's dock while it has one.
                if !hubState.launchButtonsOnIsland {
                    cleanAndBoostRow
                        .padding(.top, Self.spacing)
                }
            }

            metersModule
                .padding(.top, Self.spacing)

            runningAppsModule
                .padding(.top, Self.spacing)

            if !inIsland {
                HubPortsSection(query: trimmedQuery) {
                    SettingsTab.requestSelection(.ports)
                    onClose()
                    onOpenPreferences()
                }

                HomebrewHubRow {
                    HomebrewSettingsLink.request()
                    onOpenPreferences()
                }

                footer
                    .padding(.top, Self.spacing)
            }
        }
        .padding(14)
        .frame(width: inIsland ? ZenithIslandGeometry.expandedWidth : Self.width)
        .onExitCommand {
            onClose()
        }
        .onAppear {
            isSearchFocused = true
            hubState.refreshLaunchButtonPlacement()
            hubState.refreshHardwareSnapshot()
            if !inIsland { PortManagerModel.shared.refresh() }
        }
        .onChange(of: hubState.presentationID) { _, _ in
            isSearchFocused = true
            hubState.refreshLaunchButtonPlacement()
        }
    }

    private var trimmedQuery: String {
        hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search

    /// A capsule. It carries no shortcut hint: the hub has no shortcut of its own for the field (it is focused when the
    /// hub opens), and a hint for one that does not exist would only mislead.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            // On the island this page lists running apps only, so that is all the field finds.
            TextField(inIsland ? LocalizedStringKey("Search running apps") : LocalizedStringKey("Search actions and apps"),
                      text: $hubState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
                .onSubmit {
                    handleSubmit()
                }
                .help("Type to filter actions and running apps. Return runs the first action; \"boost\" runs Boost.")

            if !hubState.searchText.isEmpty {
                Button {
                    hubState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .hubCapsule()
        .overlay(
            RoundedRectangle(cornerRadius: 1000, style: .circular)
                .strokeBorder(isSearchFocused ? ZenithTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    /// True until system junk has been scanned once (here or in Settings), so the badge can offer "Scan".
    private var hasNotScannedJunk: Bool {
        cleaner.categories.isEmpty && cleaner.statusMessage == nil
    }

    /// Asks before quitting, then says what happened.
    private func quit(_ hog: ProcessTelemetry) {
        let quitIt = hubState.terminate(hog) { title, message, action in
            DestructiveConfirmation.confirm(verbatimTitle: title, message: message, destructiveTitle: action)
        }
        if quitIt {
            ToastHUDController.shared.show(message: "Asked \(hog.name) to quit", icon: "xmark.circle.fill")
        }
    }

    private func runBoost() {
        ZenithToolActions.boost()
    }

    private func handleSubmit() {
        // On the island Return has no action to run: the tools are on the dock and the Tools page.
        guard !inIsland else { return }
        let query = trimmedQuery.lowercased()
        if query == "/boost" || query == "boost" {
            runBoost()
            hubState.searchText = ""
            return
        }
        if let firstAction = matchingActions.first {
            executeAction(firstAction)
        }
    }

    // MARK: - Quick Actions

    private var matchingActions: [ZenithHubAction] {
        let query = trimmedQuery
        if query.isEmpty {
            return ZenithHubAction.allCases
        }
        return ZenithHubAction.allCases.filter { $0.matches(query: query) }
    }

    private var actionGrid: some View {
        let actions = matchingActions
        let rowStarts = Array(stride(from: 0, to: actions.count, by: 2))
        return VStack(spacing: Self.spacing) {
            ForEach(rowStarts, id: \.self) { start in
                HStack(spacing: Self.spacing) {
                    actionTile(actions[start], isReturnTarget: !trimmedQuery.isEmpty && start == 0)
                    if start + 1 < actions.count {
                        actionTile(actions[start + 1], isReturnTarget: false)
                    } else {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
    }

    private func tint(for action: ZenithHubAction) -> Color {
        switch action {
        case .area: return ZenithTint.capture
        case .screen: return ZenithTint.screen
        case .record: return ZenithTint.recording
        case .ocr: return ZenithTint.ocr
        case .clipboard: return ZenithTint.clipboard
        case .cleaning: return ZenithTint.general
        }
    }

    /// The shortcut the action really has (the user may have changed it in Settings), written like a menu.
    private func shortcutText(for action: ZenithHubAction) -> String {
        // Cleaning Mode's shortcut is off unless Settings turns it on.
        if action == .cleaning, !CleaningModeSettings.shared.hotKeyEnabled {
            return String(localized: "No shortcut")
        }
        return settings.effectiveHotkey(for: action.hotKeyId)?.menuStyleKeyEquivalent
            ?? HotKeyDefinition.menuStyle(action.shortcut)
    }

    private func actionTile(_ action: ZenithHubAction, isReturnTarget: Bool) -> some View {
        let isHovered = hubState.hoveredActionId == action.rawValue
        return Button {
            executeAction(action)
        } label: {
            HStack(spacing: 8) {
                ZenithIconTile(systemName: action.icon, tint: tint(for: action), size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        // German and Japanese titles run a little longer than the tile: shrink before truncating.
                        .minimumScaleFactor(0.8)
                    Text(shortcutText(for: action))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isHovered ? ZenithTheme.surfaceHover : Color.clear)
            )
            .hubModule(radius: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(ZenithTheme.accent, lineWidth: isReturnTarget ? 1.5 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(action.detail) (\(shortcutText(for: action)))")
        .accessibilityLabel(action.title)
        .accessibilityHint(action.detail)
        .onHover { hovering in
            if hovering {
                hubState.setHoveredAction(action.rawValue)
            } else {
                hubState.clearHoveredAction(ifCurrent: action.rawValue)
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func executeAction(_ action: ZenithHubAction) {
        onClose()
        switch action {
        case .area:
            onAreaCapture()
        case .screen:
            onFullscreenCapture()
        case .record:
            ScreenRecordingCoordinator.shared.toggle()  // starts choosing, or stops a running recording
        case .ocr:
            onScreenOCR()
        case .clipboard:
            onOpenClipboard()
        case .cleaning:
            CleaningModeCoordinator.shared.start()
        }
    }

    // MARK: - Running Apps

    private var runningAppsModule: some View {
        let hogs = hubState.filteredTopHogs
        let cpu = hubState.hardwareSnapshot.cpu
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(trimmedQuery.isEmpty ? "Running Apps" : "Matching Apps")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(cpu.coreCount == 1 ? "1 core" : "\(cpu.coreCount) cores")
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if hogs.isEmpty {
                Text(trimmedQuery.isEmpty ? "No app is using much CPU right now" : "No running app matches \u{201C}\(trimmedQuery)\u{201D}")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(hogs.enumerated()), id: \.element.pid) { index, hog in
                        HubAppRow(
                            hog: hog,
                            isHovered: hubState.hoveredProcessId == hog.pid,
                            shortcutHint: index < 4 ? " (⌘\(index + 1))" : "",
                            onQuit: { quit(hog) },
                            onHover: { hovered in
                                if hovered {
                                    hubState.setHoveredProcess(hog.pid)
                                } else {
                                    hubState.clearHoveredProcess(ifCurrent: hog.pid)
                                }
                            }
                        )
                    }
                }
            }

            if !cpu.zombieProcesses.isEmpty {
                zombieBanner(count: cpu.zombieProcesses.count)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubModule()
    }

    private func zombieBanner(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text(count == 1 ? "1 defunct process" : "\(count) defunct processes")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clean Up") {
                _ = try? SystemOptimizerService.shared.execute(taskId: .zombieProcessCleanup)
                hubState.refreshHardwareSnapshot()
                ToastHUDController.shared.show(message: "Defunct processes cleaned up", icon: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
    }

    // MARK: - Meters

    private func color(for level: HubGaugeLevel, base: Color) -> Color {
        switch level {
        case .normal: return base
        case .warning: return ZenithTheme.warning
        case .critical: return ZenithTheme.danger
        }
    }

    private var metersModule: some View {
        let snapshot = hubState.hardwareSnapshot
        let cpuPercent = snapshot.cpu.totalUsagePercent
        let memory = snapshot.memory
        let disk = snapshot.disk
        let battery = snapshot.battery
        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                HubRingGauge(
                    title: "CPU",
                    value: "\(Int(round(cpuPercent)))%",
                    fraction: HubStatus.ringFraction(percent: cpuPercent),
                    tint: color(for: HubGaugeLevel.cpu(percent: cpuPercent), base: ZenithTheme.accent)
                )
                .help("CPU: \(LocalizedNumber.percent(cpuPercent)) across \(snapshot.cpu.coreCount) cores")

                HubRingGauge(
                    title: "Memory",
                    value: "\(Int(round(memory.usedPercent)))%",
                    fraction: HubStatus.ringFraction(percent: memory.usedPercent),
                    tint: color(for: HubGaugeLevel.memory(pressure: memory.pressureLevel), base: Color(nsColor: .systemOrange))
                )
                .help("Memory: \(HardwareTelemetryService.formatBytes(memory.usedBytes)) used of \(HardwareTelemetryService.formatBytes(memory.totalBytes)), \(memory.pressureLevel.rawValue) pressure")

                HubRingGauge(
                    // "Free Space" as the title, so the value is just the size.
                    title: "Free Space",
                    value: HubStatus.compactSize(bytes: disk.freeBytes),
                    accessibilityValue: HardwareTelemetryService.formatBytes(disk.freeBytes),
                    fraction: HubStatus.ringFraction(percent: disk.usedPercent),
                    tint: color(for: HubGaugeLevel.disk(usedPercent: disk.usedPercent), base: Color(nsColor: .systemTeal)),
                    valueSize: 12
                )
                .help("\(disk.volumeName): \(HardwareTelemetryService.formatBytes(disk.freeBytes)) free of \(HardwareTelemetryService.formatBytes(disk.totalBytes))")

                if battery.hasBattery {
                    HubRingGauge(
                        title: battery.isCharging ? "Charging" : "Battery",
                        value: "\(battery.percentage)%",
                        fraction: HubStatus.ringFraction(percent: Double(battery.percentage)),
                        tint: battery.isCharging || battery.percentage > 20 ? ZenithTheme.success : ZenithTheme.danger
                    )
                    .help("Battery \(battery.percentage)%, maximum capacity \(battery.healthPercent ?? 100)%, \(battery.cycleCount ?? 0) cycles, condition \(battery.condition)")
                }
            }

            HubNetworkSpeedView()

            if !snapshot.bluetoothDevices.isEmpty {
                HStack(spacing: 12) {
                    ForEach(snapshot.bluetoothDevices) { device in
                        HStack(spacing: 4) {
                            Image(systemName: device.icon)
                                .font(.system(size: 11))
                            Text("\(device.batteryPercent)%")
                                .font(.system(size: 11))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .help("\(device.name): \(device.batteryPercent)%")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(device.name), battery \(device.batteryPercent) percent")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .hubModule()
    }

    // MARK: - Clean and Boost

    private var cleanTitle: String {
        if cleaner.isCleaning { return String(localized: "Cleaning…") }
        if cleaner.isScanning { return String(localized: "Scanning…") }
        if cleaner.selectedJunkSize > 0 { return String(localized: "Clean \(cleaner.formattedSelectedJunkSize)") }
        return hasNotScannedJunk ? String(localized: "Scan") : String(localized: "Clean")
    }

    private var cleanHelp: String {
        if hasNotScannedJunk && cleaner.selectedJunkSize == 0 {
            return String(localized: "Scan for system junk; you confirm what to delete before anything goes")
        }
        if cleaner.selectedJunkSize > 0 {
            return String(localized: "Clean \(cleaner.formattedSelectedJunkSize) of system junk (asks first)")
        }
        return historyTracker.totalSessions > 0 ? historyTracker.summaryHeadline : String(localized: "No system junk found")
    }

    private func runCleaner() {
        ZenithToolActions.clean()
    }

    /// What to tell the user when a clean could not remove everything, or nil when it removed all it was asked to.
    static func failureMessage(for names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1
            ? String(localized: "Could not remove \(first). macOS may be protecting it, or an app is using it.")
            : String(localized: "Could not remove \(names.count) items, such as \(first). macOS may be protecting them, or an app is using them.")
    }

    /// Clean and Boost as two capsules under the tiles; they are on the island's dock while it has one.
    private var cleanAndBoostRow: some View {
        HStack(spacing: Self.spacing) {
            capsuleButton(
                title: Text(verbatim: cleanTitle),
                symbol: "sparkles",
                help: Text(verbatim: cleanHelp),
                isDisabled: cleaner.isCleaning || cleaner.isScanning || (!hasNotScannedJunk && cleaner.selectedJunkSize == 0)
            ) { runCleaner() }

            capsuleButton(
                title: Text("Boost"),
                symbol: "bolt.fill",
                help: Text("Free inactive memory and flush the DNS cache"),
                isDisabled: false
            ) { runBoost() }
        }
    }

    private func capsuleButton(title: Text, symbol: String, help: Text, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                title
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .hubCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    // MARK: - Footer

    /// Listening Ports as a capsule, then Settings and Quit as round buttons.
    private var footer: some View {
        HStack(spacing: 8) {
            HubPortsButton {
                SettingsTab.requestSelection(.ports)
                onClose()
                onOpenPreferences()
            }

            HubCircleButton(
                symbol: "gearshape",
                label: "Settings",
                help: "Settings (⌘,)",
                isHovered: hubState.hoveredFooterId == "settings",
                action: {
                    onClose()
                    onOpenPreferences()
                },
                onHover: { hovering in setFooterHover("settings", hovering) }
            )

            HubCircleButton(
                symbol: "power",
                label: "Quit Zenith",
                help: "Quit Zenith (⌘Q)",
                isHovered: hubState.hoveredFooterId == "quit",
                action: onQuit,
                onHover: { hovering in setFooterHover("quit", hovering) }
            )
        }
    }

    private func setFooterHover(_ id: String, _ hovering: Bool) {
        if hovering {
            hubState.setHoveredFooter(id)
        } else {
            hubState.clearHoveredFooter(ifCurrent: id)
        }
    }
}

// MARK: - Network speed

/// Download and upload speed on one line under the meters. It only shows the number; the popover's controller
/// starts and stops the measuring while the hub is open.
struct HubNetworkSpeedView: View {
    @ObservedObject private var monitor: NetworkSpeedMonitor = .shared

    var body: some View {
        HStack(spacing: 22) {
            item(symbol: "arrow.down", text: monitor.speed.formattedDownload)
            item(symbol: "arrow.up", text: monitor.speed.formattedUpload)
        }
        .frame(maxWidth: .infinity)
        // Measuring starts and stops with the popover (ZenithCommandHubController), not with this view.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network speed"))
        .accessibilityValue(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
        .help("Network speed: download and upload")
    }

    private func item(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(verbatim: text)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Process Icon

/// The icon of a running process: its app's icon when it has one (helpers use their app's), otherwise a symbol tile.
struct ProcessIconView: View {
    let process: ProcessTelemetry
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let icon = ProcessIconProvider.icon(for: process) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZenithIconTile(systemName: ProcessIconProvider.symbol(for: process.name), tint: Color(nsColor: .systemGray), size: size * 0.92)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Looks up app icons for running processes, with a small cache so the 2.5 s refresh does not hit Launch Services.
@MainActor
enum ProcessIconProvider {
    /// The screenshot renderer sets this so its made-up processes never show the icon of a real app that happens to
    /// have the same PID on the machine drawing them.
    static var symbolsOnly = false

    private static var cache: [String: NSImage] = [:]

    static func icon(for process: ProcessTelemetry) -> NSImage? {
        guard !symbolsOnly else { return nil }
        let key = "\(process.pid):\(process.name)"
        if let cached = cache[key] { return cached }

        var icon: NSImage?
        if let app = NSRunningApplication(processIdentifier: pid_t(process.pid)), app.bundleURL != nil {
            icon = app.icon
        } else if let bundle = process.appBundlePath, FileManager.default.fileExists(atPath: bundle) {
            icon = NSWorkspace.shared.icon(forFile: bundle)
        }
        guard let icon else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = icon
        return icon
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("chrome") || lower.contains("safari") || lower.contains("firefox") || lower.contains("browser") {
            return "globe"
        }
        if lower.contains("code") || lower.contains("xcode") || lower.contains("rider") || lower.contains("terminal") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if lower.contains("video") || lower.contains("movie") {
            return "film"
        }
        if lower.contains("design") || lower.contains("photo") {
            return "paintbrush"
        }
        if lower.contains("chat") || lower.contains("message") {
            return "bubble.left.and.bubble.right"
        }
        if lower.contains("note") {
            return "note.text"
        }
        return "gearshape.2"
    }
}
