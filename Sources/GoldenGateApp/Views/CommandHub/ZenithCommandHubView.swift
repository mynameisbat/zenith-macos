import SwiftUI
import AppKit
import GoldenGateCore

/// Native macOS Command Hub Menu Bar Popover for Zenith.
/// Follows Apple Human Interface Guidelines: top search field, quick action rows with shortcut badges,
/// recent clipboard history with fuzzy search filtering, and subtle system status indicators at the footer.
public struct ZenithCommandHubView: View {
    @ObservedObject public var hubState: ZenithCommandHubState = .shared
    @ObservedObject public var clipboardStore: ClipboardStore = .shared
    @ObservedObject public var privacyController: PrivacyShieldController = .shared
    @ObservedObject public var cleaner: SystemCleanerService = .shared

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

            hairlineDivider

            // 2. QUICK ACTIONS LIST (when query is empty or matches actions)
            if !matchingActions.isEmpty {
                quickActionsList
                hairlineDivider
            }

            // 3. RECENT CLIPS / SEARCH RESULTS SECTION
            recentClipsSection

            hairlineDivider

            // 4. SUBTLE STATUS & CONTROL FOOTER
            footerRow
        }
        .padding(10)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .popover(item: $hubState.quickLookItem, arrowEdge: .trailing) { item in
            QuickLookPreviewCard(
                item: item,
                onCopy: {
                    clipboardStore.selectAndRestoreItem(item)
                    ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
                    hubState.quickLookItem = nil
                    onClose()
                },
                onClose: {
                    hubState.quickLookItem = nil
                }
            )
        }
        .onExitCommand {
            if hubState.quickLookItem != nil {
                hubState.quickLookItem = nil
            } else {
                onClose()
            }
        }
        .onAppear {
            isSearchFocused = true
            hubState.refreshHardwareSnapshot()
            if cleaner.categories.isEmpty && !cleaner.isScanning {
                Task {
                    await cleaner.scan()
                }
            }
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

            TextField("Search clips or actions...", text: $hubState.searchText)
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
        if query.isEmpty {
            if let firstClip = filteredClips.first {
                clipboardStore.selectAndRestoreItem(firstClip)
                ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
                onClose()
            } else if let firstAction = matchingActions.first {
                executeAction(firstAction)
            }
            return
        }

        // When query is non-empty:
        if let firstAction = matchingActions.first, matchingActions.count < ZenithHubAction.allCases.count {
            executeAction(firstAction)
        } else if let firstClip = filteredClips.first {
            clipboardStore.selectAndRestoreItem(firstClip)
            ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
            onClose()
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
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
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

    // MARK: - 3. Recent Clips / Search Results Section

    private var allMatchedClips: [ClipboardItem] {
        let query = hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return FuzzySearchEngine().search(query: query, in: clipboardStore.items)
    }

    private var filteredClips: [ClipboardItem] {
        let query = hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return Array(clipboardStore.items.prefix(4))
        }
        return Array(allMatchedClips.prefix(5))
    }

    private var sectionHeaderTitle: String {
        let query = hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "RECENT CLIPS"
        } else {
            return "SEARCH RESULTS (\(allMatchedClips.count))"
        }
    }

    private var recentClipsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sectionHeaderTitle)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.secondary.opacity(0.8))
                    .kerning(0.5)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 1)

            let clips = filteredClips
            if clips.isEmpty {
                HStack {
                    Spacer()
                    Text(hubState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No recent clipboard history" : "No matching clips found")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 10)
                    Spacer()
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, item in
                        clipRow(index: index, item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clipRow(index: Int, item: ClipboardItem) -> some View {
        let isHovered = hubState.hoveredClipId == item.id
        let button = Button {
            clipboardStore.selectAndRestoreItem(item)
            ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
            onClose()
        } label: {
            HStack(spacing: 9) {
                // Leading Icon / Thumbnail
                if item.itemType == .image {
                    ThumbnailPreviewView(item: item, size: 28, cornerRadius: 5)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                        Image(systemName: iconForType(item.itemType))
                            .font(.system(size: 11.5))
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                    }
                    .frame(width: 28, height: 28)
                }

                // Title / Content / Dimension Badges
                if item.itemType == .image {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Image")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.primary)

                        HStack(spacing: 4) {
                            Text(imageDimensionString(for: item))
                                .font(.system(size: 9.5))
                                .monospacedDigit()
                                .foregroundColor(.secondary)

                            Text("•")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.4))

                            Text(SystemCleanerService.formatBytes(Int64(item.byteSize)))
                                .font(.system(size: 9.5))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(item.previewText)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                // Quick preview eye button on hover for image clips
                if item.itemType == .image && isHovered {
                    Button {
                        hubState.quickLookItem = item
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .padding(3)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Quick Preview")
                }

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.orange)
                }

                if index < 4 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            if hovered {
                hubState.setHoveredClip(item.id)
            } else {
                hubState.clearHoveredClip(ifCurrent: item.id)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)

        if index < 4 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            button
        }
    }

    private func imageDimensionString(for item: ClipboardItem) -> String {
        if case .image(_, let width, let height) = item.payload {
            return "\(width) × \(height)"
        }
        return ""
    }

    private func iconForType(_ type: ClipboardItemType) -> String {
        switch type {
        case .plainText: return "doc.text"
        case .richText: return "text.quote"
        case .image: return "photo"
        }
    }

    // MARK: - 4. Subtle Status & Control Footer

    private var footerRow: some View {
        VStack(spacing: 6) {
            // Top telemetry sub-row: Battery, SSD Free Space, and Peripherals
            HStack(spacing: 8) {
                // Battery status
                if hubState.hardwareSnapshot.battery.hasBattery {
                    HStack(spacing: 3) {
                        Image(systemName: hubState.hardwareSnapshot.battery.isCharging ? "battery.100.bolt" : "battery.75")
                            .font(.system(size: 9.5))
                            .foregroundColor(hubState.hardwareSnapshot.battery.isCharging ? .green : (hubState.hardwareSnapshot.battery.percentage <= 20 ? .red : .secondary))
                        Text("\(hubState.hardwareSnapshot.battery.percentage)%")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .help("Battery: \(hubState.hardwareSnapshot.battery.percentage)%, Condition: \(hubState.hardwareSnapshot.battery.condition), Cycles: \(hubState.hardwareSnapshot.battery.cycleCount ?? 0)")
                }

                // Storage status
                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                    Text("\(hubState.hardwareSnapshot.disk.freeBytes / 1_073_741_824)G free")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .help("\(hubState.hardwareSnapshot.disk.volumeName): \(hubState.hardwareSnapshot.disk.freeBytes / 1_073_741_824) GB free of \(hubState.hardwareSnapshot.disk.totalBytes / 1_073_741_824) GB")

                // Connected Bluetooth accessories
                ForEach(hubState.hardwareSnapshot.bluetoothDevices) { dev in
                    HStack(spacing: 3) {
                        Image(systemName: dev.icon)
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        Text("\(dev.batteryPercent)%")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .help("\(dev.name): \(dev.batteryPercent)%")
                }

                Spacer()

                // Settings & Quit
                HStack(spacing: 4) {
                    Button {
                        onClose()
                        onOpenPreferences()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11))
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
                                .font(.system(size: 11))
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

            // Bottom action tools row: DoH Shield, System Cleaner & Optimizer
            HStack(spacing: 6) {
                // DoH Shield Toggle
                Button {
                    privacyController.toggle()
                } label: {
                    HStack(spacing: 4.5) {
                        Circle()
                            .fill(privacyController.isRunning ? Color(red: 0.18, green: 0.8, blue: 0.44) : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)

                        Text("DoH Shield")
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
                        let freed = await cleaner.cleanSelected()
                        if freed > 0 {
                            ToastHUDController.shared.show(
                                message: "Freed \(SystemCleanerService.formatBytes(freed))",
                                icon: "broom.fill"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "broom.fill")
                            .font(.system(size: 10))
                            .foregroundColor(cleaner.selectedJunkSize > 0 ? Color.orange : Color.secondary)

                        Text(cleaner.isCleaning ? "Cleaning..." : (cleaner.isScanning ? "Scanning..." : (cleaner.selectedJunkSize > 0 ? cleaner.formattedSelectedJunkSize : "Clean")))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
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
                .help(cleaner.selectedJunkSize > 0 ? "Clean \(cleaner.formattedSelectedJunkSize) system junk" : "System junk is clean")
                .onHover { isHovered in
                    if isHovered {
                        hubState.setHoveredFooter("cleaner")
                    } else {
                        hubState.clearHoveredFooter(ifCurrent: "cleaner")
                    }
                }

                // System Optimizer Button
                Button {
                    Task {
                        _ = try? SystemOptimizerService.shared.execute(taskId: .preventNetworkDsStore)
                        _ = try? SystemOptimizerService.shared.execute(taskId: .quickLookCacheRefresh)
                        _ = try? SystemOptimizerService.shared.execute(taskId: .dnsCacheFlush)
                        ToastHUDController.shared.show(message: "System Optimized & DNS Flushed", icon: "sparkles")
                        hubState.refreshHardwareSnapshot()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color.cyan)
                        Text("Optimize")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(hubState.hoveredFooterId == "optimizer" ? 0.08 : 0.04))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Run System Maintenance (Flush DNS, Clean QuickLook, Disable .DS_Store on USB/Network)")
                .onHover { isHovered in
                    if isHovered {
                        hubState.setHoveredFooter("optimizer")
                    } else {
                        hubState.clearHoveredFooter(ifCurrent: "optimizer")
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    // MARK: - Hairline Divider

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 2)
    }
}
