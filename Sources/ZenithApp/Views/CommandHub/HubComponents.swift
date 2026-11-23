import SwiftUI
import AppKit
import ZenithCore

// MARK: - Modules

/// The look of the Command Hub's surfaces, Control Center style: rounded, translucent, with a 1 pt inner highlight.
///
/// These are semantic fills rather than `glassEffect`: on macOS 26 the popover behind the hub already is Liquid
/// Glass, and glass drawn on glass reads as mud (and the island's page is black, where it would show nothing). A
/// translucent white in Light and a faint one in Dark lift the modules off whatever is behind in both.
enum HubSurface {
    static let moduleRadius: CGFloat = 22

    static let fill = Color(nsColor: NSColor(name: "ZenithHubModuleFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.075)
            : NSColor(white: 1, alpha: 0.58)
    })
    static let edge = Color(nsColor: NSColor(name: "ZenithHubModuleEdge") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 1, alpha: 0.85)
    })
    /// The faint ring behind a gauge, a bar's empty part, and the small round buttons inside a module.
    static let track = Color.primary.opacity(0.1)
    static let chip = Color.primary.opacity(0.08)
}

private struct HubModuleModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: AnyShapeStyle = AnyShapeStyle(HubSurface.fill)

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(HubSurface.edge, lineWidth: 1))
    }
}

extension View {
    /// A rounded Command Hub module.
    func hubModule(radius: CGFloat = HubSurface.moduleRadius, fill: AnyShapeStyle? = nil) -> some View {
        modifier(HubModuleModifier(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                                   fill: fill ?? AnyShapeStyle(HubSurface.fill)))
    }

    /// A capsule-shaped Command Hub module (the search field, the Ports button).
    func hubCapsule() -> some View {
        modifier(HubModuleModifier(shape: RoundedRectangle(cornerRadius: 1000, style: .circular)))
    }
}

// MARK: - Gauges

/// A ring gauge: a 5 pt round-capped arc on a faint track, the value in the middle and the name under it.
struct HubRingGauge: View {
    let title: LocalizedStringKey
    let value: String
    /// The precise value for VoiceOver when `value` is a shortened one.
    var accessibilityValue: String? = nil
    let fraction: Double
    let tint: Color
    var valueSize: CGFloat = 14

    private static let diameter: CGFloat = 60
    private static let lineWidth: CGFloat = 5

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(HubSurface.track, lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: max(min(fraction, 1), 0.001))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: value)
                    .font(.system(size: valueSize, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8)
            }
            .padding(Self.lineWidth / 2)
            .frame(width: Self.diameter, height: Self.diameter)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: accessibilityValue ?? value))
    }
}

// MARK: - Toggle tile

/// A large Control Center tile: a symbol in a circle, the name and a status line. Filled with the feature's colour
/// (white text) while on, a plain module while off.
struct HubToggleTile<Accessory: View>: View {
    let title: LocalizedStringKey
    let status: String
    let symbol: String
    let isOn: Bool
    let fill: Color
    var isDisabled = false
    let help: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? Color.white.opacity(0.25) : HubSurface.chip))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: status)
                        .font(.system(size: 11.5))
                        .opacity(0.72)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hubModule(fill: isOn ? AnyShapeStyle(fill) : nil)
            .contentShape(RoundedRectangle(cornerRadius: HubSurface.moduleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .overlay(alignment: .topTrailing) { accessory().padding(10) }
        .help(help)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: status))
        .accessibilityAddTraits(.isToggle)
    }
}

extension HubToggleTile where Accessory == EmptyView {
    init(title: LocalizedStringKey, status: String, symbol: String, isOn: Bool, fill: Color, isDisabled: Bool = false,
         help: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(title: title, status: status, symbol: symbol, isOn: isOn, fill: fill, isDisabled: isDisabled,
                  help: help, action: action, accessory: { EmptyView() })
    }
}

/// Privacy Shield's tile: switches the shield, shows whether it is on and how many requests it has blocked.
struct HubPrivacyShieldTile: View {
    @ObservedObject var controller: PrivacyShieldController
    @ObservedObject private var statistics: PrivacyShieldStatistics = .shared

    var body: some View {
        HubToggleTile(
            title: "Privacy Shield",
            status: HubStatus.privacyShieldStatus(isOn: controller.isRunning, blockedRequests: statistics.totalRequestsBlocked),
            symbol: "lock.shield.fill",
            isOn: controller.isRunning,
            fill: Color(red: 0.14, green: 0.54, blue: 0.24),
            isDisabled: controller.isTransitioning,
            help: controller.isRunning
                ? "On: sites are looked up over encrypted DNS through a local proxy"
                : "Off. Turn on to look sites up over encrypted DNS through a local proxy"
        ) {
            // Same as the switch it replaces: the controller ignores a second request while it is changing state.
            controller.toggle()
        }
    }
}

/// Keep Awake's tile. A click does what the old switch did ("until turned off", or off); the clock menu in the corner
/// (and the context menu) offers the durations, apps and power-adapter modes.
struct HubKeepAwakeTile: View {
    @ObservedObject private var service: KeepAwakeService = .shared
    @ObservedObject private var settings: KeepAwakeSettings = .shared

    var body: some View {
        HubToggleTile(
            title: "Keep Awake",
            status: HubStatus.keepAwakeStatus(service.snapshot),
            symbol: "mug.fill",
            isOn: service.isActive,
            fill: Color(red: 0.70, green: 0.31, blue: 0),
            help: service.isActive
                ? "On: the Mac does not go to sleep on its own"
                : "Off. Turn on to keep the Mac from going to sleep until you turn it off",
            action: { service.toggle() },
            accessory: {
                Menu {
                    KeepAwakeModeMenuItems(service: service, settings: settings)
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(service.isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(service.isActive ? Color.white.opacity(0.25) : HubSurface.chip))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Keep the Mac awake for a while, or while apps run or the adapter is connected")
                .accessibilityLabel("Keep Awake Options")
            }
        )
        .contextMenu {
            KeepAwakeModeMenuItems(service: service, settings: settings)
        }
    }
}

// MARK: - Running app row

/// One running app: its real icon, name and memory, a thin CPU bar, the CPU figure, and a quit button that shows when
/// the pointer is on the row or the button has keyboard focus.
struct HubAppRow: View {
    let hog: ProcessTelemetry
    let isHovered: Bool
    /// " (⌘1)" for the first four rows, whose number keys quit them; empty after that.
    let shortcutHint: String
    let onQuit: () -> Void
    let onHover: (Bool) -> Void

    @FocusState private var quitIsFocused: Bool

    private func color(for level: HubGaugeLevel) -> Color {
        switch level {
        case .normal: return ZenithTheme.accent
        case .warning: return ZenithTheme.warning
        case .critical: return ZenithTheme.danger
        }
    }

    var body: some View {
        let level = HubGaugeLevel.process(cpuPercent: hog.cpuPercent)
        let showsQuit = isHovered || quitIsFocused
        HStack(spacing: 10) {
            ProcessIconView(process: hog, size: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(hog.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(HardwareTelemetryService.formatBytes(hog.memoryBytes))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Capsule()
                .fill(HubSurface.track)
                .frame(width: 54, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color(for: level))
                        .frame(width: max(2, 54 * HubStatus.processBarFraction(cpuPercent: hog.cpuPercent)), height: 4)
                }
                .accessibilityHidden(true)

            Text(verbatim: HubStatus.processCPUText(percent: hog.cpuPercent))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(color(for: level)))
                .frame(width: 48, alignment: .trailing)

            Button(action: onQuit) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isHovered ? AnyShapeStyle(ZenithTheme.danger) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(HubSurface.chip))
            }
            .buttonStyle(.plain)
            .focused($quitIsFocused)
            .opacity(showsQuit ? 1 : 0)
            // Invisible, it must not take clicks meant for the row; it still takes keyboard focus, which shows it.
            .allowsHitTesting(showsQuit)
            .animation(.easeOut(duration: 0.15), value: showsQuit)
            .help("Quit \(hog.name)\(shortcutHint); asks first")
            .accessibilityLabel("Quit \(hog.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovered ? ZenithTheme.surfaceRaised : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .help(Text(verbatim: "\(hog.name), PID \(hog.pid)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(hog.name), \(Int(round(hog.cpuPercent))) percent CPU, \(HardwareTelemetryService.formatBytes(hog.memoryBytes))"))
        .accessibilityAction(named: Text("Quit \(hog.name)"), onQuit)
        .onHover(perform: onHover)
    }
}

// MARK: - Footer buttons

/// A 38 pt round module button with a symbol (Settings, Quit).
struct HubCircleButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let help: LocalizedStringKey
    let isHovered: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(isHovered ? ZenithTheme.surfaceHover : Color.clear))
                .hubCapsule()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .onHover(perform: onHover)
    }
}
