import SwiftUI
import ZenithCore

/// How a tool looks and what a click on it does, shared by the dock and the Tools page.
@MainActor
enum IslandToolStyle {
    static func tint(for tool: IslandTool) -> Color {
        switch tool {
        case .area: return ZenithTint.capture
        case .screen: return ZenithTint.screen
        case .record: return ZenithTint.recording
        case .ocr: return ZenithTint.ocr
        case .clipboard: return ZenithTint.clipboard
        case .cleaning: return ZenithTint.general
        case .privacyShield: return ZenithTint.privacy
        case .keepAwake: return ZenithTint.keepAwake
        case .clean: return ZenithTint.cleaner
        case .uninstall: return Color(nsColor: .systemPink)
        case .cleaner: return Color(nsColor: .systemMint)
        case .boost: return Color(nsColor: .systemYellow)
        case .system: return Color(nsColor: .systemGray)
        case .ports: return ZenithTint.network
        case .homebrew: return HomebrewSettingsTab.tint
        case .displays: return Color(nsColor: .systemOrange)
        case .settings, .quit, .allTools: return Color(white: 0.24)
        }
    }

    /// The glyph colour of the tinted style: the tool's colour, and for the tools that have none (Settings, Quit, All
    /// Tools: their solid tile is dark grey) a light grey.
    static func glyphTint(for tool: IslandTool) -> Color {
        switch tool {
        case .settings, .quit, .allTools: return Color(white: 0.92)
        default: return tint(for: tool)
        }
    }

    /// The tool's name and, where it has a shortcut that is on, the shortcut: what the dock shows for the button
    /// under the pointer.
    static func caption(for tool: IslandTool) -> String {
        guard let shortcut = shortcut(for: tool) else { return tool.title }
        return "\(tool.title)  \(shortcut)"
    }

    static func tooltip(for tool: IslandTool) -> String {
        guard let shortcut = shortcut(for: tool) else { return tool.detail }
        return "\(tool.detail) (\(shortcut))"
    }

    private static func shortcut(for tool: IslandTool) -> String? {
        guard let action = tool.hubAction else { return nil }
        // Cleaning Mode's shortcut is off unless Settings turns it on.
        if action == .cleaning, !CleaningModeSettings.shared.hotKeyEnabled { return nil }
        return SettingsStore.shared.effectiveHotkey(for: action.hotKeyId)?.menuStyleKeyEquivalent
            ?? HotKeyDefinition.menuStyle(action.shortcut)
    }

    /// A page (System, All Tools) opens inside the island and a switch flips in place. Anything else closes the
    /// island first: a capture must not start with the open island in the picture, and the tools that open
    /// Zenith's Settings window (Cleaner, Ports, Homebrew, Uninstall, Settings) would otherwise leave the island
    /// open over it.
    static func activate(_ tool: IslandTool, islandState: ZenithIslandState) {
        if tool == .keepAwake {
            // On: turn it off. Off: ask for how long, right there, instead of silently meaning "until turned off".
            if KeepAwakeService.shared.isActive {
                KeepAwakeService.shared.stop()
            } else {
                IslandKeepAwakePrompt.shared.isShowing = true
            }
            return
        }
        if tool.page == nil && !tool.isToggle { islandState.close() }
        ZenithToolActions.run(tool)
    }
}

/// Whether the island is asking how long Keep Awake should hold (the dock, or the Tools page's strip, then shows
/// the choices in place of its icons).
@MainActor
final class IslandKeepAwakePrompt: ObservableObject {
    static let shared = IslandKeepAwakePrompt()
    @Published var isShowing = false
}

/// The answer to "for how long?": the preset times and "until turned off" as buttons, and a way out.
struct IslandKeepAwakeChoices: View {
    @ObservedObject private var prompt = IslandKeepAwakePrompt.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(KeepAwakeMode.quickChoices, id: \.self) { mode in
                Button {
                    KeepAwakeService.shared.start(mode)
                    prompt.isShowing = false
                } label: {
                    Group {
                        if mode == .indefinite {
                            // "Until Turned Off" does not fit beside four times in the dock: the infinity sign, named by its tooltip.
                            Image(systemName: "infinity")
                                .font(.system(size: 12, weight: .bold))
                        } else {
                            Text(verbatim: mode.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    // Dark on the yellow: white on it was about 1.6:1; black is above 10:1.
                    .foregroundColor(Color.black.opacity(0.88))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(ZenithTint.keepAwake))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: mode.title))
                .accessibilityLabel(Text(verbatim: mode.title))
            }
            Spacer(minLength: 0)
            Button {
                prompt.isShowing = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
    }
}

/// Whether the two switches are on. One object, so a view observes both with a single wrapper.
@MainActor
final class IslandToolSwitches: ObservableObject {
    static let shared = IslandToolSwitches()

    @Published private(set) var privacyShieldOn = PrivacyShieldController.shared.isRunning
    @Published private(set) var keepAwakeOn = KeepAwakeService.shared.isActive

    private init() {
        PrivacyShieldController.shared.$isRunning.removeDuplicates().assign(to: &$privacyShieldOn)
        KeepAwakeService.shared.$mode.map { $0 != nil }.removeDuplicates().assign(to: &$keepAwakeOn)
    }

    /// `nil` for a tool that is not a switch.
    func isOn(_ tool: IslandTool) -> Bool? {
        switch tool {
        case .privacyShield: return privacyShieldOn
        case .keepAwake: return keepAwakeOn
        default: return nil
        }
    }
}

/// A tool as a rounded icon, in the style the user chose (`IslandWidgetSettings.dockIconStyle`).
///
/// Tinted: a faint light tile with an inner highlight and the glyph in the tool's colour; a switch that is off is a
/// dimmer tile with a grey glyph. Color: a solid tile in the tool's colour with a white glyph; a switch that is off is
/// grey. The corners are 36 % of the side (14 pt at 40), concentric with the dock's tray around the icons.
///
/// Under the pointer (`isHovered`, set by the dock) the icon lifts a little, unless Reduce Motion is on.
struct IslandToolIcon: View {
    let tool: IslandTool
    let size: CGFloat
    let isHovered: Bool
    @ObservedObject private var switches = IslandToolSwitches.shared
    @ObservedObject private var settings = IslandWidgetSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOff = switches.isOn(tool) == false
        let shape = RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
        return Image(systemName: tool.icon)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(glyphColor(isOff: isOff))
            .frame(width: size, height: size)
            .background(tileFill(isOff: isOff), in: shape)
            .overlay(highlight(shape))
            // The island clips everything to its rounded shape, and a clip flattens a symbol's colour to white (record,
            // sparkles, the window and viewfinder symbols came out white in the tinted style). Drawing the icon as one
            // group first keeps the glyph's colour.
            .compositingGroup()
            .offset(y: isHovered && !reduceMotion ? -2 : 0)
            .scaleEffect(isHovered && !reduceMotion ? 1.06 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: isHovered)
    }

    private var isTinted: Bool { settings.dockIconStyle == .tinted }

    private func glyphColor(isOff: Bool) -> Color {
        if isTinted {
            return isOff ? .white.opacity(0.45) : IslandToolStyle.glyphTint(for: tool)
        }
        return .white.opacity(isOff ? 0.7 : 1)
    }

    private func tileFill(isOff: Bool) -> Color {
        if isTinted { return .white.opacity(isOff ? 0.04 : 0.08) }
        return isOff ? Color(white: 0.2) : IslandToolStyle.tint(for: tool)
    }

    /// Tinted tiles get a 1 pt inner stroke, brighter along the top edge; solid ones a light edge on top.
    @ViewBuilder
    private func highlight(_ shape: RoundedRectangle) -> some View {
        if isTinted {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        } else {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
        }
    }
}

/// What a switch offers beyond on and off, in its context menu: how long Keep Awake holds, and Privacy Shield's
/// settings. Nothing for the other tools.
struct IslandToolMenuItems: View {
    let tool: IslandTool
    @ObservedObject var islandState: ZenithIslandState

    var body: some View {
        switch tool {
        case .keepAwake:
            KeepAwakeModeMenuItems(service: .shared, settings: .shared)
            Divider()
        case .privacyShield:
            Button("Privacy Shield Settings…") {
                islandState.close()
                ZenithToolActions.openSettings(on: .privacy)
            }
            Divider()
        default:
            EmptyView()
        }
    }
}

/// (Not `@State`: the SwiftUI macro plugin is not available to a Command Line Tools build.)
final class IslandToolHover: ObservableObject {
    @Published var tool: IslandTool?
}

/// Where the dragged icon is on the Tools page's dock strip, from the strip's leading edge. It changes with every
/// pointer move, so it is an object of its own: only the one small view that draws the dragged icon observes it,
/// and the rest of the page is not redrawn sixty times a second.
@MainActor
final class IslandDockDragPosition: ObservableObject {
    static let shared = IslandDockDragPosition()
    @Published var x: CGFloat = 0
}

/// The icon being dragged, drawn over the strip at the pointer.
private struct IslandDockDragGhost: View {
    let tool: IslandTool
    @ObservedObject private var position = IslandDockDragPosition.shared

    var body: some View {
        IslandToolIcon(tool: tool, size: IslandDockEditor.stripIconSize, isHovered: true)
            .offset(x: position.x)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Editing the dock: whether the Tools page is in its edit mode, and the icon being dragged there.
@MainActor
final class IslandDockEditor: ObservableObject {
    static let shared = IslandDockEditor()

    /// An icon on the Tools page's dock strip, and its slot: the icon and the gap to the next. Seven slots, and in
    /// edit mode Reset and Done after them, fit the 348 pt the strip has in the 380 pt island.
    static let stripIconSize: CGFloat = 28
    static let slotWidth: CGFloat = 34

    @Published var isEditing = false
    /// The icon being dragged on the strip. Its slot in the row is left empty (and moves as the others make room);
    /// the icon itself is drawn apart, at `IslandDockDragPosition.x`, so it follows the pointer exactly.
    @Published private(set) var draggedTool: IslandTool?
    private var dragStartIndex = 0
    private var settleTask: Task<Void, Never>?

    private var settings: IslandWidgetSettings { .shared }
    private var position: IslandDockDragPosition { .shared }

    /// The pointer has moved `translation` points sideways with `tool` held. `translation` must be measured in a
    /// coordinate space that does not move with the icon (the gesture uses the screen's): measured in the icon's
    /// own space it changes by a slot every time the icon changes slot, and the icon flickers between two places.
    func drag(_ tool: IslandTool, translation: CGFloat) {
        guard let current = settings.dockLayout.pinned.firstIndex(of: tool) else { return }
        if draggedTool != tool {
            settleTask?.cancel()
            draggedTool = tool
            dragStartIndex = current
        }
        let count = settings.dockLayout.pinned.count
        let target = IslandDockLayout.dragTargetIndex(
            startIndex: dragStartIndex, translation: translation, slotWidth: Self.slotWidth, count: count
        )
        if target != current {
            // Only the other icons are seen sliding: the dragged one is not drawn in the row.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                settings.dockLayout.move(tool, to: target)
            }
        }
        // A little past either end, so the icon does not stop dead at the edge of the strip.
        position.x = IslandDockLayout.dragGhostOffset(
            startIndex: dragStartIndex, translation: translation, slotWidth: Self.slotWidth, count: count
        )
    }

    /// The icon is let go: it glides into the slot it has, then takes its place in the row again.
    func endDrag() {
        guard let tool = draggedTool, let index = settings.dockLayout.pinned.firstIndex(of: tool) else {
            draggedTool = nil
            return
        }
        withAnimation(.easeOut(duration: 0.14)) {
            position.x = CGFloat(index) * Self.slotWidth
        }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self = self, !Task.isCancelled, self.draggedTool == tool else { return }
            self.draggedTool = nil
        }
    }

    /// Opens the Tools page ready for editing (the dock's "Edit Dock…").
    func beginEditing(on island: ZenithIslandState) {
        isEditing = true
        island.openPage(.tools)
    }
}

/// The dock under the open island: the tools the user put there and, last, the way to all the others. Above them
/// one line names the icon under the pointer, so an icon never has to be guessed at. Right-click an icon to move or
/// remove it.
struct IslandDock: View {
    /// Seven icons (six tools and All Tools) and the rule fit the tray in 380 pt (`ZenithIslandGeometry.dockRowWidth`).
    static let iconSize: CGFloat = ZenithIslandGeometry.dockIconSize
    @ObservedObject var islandState: ZenithIslandState
    @StateObject private var hover = IslandToolHover()
    @ObservedObject private var switches = IslandToolSwitches.shared
    @ObservedObject private var settings = IslandWidgetSettings.shared
    @ObservedObject private var keepAwakePrompt = IslandKeepAwakePrompt.shared
    @ObservedObject private var keepAwake = KeepAwakeService.shared

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: caption)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .frame(height: 11)
                .accessibilityHidden(keepAwakePrompt.isShowing ? false : true)

            Group {
                if keepAwakePrompt.isShowing {
                    IslandKeepAwakeChoices()
                        .padding(.horizontal, 6)
                        .frame(height: ZenithIslandGeometry.dockIconSize)
                } else {
                    HStack(spacing: ZenithIslandGeometry.dockIconSpacing) {
                        ForEach(settings.dockLayout.pinned) { tool in
                            button(tool)
                        }
                        if !settings.dockLayout.pinned.isEmpty {
                            // A thin rule before the way to everything that is not on the dock.
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1, height: 22)
                                .padding(.horizontal, (ZenithIslandGeometry.dockRuleWidth - 1) / 2)
                                .accessibilityHidden(true)
                        }
                        button(.allTools)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(ZenithIslandGeometry.dockTrayPadding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.horizontal, ZenithIslandGeometry.dockSideInset)
        .padding(.bottom, 6)
        .frame(width: ZenithIslandGeometry.expandedWidth, height: ZenithIslandGeometry.dockHeight, alignment: .bottom)
        // The question is not left open behind a closed island.
        .onDisappear { keepAwakePrompt.isShowing = false }
    }

    /// The question while Keep Awake is being turned on; else the hovered tool's name (with "On"/"Off" for a
    /// switch, and for Keep Awake how long it still holds); else nothing.
    private var caption: String {
        if keepAwakePrompt.isShowing { return String(localized: "Keep the Mac awake for") }
        guard let tool = hover.tool else { return "" }
        guard let isOn = switches.isOn(tool) else { return IslandToolStyle.caption(for: tool) }
        if tool == .keepAwake, isOn, let status = keepAwake.snapshot?.statusText {
            return "\(tool.title): \(status)"
        }
        return isOn ? String(localized: "\(tool.title): On") : String(localized: "\(tool.title): Off")
    }

    private func button(_ tool: IslandTool) -> some View {
        Button {
            IslandToolStyle.activate(tool, islandState: islandState)
        } label: {
            IslandToolIcon(tool: tool, size: Self.iconSize, isHovered: hover.tool == tool)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(IslandToolStyle.tooltip(for: tool))
        .accessibilityLabel(Text(verbatim: tool.title))
        .accessibilityHint(Text(verbatim: tool.detail))
        .accessibilityValue(Text(verbatim: switchValue(tool)))
        .onHover { hovering in
            if hovering {
                hover.tool = tool
            } else if hover.tool == tool {
                hover.tool = nil
            }
        }
        .contextMenu {
            IslandToolMenuItems(tool: tool, islandState: islandState)
            if settings.dockLayout.contains(tool) {
                Button("Move Left") { settings.dockLayout.move(tool, by: -1) }
                    .disabled(!settings.dockLayout.canMove(tool, by: -1))
                Button("Move Right") { settings.dockLayout.move(tool, by: 1) }
                    .disabled(!settings.dockLayout.canMove(tool, by: 1))
                Button("Remove from Dock") { settings.dockLayout.unpin(tool) }
                Divider()
            }
            Button("Edit Dock…") { IslandDockEditor.shared.beginEditing(on: islandState) }
        }
    }

    private func switchValue(_ tool: IslandTool) -> String {
        guard let isOn = switches.isOn(tool) else { return "" }
        return isOn ? String(localized: "On") : String(localized: "Off")
    }
}

/// The Tools page: every tool as an icon with its full name under it, in named groups one under the other (four
/// tiles to a row), and at the bottom the dock as it is now, with Edit, Settings and Quit. It is as wide as the
/// island, 380 pt.
///
/// In edit mode a click on a tool puts it on the dock or takes it off, and the icons on the strip can be dragged
/// into another order (or moved from their context menu). Every change is saved as it is made.
struct IslandAllToolsPage: View {
    @ObservedObject var islandState: ZenithIslandState
    @StateObject private var hover = IslandToolHover()
    @ObservedObject private var editor = IslandDockEditor.shared
    @ObservedObject private var settings = IslandWidgetSettings.shared
    @ObservedObject private var keepAwakePrompt = IslandKeepAwakePrompt.shared

    private static let sideInset: CGFloat = 16
    /// Four tiles fill a row of the page.
    private static let tileWidth = (ZenithIslandGeometry.expandedWidth - 2 * sideInset) / 4
    private static let stripHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(IslandTool.groups) { group in
                    groupView(group)
                }
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            dockStrip
        }
        .onDisappear {
            editor.isEditing = false
            keepAwakePrompt.isShowing = false
        }
    }

    /// A group's name and its tools in one row, every tile as wide as a quarter of the page, whether the group has
    /// four tools or three.
    private func groupView(_ group: IslandTool.Group) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: group.title)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.5))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 0) {
                ForEach(group.tools) { tool in
                    tile(tool)
                }
            }
        }
    }

    private func tile(_ tool: IslandTool) -> some View {
        let isPinned = settings.dockLayout.contains(tool)
        // In edit mode a tool that cannot be added (the dock is full) steps back.
        let isUnavailable = editor.isEditing && !isPinned && settings.dockLayout.isFull
        let isHovered = hover.tool == tool
        return Button {
            if editor.isEditing {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    _ = settings.dockLayout.toggle(tool)
                }
            } else {
                IslandToolStyle.activate(tool, islandState: islandState)
            }
        } label: {
            VStack(spacing: 4) {
                // The tile as a whole lights up under the pointer, so the icon itself does not lift here.
                IslandToolIcon(tool: tool, size: 38, isHovered: false)
                    .overlay(alignment: .topTrailing) {
                        if editor.isEditing && !isUnavailable {
                            Image(systemName: isPinned ? "checkmark.circle.fill" : "plus.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, isPinned ? Color(nsColor: .systemGreen) : Color(white: 0.42))
                                .offset(x: 4, y: -4)
                        }
                    }
                Text(verbatim: tool.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.top, 5)
            .frame(width: Self.tileWidth, height: 72, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .opacity(isUnavailable ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            IslandToolMenuItems(tool: tool, islandState: islandState)
        }
        .help(IslandToolStyle.tooltip(for: tool))
        .accessibilityLabel(Text(verbatim: tool.title))
        .accessibilityHint(Text(verbatim: tool.detail))
        .accessibilityValue(Text(verbatim: editor.isEditing
            ? (isPinned ? String(localized: "On the dock") : String(localized: "Not on the dock"))
            : ""))
        .onHover { hovering in
            if hovering {
                hover.tool = tool
            } else if hover.tool == tool {
                hover.tool = nil
            }
        }
    }

    // MARK: Dock strip

    /// The strip at the bottom: the dock as it is, or, while Keep Awake is being turned on, for how long.
    @ViewBuilder
    private var dockStrip: some View {
        if keepAwakePrompt.isShowing {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep the Mac awake for")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                IslandKeepAwakeChoices()
                    .frame(height: 28)
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(height: Self.stripHeight)
            .background(Color.white.opacity(0.05))
        } else {
            dockIcons
        }
    }

    /// Caption row (the strip's name and Edit, or while editing what to do), then the icons; while editing, Reset and
    /// Done at the end of the icons; otherwise Settings and Quit.
    private var dockIcons: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if editor.isEditing {
                    Text(verbatim: stripCaption)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    // The same small uppercase label as the groups above.
                    Text(verbatim: stripCaption)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    stripButton("Edit Dock") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { editor.isEditing = true }
                    }
                    .help("Choose which tools are on the dock under the island, and in what order")
                }
            }
            .frame(height: 20)

            HStack(spacing: 0) {
                HStack(spacing: IslandDockEditor.slotWidth - IslandDockEditor.stripIconSize) {
                    ForEach(settings.dockLayout.pinned) { tool in
                        stripIcon(tool)
                    }
                    IslandToolIcon(tool: .allTools, size: IslandDockEditor.stripIconSize, isHovered: false)
                        .opacity(0.55)
                        .help("All Tools is always the last icon on the dock")
                        .accessibilityLabel(Text(verbatim: IslandTool.allTools.title))
                }
                .overlay(alignment: .leading) {
                    if let dragged = editor.draggedTool {
                        IslandDockDragGhost(tool: dragged)
                    }
                }
                Spacer(minLength: 8)
                if !editor.isEditing {
                    // Apart from the tools on purpose: small, in the corner, where nobody reaching for a tool lands on Quit.
                    HStack(spacing: 6) {
                        cornerButton(.settings)
                        cornerButton(.quit)
                    }
                }
                if editor.isEditing {
                    stripButton("Reset") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { settings.dockLayout = IslandDockLayout() }
                    }
                    .disabled(settings.dockLayout == IslandDockLayout())
                    .padding(.trailing, 6)
                    stripButton("Done", prominent: true) { editor.isEditing = false }
                }
            }
        }
        .padding(.horizontal, Self.sideInset)
        .padding(.top, 5)
        .padding(.bottom, 7)
        .frame(height: Self.stripHeight)
        .background(Color.white.opacity(0.05))
    }

    private func cornerButton(_ tool: IslandTool) -> some View {
        Button {
            IslandToolStyle.activate(tool, islandState: islandState)
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
        .accessibilityLabel(Text(verbatim: tool.title))
    }

    private var stripCaption: String {
        guard editor.isEditing else { return String(localized: "Dock") }
        return settings.dockLayout.isFull
            ? String(localized: "The dock is full. Click a tool on it to remove it.")
            : String(localized: "Click a tool to add or remove it. Drag icons to reorder.")
    }

    /// An icon on the strip. In edit mode it can be dragged sideways, clicked to take it off, and moved from its
    /// context menu (the way to reorder without a pointer drag).
    private func stripIcon(_ tool: IslandTool) -> some View {
        let isDragged = editor.draggedTool == tool
        return IslandToolIcon(tool: tool, size: IslandDockEditor.stripIconSize, isHovered: false)
            // While it is dragged the icon is drawn by `IslandDockDragGhost`; this is its empty slot.
            .opacity(isDragged ? 0 : 1)
            .overlay(alignment: .topTrailing) {
                if editor.isEditing && !isDragged {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.42))
                        .offset(x: 5, y: -5)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // The screen's coordinates, not the icon's: the icon moves under the pointer as it changes slot.
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        guard editor.isEditing else { return }
                        editor.drag(tool, translation: value.translation.width)
                    }
                    .onEnded { _ in editor.endDrag() }
            )
            .onTapGesture {
                guard editor.isEditing else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { settings.dockLayout.unpin(tool) }
            }
            .contextMenu {
                Button("Move Left") { settings.dockLayout.move(tool, by: -1) }
                    .disabled(!settings.dockLayout.canMove(tool, by: -1))
                Button("Move Right") { settings.dockLayout.move(tool, by: 1) }
                    .disabled(!settings.dockLayout.canMove(tool, by: 1))
                Button("Remove from Dock") { settings.dockLayout.unpin(tool) }
            }
            .help(tool.title)
            .accessibilityLabel(Text(verbatim: tool.title))
            .accessibilityAddTraits(editor.isEditing ? .isButton : [])
            .accessibilityAction(named: "Move Left") { settings.dockLayout.move(tool, by: -1) }
            .accessibilityAction(named: "Move Right") { settings.dockLayout.move(tool, by: 1) }
            .accessibilityAction(named: "Remove from Dock") { settings.dockLayout.unpin(tool) }
    }

    private func stripButton(_ title: LocalizedStringKey, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(prominent ? .black : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(prominent ? Color.white.opacity(0.92) : Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
