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

            hairlineDivider

            // 2. QUICK ACTIONS LIST (when query is empty or matches actions)
            if !matchingActions.isEmpty {
                quickActionsList
                hairlineDivider
            }

            // TOP CPU HOGS DRAWER (when toggled)
            if hubState.showTopHogs {
                topCpuHogsSection
                hairlineDivider
            }

            // 3. RECENT CLIPS / SEARCH RESULTS SECTION
            recentClipsSection

            hairlineDivider

            // INLINE CONFIRMATION (for destructive footer / drawer actions)
            if let confirmation = hubState.pendingConfirmation {
                confirmationBar(confirmation)
            }

            // 4. SUBTLE STATUS & CONTROL FOOTER
            footerRow
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hubState.pendingConfirmation)
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
            if hubState.pendingConfirmation != nil {
                hubState.cancelConfirmation()
            } else if hubState.quickLookItem != nil {
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
        .onChange(of: hubState.searchText) { _, _ in
            hubState.clearSelection()
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
        if let confirmation = hubState.pendingConfirmation {
            performConfirmation(confirmation)
            return
        }

        let entries = hubState.entries(in: clipboardStore.items)
        if let index = hubState.selectedEntryIndex, index < entries.count {
            activate(entries[index])
            return
        }

        let query = hubState.trimmedQuery
        if query.isEmpty {
            if let firstClip = filteredClips.first {
                copyClip(firstClip)
            } else if let firstAction = matchingActions.first {
                executeAction(firstAction)
            }
            return
        }

        // When query is non-empty:
        if let firstAction = matchingActions.first, matchingActions.count < ZenithHubAction.allCases.count {
            executeAction(firstAction)
        } else if let firstClip = filteredClips.first {
            copyClip(firstClip)
        } else if let firstAction = matchingActions.first {
            executeAction(firstAction)
        }
    }

    // MARK: - 2. Quick Actions List

    private var matchingActions: [ZenithHubAction] {
        hubState.matchingActions
    }

    /// Whether `entry` is the row currently chosen with the arrow keys.
    private func isKeyboardSelected(_ entry: ZenithHubEntry) -> Bool {
        guard let index = hubState.selectedEntryIndex else { return false }
        let entries = hubState.entries(in: clipboardStore.items)
        guard index < entries.count else { return false }
        switch (entries[index], entry) {
        case (.action(let lhs), .action(let rhs)):
            return lhs == rhs
        case (.clip(let lhs), .clip(let rhs)):
            return lhs.id == rhs.id
        default:
            return false
        }
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        return Color.primary.opacity(isHovered ? 0.06 : 0.0)
    }

    private var quickActionsList: some View {
        VStack(spacing: 2) {
            ForEach(matchingActions, id: \.self) { action in
                quickActionRow(action: action)
            }
        }
    }

    private func quickActionRow(action: ZenithHubAction) -> some View {
        let isSelected = isKeyboardSelected(.action(action))
        let isHovered = hubState.hoveredActionId == action.rawValue
        return Button {
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
                    .fill(rowFill(isSelected: isSelected, isHovered: isHovered))
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
        .animation(.easeInOut(duration: 0.12), value: isHovered || isSelected)
    }

    private func activate(_ entry: ZenithHubEntry) {
        switch entry {
        case .action(let action):
            executeAction(action)
        case .clip(let item):
            copyClip(item)
        }
    }

    private func copyClip(_ item: ClipboardItem) {
        clipboardStore.selectAndRestoreItem(item)
        ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
        onClose()
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
        hubState.allMatchedClips(in: clipboardStore.items)
    }

    private var filteredClips: [ClipboardItem] {
        hubState.visibleClips(in: clipboardStore.items)
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
        let isSelected = isKeyboardSelected(.clip(item))
        let button = Button {
            copyClip(item)
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
                    .fill(rowFill(isSelected: isSelected, isHovered: isHovered))
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
        .animation(.easeInOut(duration: 0.12), value: isHovered || isSelected)

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
        VStack(spacing: 7) {
            telemetryRow
            footerActionsRow
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    /// Read-only status line: CPU, memory, battery, free disk space and the lowest accessory battery.
    private var telemetryRow: some View {
        let snapshot = hubState.hardwareSnapshot
        let cpuPercent = snapshot.cpu.totalUsagePercent
        let memory = snapshot.memory
        let battery = snapshot.battery
        let disk = snapshot.disk
        let lowestAccessory = snapshot.bluetoothDevices.min { $0.batteryPercent < $1.batteryPercent }

        return HStack(spacing: 10) {
            telemetryItem(
                icon: "cpu",
                value: "\(Int(round(cpuPercent)))%",
                tint: cpuPercent > 75 ? .red : (cpuPercent > 40 ? .orange : .secondary),
                help: "CPU Usage: \(String(format: "%.1f", cpuPercent))% across \(snapshot.cpu.coreCount) cores"
            )

            telemetryItem(
                icon: "memorychip",
                value: "\(Int(round(memory.usedPercent)))%",
                tint: memory.pressureLevel == .critical ? .red : (memory.pressureLevel == .warning ? .orange : .secondary),
                help: "Memory: \(HardwareTelemetryService.formatBytes(memory.usedBytes)) used of \(HardwareTelemetryService.formatBytes(memory.totalBytes)) (\(memory.pressureLevel.rawValue.capitalized) pressure)"
            )

            if battery.hasBattery {
                telemetryItem(
                    icon: battery.isCharging ? "battery.100.bolt" : "battery.75",
                    value: "\(battery.percentage)%",
                    tint: battery.isCharging ? .green : (battery.percentage <= 20 ? .red : .secondary),
                    help: "Battery: \(battery.percentage)%, Condition: \(battery.condition), Cycles: \(battery.cycleCount ?? 0)"
                )
            }

            telemetryItem(
                icon: "internaldrive",
                value: "\(disk.freeBytes / 1_073_741_824) GB",
                tint: .secondary,
                help: "\(disk.volumeName): \(disk.freeBytes / 1_073_741_824) GB free of \(disk.totalBytes / 1_073_741_824) GB"
            )

            if let accessory = lowestAccessory {
                telemetryItem(
                    icon: accessory.icon,
                    value: "\(accessory.batteryPercent)%",
                    tint: accessory.batteryPercent <= 20 ? .red : .secondary,
                    help: snapshot.bluetoothDevices
                        .map { "\($0.name): \($0.batteryPercent)%" }
                        .joined(separator: "\n")
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func telemetryItem(icon: String, value: String, tint: Color, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundColor(tint)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    /// Action line: DoH Shield, cleaner and CPU drawer on the left; overflow menu, Settings and Quit on the right.
    private var footerActionsRow: some View {
        HStack(spacing: 6) {
            // DoH Shield Toggle
            footerChip(
                id: "doh",
                help: privacyController.isRunning ? "DNS Protection Active (Click to disable)" : "DNS Protection Disabled (Click to enable)",
                action: { privacyController.toggle() }
            ) {
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(privacyController.isRunning ? ZenithTheme.success : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)

                    Text("DoH")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(privacyController.isRunning ? .primary : .secondary)
                }
            }
            .disabled(privacyController.isTransitioning)

            // System Cleaner (asks for confirmation before deleting anything)
            footerChip(
                id: "cleaner",
                help: cleaner.selectedJunkSize > 0 ? "Clean \(cleaner.formattedSelectedJunkSize) system junk" : (historyTracker.totalSessions > 0 ? historyTracker.summaryHeadline : "System junk is clean"),
                action: { hubState.requestConfirmation(.cleanJunk(formattedSize: cleaner.formattedSelectedJunkSize)) }
            ) {
                HStack(spacing: 4) {
                    Image(systemName: "broom.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(cleaner.selectedJunkSize > 0 ? Color.orange : Color.secondary)

                    Text(cleaner.isCleaning ? "Cleaning…" : (cleaner.isScanning ? "Scanning…" : (cleaner.selectedJunkSize > 0 ? cleaner.formattedSelectedJunkSize : "Clean")))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(cleaner.selectedJunkSize > 0 ? .primary : .secondary)
                }
            }
            .disabled(cleaner.isCleaning || cleaner.isScanning || cleaner.selectedJunkSize == 0)

            // Top CPU Hogs Toggle
            footerChip(
                id: "hogs",
                help: hubState.showTopHogs ? "Hide heavy CPU processes" : "Inspect and quit heavy CPU processes",
                selectedFill: hubState.showTopHogs ? Color.red.opacity(0.12) : nil,
                action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        hubState.toggleTopHogs()
                    }
                }
            ) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(hubState.showTopHogs ? .red : (hubState.hardwareSnapshot.cpu.totalUsagePercent > 50 ? .orange : .secondary))
                    Text("CPU")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(hubState.showTopHogs ? .primary : .secondary)
                }
            }

            Spacer(minLength: 0)

            // Overflow: less frequent actions
            Menu {
                Button {
                    hubState.requestConfirmation(.optimizeSystem)
                } label: {
                    Label("Optimize System…", systemImage: "sparkles")
                }

                Divider()

                Button {
                    onOpenClipboard()
                } label: {
                    Label("Clipboard History", systemImage: "list.clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")

            footerIconButton(id: "settings", systemImage: "gearshape", help: "Settings (⌘,)", hoverTint: .primary, hoverFill: Color.primary.opacity(0.08)) {
                onClose()
                onOpenPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)

            footerIconButton(id: "quit", systemImage: "power", help: "Quit Zenith (⌘Q)", hoverTint: .red, hoverFill: Color.red.opacity(0.12)) {
                onQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func footerChip<Content: View>(
        id: String,
        help: String,
        selectedFill: Color? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        let isHovered = hubState.hoveredFooterId == id
        let content = label()
        return Button(action: action) {
            content
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedFill ?? Color.primary.opacity(isHovered ? 0.08 : 0.04))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            if hovering {
                hubState.setHoveredFooter(id)
            } else {
                hubState.clearHoveredFooter(ifCurrent: id)
            }
        }
    }

    private func footerIconButton(
        id: String,
        systemImage: String,
        help: String,
        hoverTint: Color,
        hoverFill: Color,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hubState.hoveredFooterId == id
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundColor(isHovered ? hoverTint : .secondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? hoverFill : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            if hovering {
                hubState.setHoveredFooter(id)
            } else {
                hubState.clearHoveredFooter(ifCurrent: id)
            }
        }
    }

    // MARK: - Inline Confirmation

    private func confirmationBar(_ confirmation: ZenithHubConfirmation) -> some View {
        let tint: Color = confirmation.isDestructive ? .red : .accentColor
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: confirmation.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(confirmation.message)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("↵ confirm  ⎋ cancel")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(Color.secondary.opacity(0.7))

                Spacer()

                Button("Cancel") {
                    hubState.cancelConfirmation()
                }
                .controlSize(.small)

                Button(role: confirmation.isDestructive ? ButtonRole.destructive : nil) {
                    performConfirmation(confirmation)
                } label: {
                    Text(confirmation.confirmTitle)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func performConfirmation(_ confirmation: ZenithHubConfirmation) {
        hubState.cancelConfirmation()
        switch confirmation {
        case .cleanJunk:
            Task {
                let freed = await cleaner.cleanSelected()
                if freed > 0 {
                    ToastHUDController.shared.show(
                        message: "Freed \(SystemCleanerService.formatBytes(freed))",
                        icon: "broom.fill"
                    )
                }
            }
        case .optimizeSystem:
            Task {
                _ = try? SystemOptimizerService.shared.execute(taskId: .preventNetworkDsStore)
                _ = try? SystemOptimizerService.shared.execute(taskId: .quickLookCacheRefresh)
                _ = try? SystemOptimizerService.shared.execute(taskId: .dnsCacheFlush)
                ToastHUDController.shared.show(message: "System Optimized & DNS Flushed", icon: "sparkles")
                hubState.refreshHardwareSnapshot()
            }
        case .terminateProcess(let pid, let name):
            hubState.killProcess(pid: pid)
            ToastHUDController.shared.show(message: "Terminated \(name)", icon: "xmark.circle.fill")
        case .purgeZombies:
            _ = try? SystemOptimizerService().execute(taskId: .zombieProcessCleanup)
            hubState.refreshHardwareSnapshot()
            ToastHUDController.shared.show(message: "Zombies Purged", icon: "bolt.fill")
        }
    }

    // MARK: - Top CPU Hogs Section

    private var topCpuHogsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TOP CPU CONSUMERS")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.secondary.opacity(0.7))
                Spacer()
                Text("\(hubState.hardwareSnapshot.cpu.coreCount) Cores • \(Int(round(hubState.hardwareSnapshot.cpu.totalUsagePercent)))% Total")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            let hogs = Array(hubState.hardwareSnapshot.cpu.topHogs.prefix(4))
            if hogs.isEmpty {
                Text("Zero heavy CPU consumers")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            } else {
                ForEach(hogs) { hog in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(hog.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text("(\(hog.pid))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(HardwareTelemetryService.formatBytes(hog.memoryBytes))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text("\(String(format: "%.1f", hog.cpuPercent))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(hog.cpuPercent > 50 ? .red : (hog.cpuPercent > 20 ? .orange : .primary))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )

                        Button {
                            hubState.requestConfirmation(.terminateProcess(pid: hog.pid, name: hog.name))
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Terminate process \(hog.name) (PID \(hog.pid))")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }

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
                        hubState.requestConfirmation(.purgeZombies(count: hubState.hardwareSnapshot.cpu.zombieProcesses.count))
                    }
                    .font(.system(size: 9, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Hairline Divider

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 2)
    }
}
