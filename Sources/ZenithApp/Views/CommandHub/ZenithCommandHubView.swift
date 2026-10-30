import SwiftUI
import AppKit
import ZenithCore

/// Native macOS Command Hub Menu Bar Popover for Zenith.
/// Follows Apple Human Interface Guidelines: top search field, quick action rows with shortcut badges,
/// recent clipboard history with fuzzy search filtering, and subtle system status indicators at the footer.
public struct ZenithCommandHubView: View {
    @ObservedObject public var hubState: ZenithCommandHubState = .shared
    @ObservedObject public var privacyController: PrivacyShieldController = .shared
    @ObservedObject public var cleaner: SystemCleanerService = .shared
    @ObservedObject public var historyTracker: SystemCleaningHistoryTracker = .shared

    @FocusState private var isSearchFocused: Bool

    public var onAreaCapture: () -> Void
    public var onFullscreenCapture: () -> Void
    public var onOpenClipboard: () -> Void
    public var onOpenPreferences: () -> Void
    public var onQuit: () -> Void
    public var onClose: () -> Void

    public init(
        onAreaCapture: @escaping () -> Void = {},
        onFullscreenCapture: @escaping () -> Void = {},
        onOpenClipboard: @escaping () -> Void = {},
        onOpenPreferences: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.onAreaCapture = onAreaCapture
        self.onFullscreenCapture = onFullscreenCapture
        self.onOpenClipboard = onOpenClipboard
        self.onOpenPreferences = onOpenPreferences
        self.onQuit = onQuit
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 1. TOP SEARCH BAR
            searchBar

            // 2. QUICK ACTIONS LIST (when query is empty or matches actions)
            if !matchingActions.isEmpty {
                quickActionsList
                hairlineDivider
            }

            // 3. TOP HOGS MONITOR (replaces Recent Clips)
            topHogsSection

            hairlineDivider

            // 4. SUBTLE STATUS & CONTROL FOOTER
            footerRow
        }
        .padding(10)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .onExitCommand {
            onClose()
        }
        .onAppear {
            isSearchFocused = true
            hubState.refreshHardwareSnapshot()
        }
        .onChange(of: hubState.presentationID) { _, _ in
            isSearchFocused = true
        }
    }

    // MARK: - 1. Top Search Bar

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search actions, apps to terminate (or /boost)...", text: $hubState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFocused)
                .onSubmit {
                    handleSubmit()
                }

            if !hubState.searchText.isEmpty {
                Button {
                    hubState.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func handleSubmit() {
        let query = hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.lowercased() == "/boost" || query.lowercased() == "boost" {
            hubState.boostSystem()
            ToastHUDController.shared.show(message: "Zenith Boost: Memory Purged & DNS Flushed", icon: "sparkles")
            hubState.searchText = ""
            return
        }

        if query.isEmpty {
            if let firstAction = matchingActions.first {
                executeAction(firstAction)
            }
            return
        }

        // When query is non-empty:
        if let firstAction = matchingActions.first, matchingActions.count < ZenithHubAction.allCases.count {
            executeAction(firstAction)
        } else if let firstHog = hubState.filteredTopHogs.first {
            hubState.killProcess(pid: firstHog.pid)
            ToastHUDController.shared.show(message: "Terminated \(firstHog.name)", icon: "xmark.circle.fill")
        } else if let firstAction = matchingActions.first {
            executeAction(firstAction)
        }
    }

    // MARK: - 2. Quick Actions List

    private var matchingActions: [ZenithHubAction] {
        let query = hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return ZenithHubAction.allCases
        }
        return ZenithHubAction.allCases.filter { $0.matches(query: query) }
    }

    private var quickActionsList: some View {
        VStack(spacing: 2) {
            ForEach(matchingActions, id: \.self) { action in
                quickActionRow(action: action)
            }
        }
    }

    private func quickActionRow(action: ZenithHubAction) -> some View {
        Button {
            executeAction(action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(width: 18, alignment: .center)

                Text(action.title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(.primary)

                Spacer()

                Text(action.shortcut)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hubState.hoveredActionId == action.rawValue ? 0.06 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(
            action == .area ? "2" : "1",
            modifiers: [.command, .shift]
        )
        .onHover { isHovered in
            if isHovered {
                hubState.setHoveredAction(action.rawValue)
            } else {
                hubState.clearHoveredAction(ifCurrent: action.rawValue)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hubState.hoveredActionId == action.rawValue)
    }

    private func executeAction(_ action: ZenithHubAction) {
        onClose()
        switch action {
        case .area:
            onAreaCapture()
        case .screen:
            onFullscreenCapture()
        }
    }

    // MARK: - 3. Top Hogs Monitor Section (Replaces Recent Clips)

    private var topHogsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let hogs = hubState.filteredTopHogs
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(hubState.hardwareSnapshot.cpu.totalUsagePercent > 60 ? .red : .orange)

                    Text(hubState.searchText.isEmpty ? "RUNNING APPS (SAFE TO KILL)" : "MATCHING APPS (\(hogs.count))")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.secondary.opacity(0.75))
                }

                Spacer()

                Text("\(hubState.hardwareSnapshot.cpu.coreCount) Cores • \(Int(round(hubState.hardwareSnapshot.cpu.totalUsagePercent)))% CPU")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 1)

            if hogs.isEmpty {
                HStack {
                    Spacer()
                    Text(hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Zero heavy user applications running" : "No matching applications found")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(hogs.enumerated()), id: \.element.pid) { index, hog in
                        hogRow(index: index, hog: hog)
                    }
                }
            }

            // Defunct / Zombie Processes Banner
            if !hubState.hardwareSnapshot.cpu.zombieProcesses.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    Text("\(hubState.hardwareSnapshot.cpu.zombieProcesses.count) Defunct Zombie(s)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Purge") {
                        _ = try? SystemOptimizerService.shared.execute(taskId: .zombieProcessCleanup)
                        hubState.refreshHardwareSnapshot()
                        ToastHUDController.shared.show(message: "Zombies Purged", icon: "bolt.fill")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.yellow.opacity(0.1))
                )
            }
        }
    }

    private func hogRow(index: Int, hog: ProcessTelemetry) -> some View {
        let isHovered = hubState.hoveredProcessId == hog.pid
        return HStack(spacing: 8) {
            // Process Icon
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                Image(systemName: iconForProcess(hog.name))
                    .font(.system(size: 11))
                    .foregroundColor(hog.cpuPercent > 30 ? .red : .secondary)
            }
            .frame(width: 26, height: 26)

            // Name, PID & Memory
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(hog.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text("(\(hog.pid))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.75))
                }

                Text(HardwareTelemetryService.formatBytes(hog.memoryBytes))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // CPU percentage badge
            Text("\(String(format: "%.1f", hog.cpuPercent))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(hog.cpuPercent > 50 ? .red : (hog.cpuPercent > 20 ? .orange : .primary))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            // Shortcut badge (⌘1..⌘4)
            if index < 4 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.secondary.opacity(0.55))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }

            // Termination Button
            Button {
                hubState.killProcess(pid: hog.pid)
                ToastHUDController.shared.show(message: "Terminated \(hog.name)", icon: "xmark.circle.fill")
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(isHovered ? 1.0 : 0.75))
            }
            .buttonStyle(.plain)
            .help("Terminate \(hog.name) (PID \(hog.pid))")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0.02))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered in
            if hovered {
                hubState.setHoveredProcess(hog.pid)
            } else {
                hubState.clearHoveredProcess(ifCurrent: hog.pid)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func iconForProcess(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("chrome") || lower.contains("safari") || lower.contains("firefox") || lower.contains("browser") {
            return "globe"
        } else if lower.contains("code") || lower.contains("xcode") || lower.contains("rider") || lower.contains("terminal") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("windowserver") || lower.contains("finder") {
            return "macwindow"
        } else {
            return "gearshape.2"
        }
    }

    // MARK: - 4. Subtle Status & Control Footer

    private var footerRow: some View {
        VStack(spacing: 6) {
            // Top telemetry sub-row: CPU, RAM, Battery (with Maximum Capacity), Storage, and Peripherals
            HStack(spacing: 7) {
                // CPU status
                HStack(spacing: 3) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10.5))
                        .foregroundColor(hubState.hardwareSnapshot.cpu.totalUsagePercent > 75 ? .red : (hubState.hardwareSnapshot.cpu.totalUsagePercent > 40 ? .orange : .secondary))
                    Text("\(Int(round(hubState.hardwareSnapshot.cpu.totalUsagePercent)))%")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                .help("CPU Usage: \(String(format: "%.1f", hubState.hardwareSnapshot.cpu.totalUsagePercent))% across \(hubState.hardwareSnapshot.cpu.coreCount) cores")

                // RAM status with pressure indicator
                HStack(spacing: 3) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10.5))
                        .foregroundColor(hubState.hardwareSnapshot.memory.pressureLevel == .critical ? .red : (hubState.hardwareSnapshot.memory.pressureLevel == .warning ? .orange : .secondary))
                    Text("\(Int(round(hubState.hardwareSnapshot.memory.usedPercent)))%")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                .help("Memory: \(HardwareTelemetryService.formatBytes(hubState.hardwareSnapshot.memory.usedBytes)) used of \(HardwareTelemetryService.formatBytes(hubState.hardwareSnapshot.memory.totalBytes)) (\(hubState.hardwareSnapshot.memory.pressureLevel.rawValue.capitalized) pressure)")

                // Battery status with charge level & Maximum Capacity
                if hubState.hardwareSnapshot.battery.hasBattery {
                    HStack(spacing: 3) {
                        Image(systemName: hubState.hardwareSnapshot.battery.isCharging ? "battery.100.bolt" : "battery.75")
                            .font(.system(size: 10.5))
                            .foregroundColor(hubState.hardwareSnapshot.battery.isCharging ? .green : (hubState.hardwareSnapshot.battery.percentage <= 20 ? .red : .secondary))
                        Text("\(hubState.hardwareSnapshot.battery.percentage)%")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)

                        if let maxCap = hubState.hardwareSnapshot.battery.healthPercent {
                            Text("(\(maxCap)% max)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(maxCap < 80 ? .orange : Color.secondary.opacity(0.75))
                        }
                    }
                    .help("Battery: \(hubState.hardwareSnapshot.battery.percentage)%, Maximum Capacity: \(hubState.hardwareSnapshot.battery.healthPercent ?? 100)%, Condition: \(hubState.hardwareSnapshot.battery.condition), Cycles: \(hubState.hardwareSnapshot.battery.cycleCount ?? 0)")
                }

                // Storage status
                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Text("\(hubState.hardwareSnapshot.disk.freeBytes / 1_073_741_824)G free")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                .help("\(hubState.hardwareSnapshot.disk.volumeName): \(hubState.hardwareSnapshot.disk.freeBytes / 1_073_741_824) GB free of \(hubState.hardwareSnapshot.disk.totalBytes / 1_073_741_824) GB")

                // Connected Bluetooth accessories
                ForEach(hubState.hardwareSnapshot.bluetoothDevices) { dev in
                    HStack(spacing: 3) {
                        Image(systemName: dev.icon)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Text("\(dev.batteryPercent)%")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    .help("\(dev.name): \(dev.batteryPercent)%")
                }

                Spacer()
            }

            // Bottom action tools & application control row (Settings & Quit at bottom right)
            HStack(spacing: 5) {
                // DoH Shield Toggle
                Button {
                    privacyController.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(privacyController.isRunning ? Color(red: 0.18, green: 0.8, blue: 0.44) : Color.secondary.opacity(0.4))
                            .frame(width: 5.5, height: 5.5)

                        Text("DoH")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(privacyController.isRunning ? .primary : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hubState.hoveredFooterId == "doh" ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(privacyController.isTransitioning)
                .help(privacyController.isRunning ? "DNS Protection Active (Click to disable)" : "DNS Protection Disabled (Click to enable)")
                .onHover { isHovered in
                    if isHovered {
                        hubState.setHoveredFooter("doh")
                    } else {
                        hubState.clearHoveredFooter(ifCurrent: "doh")
                    }
                }

                // System Cleaner Badge
                Button {
                    Task {
                        // Nothing has been scanned yet: look first, so there is something to confirm.
                        if cleaner.categories.isEmpty && !cleaner.isScanning {
                            await cleaner.scan()
                        }
                        guard cleaner.selectedJunkSize > 0,
                              DestructiveConfirmation.confirm(
                                title: "Delete \(cleaner.formatSelectedSize) permanently?",
                                message: "These cannot be restored:\n\(cleaner.selectionSummary)",
                                destructiveTitle: "Delete Permanently"
                              ) else { return }

                        let freed = await cleaner.cleanSelected()
                        if freed > 0 {
                            ToastHUDController.shared.show(
                                message: "Freed \(SystemCleanerService.formatBytes(freed))",
                                icon: "broom.fill"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "broom.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(cleaner.selectedJunkSize > 0 ? Color.orange : Color.secondary)

                        Text(cleaner.isCleaning ? "Cleaning..." : (cleaner.isScanning ? "Scanning..." : (cleaner.selectedJunkSize > 0 ? cleaner.formattedSelectedJunkSize : "Clean")))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(cleaner.selectedJunkSize > 0 ? .primary : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hubState.hoveredFooterId == "cleaner" ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(cleaner.isCleaning || cleaner.isScanning || cleaner.selectedJunkSize == 0)
                .help(cleaner.selectedJunkSize > 0 ? "Clean \(cleaner.formattedSelectedJunkSize) system junk" : (historyTracker.totalSessions > 0 ? historyTracker.summaryHeadline : "System junk is clean"))
                .onHover { isHovered in
                    if isHovered {
                        hubState.setHoveredFooter("cleaner")
                    } else {
                        hubState.clearHoveredFooter(ifCurrent: "cleaner")
                    }
                }

                // Boost & Optimizer Button (/boost)
                Button {
                    hubState.boostSystem()
                    ToastHUDController.shared.show(message: "Zenith Boost: Memory Purged & DNS Flushed", icon: "sparkles")
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color.cyan)
                        Text("Boost")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hubState.hoveredFooterId == "boost" ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Boost Zenith: Flush DNS, Purge Defunct Zombies & Free Unused RAM (/boost)")
                .onHover { isHovered in
                    if isHovered {
                        hubState.setHoveredFooter("boost")
                    } else {
                        hubState.clearHoveredFooter(ifCurrent: "boost")
                    }
                }

                Spacer(minLength: 4)

                // Settings & Quit Buttons (Moved Down to bottom right)
                HStack(spacing: 3) {
                    Button {
                        onClose()
                        onOpenPreferences()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 10.5))
                            Text("⌘,")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color.secondary.opacity(0.6))
                        }
                        .foregroundColor(hubState.hoveredFooterId == "settings" ? .primary : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(hubState.hoveredFooterId == "settings" ? 0.08 : 0.0))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Settings (⌘,)")
                    .onHover { isHovered in
                        if isHovered {
                            hubState.setHoveredFooter("settings")
                        } else {
                            hubState.clearHoveredFooter(ifCurrent: "settings")
                        }
                    }

                    Button {
                        onQuit()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "power")
                                .font(.system(size: 10.5))
                            Text("⌘Q")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color.secondary.opacity(0.6))
                        }
                        .foregroundColor(hubState.hoveredFooterId == "quit" ? .red : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.red.opacity(hubState.hoveredFooterId == "quit" ? 0.12 : 0.0))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q", modifiers: .command)
                    .help("Quit Zenith (⌘Q)")
                    .onHover { isHovered in
                        if isHovered {
                            hubState.setHoveredFooter("quit")
                        } else {
                            hubState.clearHoveredFooter(ifCurrent: "quit")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    // MARK: - Hairline Divider

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(height: 0.5)
            .padding(.horizontal, 4)
    }
}
