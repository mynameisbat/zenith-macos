import SwiftUI
import AppKit
import ZenithCore

/// The Command Hub: the popover under Zenith's menu bar icon.
///
/// Laid out like a macOS menu bar extra: a search field, four quick actions as Control Center-style tiles, the
/// running apps that use the most CPU (each can be quit, after a confirmation), system meters, a few switches, and
/// "Settings…" / "Quit Zenith" at the bottom the way a menu ends.
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

    public init(
        onAreaCapture: @escaping () -> Void = {},
        onFullscreenCapture: @escaping () -> Void = {},
        onScreenOCR: @escaping () -> Void = {},
        onOpenClipboard: @escaping () -> Void = {},
        onOpenPreferences: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.onAreaCapture = onAreaCapture
        self.onFullscreenCapture = onFullscreenCapture
        self.onScreenOCR = onScreenOCR
        self.onOpenClipboard = onOpenClipboard
        self.onOpenPreferences = onOpenPreferences
        self.onQuit = onQuit
        self.onClose = onClose
    }

    private static let width: CGFloat = 340

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !matchingActions.isEmpty {
                actionGrid
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            sectionDivider

            runningAppsSection
                .padding(.horizontal, 6)
                .padding(.vertical, 8)

            sectionDivider

            VStack(spacing: 12) {
                metersRow
                controlsRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            sectionDivider

            appRow
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .frame(width: Self.width)
        .onExitCommand {
            onClose()
        }
        .onAppear {
            isSearchFocused = true
            hubState.refreshHardwareSnapshot()
        }
        .onValueChange(of: hubState.presentationID) { _ in
            isSearchFocused = true
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 12)
    }

    private var trimmedQuery: String {
        hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField("Search actions and apps", text: $hubState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSearchFocused ? ZenithTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
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
        hubState.boostSystem()
        ToastHUDController.shared.show(message: "Boost: memory purged, DNS cache flushed", icon: "bolt.fill")
    }

    private func handleSubmit() {
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
        return VStack(spacing: 6) {
            ForEach(rowStarts, id: \.self) { start in
                HStack(spacing: 6) {
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
                ZenithIconTile(systemName: action.icon, tint: tint(for: action), size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(shortcutText(for: action))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? ZenithTheme.surfaceActive : ZenithTheme.groupedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isReturnTarget ? ZenithTheme.accent : ZenithTheme.groupedStroke,
                        lineWidth: isReturnTarget ? 1.5 : ZenithTheme.hairline
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        case .ocr:
            onScreenOCR()
        case .clipboard:
            onOpenClipboard()
        case .cleaning:
            CleaningModeCoordinator.shared.start()
        }
    }

    // MARK: - Running Apps

    private var runningAppsSection: some View {
        let hogs = hubState.filteredTopHogs
        let cpu = hubState.hardwareSnapshot.cpu
        return VStack(alignment: .leading, spacing: 4) {
            ZenithSectionHeader(trimmedQuery.isEmpty ? "Running Apps" : "Matching Apps") {
                Text("\(Int(round(cpu.totalUsagePercent)))% CPU · \(cpu.coreCount) cores")
            }
            .padding(.bottom, 2)

            if hogs.isEmpty {
                Text(trimmedQuery.isEmpty ? "No app is using much CPU right now" : "No running app matches \u{201C}\(trimmedQuery)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(hogs.enumerated()), id: \.element.pid) { index, hog in
                        hogRow(index: index, hog: hog)
                    }
                }
            }

            if !cpu.zombieProcesses.isEmpty {
                zombieBanner(count: cpu.zombieProcesses.count)
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
            }
        }
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
    }

    private func cpuColor(_ percent: Double) -> Color {
        if percent > 50 { return ZenithTheme.danger }
        if percent > 20 { return ZenithTheme.warning }
        return .secondary
    }

    private func hogRow(index: Int, hog: ProcessTelemetry) -> some View {
        let isHovered = hubState.hoveredProcessId == hog.pid
        let shortcutHint = index < 4 ? " (⌘\(index + 1))" : ""
        return HStack(spacing: 9) {
            ProcessIconView(process: hog)

            VStack(alignment: .leading, spacing: 0) {
                Text(hog.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(HardwareTelemetryService.formatBytes(hog.memoryBytes))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(String(format: "%.1f%%", hog.cpuPercent))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(cpuColor(hog.cpuPercent))

            Button {
                quit(hog)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? AnyShapeStyle(ZenithTheme.danger) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Quit \(hog.name)\(shortcutHint); asks first")
            .accessibilityLabel("Quit \(hog.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .zenithRowBackground(isHovered: isHovered)
        .help(Text(verbatim: "\(hog.name), PID \(hog.pid)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(hog.name), \(Int(round(hog.cpuPercent))) percent CPU, \(HardwareTelemetryService.formatBytes(hog.memoryBytes))"))
        .onHover { hovered in
            if hovered {
                hubState.setHoveredProcess(hog.pid)
            } else {
                hubState.clearHoveredProcess(ifCurrent: hog.pid)
            }
        }
    }

    // MARK: - Meters

    private var metersRow: some View {
        let snapshot = hubState.hardwareSnapshot
        let cpuPercent = snapshot.cpu.totalUsagePercent
        let memory = snapshot.memory
        let disk = snapshot.disk
        let battery = snapshot.battery
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                HubMeterView(
                    title: "CPU",
                    value: "\(Int(round(cpuPercent)))%",
                    fraction: cpuPercent / 100,
                    tint: cpuPercent > 75 ? ZenithTheme.danger : (cpuPercent > 40 ? ZenithTheme.warning : ZenithTheme.accent)
                )
                .help(String(format: "CPU: %.1f%% across %d cores", cpuPercent, snapshot.cpu.coreCount))

                HubMeterView(
                    title: "Memory",
                    value: "\(Int(round(memory.usedPercent)))%",
                    fraction: memory.usedPercent / 100,
                    tint: memory.pressureLevel == .critical ? ZenithTheme.danger : (memory.pressureLevel == .warning ? ZenithTheme.warning : ZenithTheme.accent)
                )
                .help("Memory: \(HardwareTelemetryService.formatBytes(memory.usedBytes)) used of \(HardwareTelemetryService.formatBytes(memory.totalBytes)), \(memory.pressureLevel.rawValue) pressure")

                HubMeterView(
                    title: "Storage",
                    value: String(localized: "\(HardwareTelemetryService.formatBytes(disk.freeBytes)) free"),
                    fraction: disk.usedPercent / 100,
                    tint: disk.usedPercent > 90 ? ZenithTheme.danger : ZenithTheme.accent
                )
                .help("\(disk.volumeName): \(HardwareTelemetryService.formatBytes(disk.freeBytes)) free of \(HardwareTelemetryService.formatBytes(disk.totalBytes))")

                if battery.hasBattery {
                    HubMeterView(
                        title: battery.isCharging ? "Charging" : "Battery",
                        value: "\(battery.percentage)%",
                        fraction: Double(battery.percentage) / 100,
                        tint: battery.isCharging ? ZenithTheme.success : (battery.percentage <= 20 ? ZenithTheme.danger : ZenithTheme.success)
                    )
                    .help("Battery \(battery.percentage)%, maximum capacity \(battery.healthPercent ?? 100)%, \(battery.cycleCount ?? 0) cycles, condition \(battery.condition)")
                }
            }

            HubNetworkSpeedView()

            if !snapshot.bluetoothDevices.isEmpty {
                HStack(spacing: 10) {
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
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Controls

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
        Task {
            // Nothing has been scanned yet: look first, so there is something to confirm.
            if cleaner.categories.isEmpty && !cleaner.isScanning {
                await cleaner.scan()
            }
            guard cleaner.selectedJunkSize > 0 else {
                ToastHUDController.shared.show(message: "No system junk found", icon: "checkmark.circle.fill")
                return
            }
            guard DestructiveConfirmation.confirm(
                    title: "Delete \(cleaner.formatSelectedSize) permanently?",
                    message: "These cannot be restored:\n\(cleaner.selectionSummary)",
                    destructiveTitle: "Delete Permanently"
                  ) else { return }

            let freed = await cleaner.cleanSelected()
            if freed > 0 {
                ToastHUDController.shared.show(
                    message: "Freed \(SystemCleanerService.formatBytes(freed))",
                    icon: "sparkles"
                )
            }
            if let message = Self.failureMessage(for: cleaner.lastFailedItemNames) {
                ToastHUDController.shared.show(verbatim: message, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// What to tell the user when a clean could not remove everything, or nil when it removed all it was asked to.
    static func failureMessage(for names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1
            ? String(localized: "Could not remove \(first). macOS may be protecting it, or an app is using it.")
            : String(localized: "Could not remove \(names.count) items, such as \(first). macOS may be protecting them, or an app is using them.")
    }

    private var shieldBinding: Binding<Bool> {
        Binding(
            get: { privacyController.isRunning },
            set: { wantsOn in
                if wantsOn != privacyController.isRunning {
                    privacyController.toggle()
                }
            }
        )
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: shieldBinding) {
                HStack(spacing: 6) {
                    ZenithIconTile(systemName: "lock.shield.fill", tint: ZenithTint.privacy, size: 20)
                    Text("Privacy Shield")
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(privacyController.isTransitioning)
            .help(privacyController.isRunning
                    ? "On: sites are looked up over encrypted DNS through a local proxy"
                    : "Off. Turn on to look sites up over encrypted DNS through a local proxy")

            Spacer(minLength: 4)

            Button {
                runCleaner()
            } label: {
                Label(cleanTitle, systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(cleaner.isCleaning || cleaner.isScanning || (!hasNotScannedJunk && cleaner.selectedJunkSize == 0))
            .help(cleanHelp)

            Button {
                runBoost()
            } label: {
                Label("Boost", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Free inactive memory and flush the DNS cache")
        }
    }

    // MARK: - Settings / Quit

    private var appRow: some View {
        HStack(spacing: 0) {
            menuStyleButton(id: "settings", title: "Settings…", shortcut: "⌘,") {
                onClose()
                onOpenPreferences()
            }
            Spacer(minLength: 8)
            menuStyleButton(id: "quit", title: "Quit Zenith", shortcut: "⌘Q") {
                onQuit()
            }
        }
    }

    private func menuStyleButton(id: String, title: LocalizedStringKey, shortcut: String, action: @escaping () -> Void) -> some View {
        let isHovered = hubState.hoveredFooterId == id
        return Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                ZenithShortcutText(shortcut, isOnSelection: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? ZenithTheme.accent : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hovering in
            if hovering {
                hubState.setHoveredFooter(id)
            } else {
                hubState.clearHoveredFooter(ifCurrent: id)
            }
        }
    }
}

// MARK: - Meter

/// A small labelled gauge: title, value, and a thin bar.
struct HubMeterView: View {
    let title: LocalizedStringKey
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title) + Text(verbatim: " \(value)"))
    }
}

// MARK: - Network speed

/// Download and upload speed on one line under the meters. It only shows the number; the popover's controller
/// starts and stops the measuring while the hub is open.
struct HubNetworkSpeedView: View {
    @ObservedObject private var monitor: NetworkSpeedMonitor = .shared

    var body: some View {
        HStack(spacing: 14) {
            item(symbol: "arrow.down", text: monitor.speed.formattedDownload)
            item(symbol: "arrow.up", text: monitor.speed.formattedUpload)
            Spacer(minLength: 0)
        }
        // Measuring starts and stops with the popover (ZenithCommandHubController), not with this view.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network speed"))
        .accessibilityValue(Text("Download \(monitor.speed.formattedDownload), upload \(monitor.speed.formattedUpload)"))
        .help("Network speed: download and upload")
    }

    private func item(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Process Icon

/// The icon of a running process: its app's icon when it has one (helpers use their app's), otherwise a symbol tile.
struct ProcessIconView: View {
    let process: ProcessTelemetry

    var body: some View {
        Group {
            if let icon = ProcessIconProvider.icon(for: process) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZenithIconTile(systemName: ProcessIconProvider.symbol(for: process.name), tint: Color(nsColor: .systemGray), size: 22)
            }
        }
        .frame(width: 24, height: 24)
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
