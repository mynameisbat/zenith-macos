import SwiftUI
import ZenithCore
import AppKit

/// Design tokens for Zenith. The app follows the system: the accent is the one chosen in System Settings → Appearance,
/// text and fills are semantic so they work in Light and Dark mode, and type sizes are the macOS text styles.
/// Only the Dynamic Island has fixed colors, because it always sits on a black notch (see `ZenithTheme.Island`).
public enum ZenithTheme {
    // MARK: - Brand Identity
    public static let appName = "Zenith"
    public static let appTagline = "Precision Mac Workspace"
    public static let appVersion = ZenithVersion.current

    // MARK: - Color

    /// The user's accent color (System Settings → Appearance → Accent color).
    public static let accent = Color.accentColor
    public static let accentSecondary = Color.accentColor.opacity(0.8)

    /// Window background of a standard macOS window.
    public static let canvasBackground = Color(nsColor: .windowBackgroundColor)

    /// Pure black (sRGB #000000), only for the Dynamic Island so it blends into the camera notch.
    public static let pureBlack = Color(nsColor: .black)

    /// Fills for rows and groups, in steps (no borders needed). Semantic, so they work in both appearances.
    public static let surfaceSubtle = Color.primary.opacity(0.035)
    public static let surfaceRaised = Color.primary.opacity(0.055)
    public static let surfaceHover = Color.primary.opacity(0.07)
    public static let surfaceActive = Color.primary.opacity(0.11)

    /// The highlight a selected list row gets in AppKit (accent-tinted, white text on top).
    public static let selection = Color(nsColor: .selectedContentBackgroundColor)

    /// Fill and edge of a grouped section, as in a `.formStyle(.grouped)` form: lighter than the window in both modes.
    public static let groupedFill = Color(nsColor: NSColor(name: "ZenithGroupedFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05)
            : NSColor(white: 1, alpha: 0.72)
    })
    public static let groupedStroke = Color(nsColor: NSColor(name: "ZenithGroupedStroke") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.07)
    })

    /// System status colors; they adapt to Light/Dark mode and Increase Contrast.
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let danger = Color(nsColor: .systemRed)

    // MARK: - Lines

    public static let hairline: CGFloat = 0.5
    public static let borderStandard: CGFloat = 1.0
    public static let hairlineColor = Color(nsColor: .separatorColor)
    public static let hairlineSubtle = Color.primary.opacity(0.05)
    public static let specularHighlight = Color.white.opacity(0.16)

    // MARK: - Corner Radii (continuous)

    public static let radiusSmall: CGFloat = 5
    public static let radiusMedium: CGFloat = 7
    public static let radiusLarge: CGFloat = 10
    public static let radiusCard: CGFloat = 10
    public static let radiusPill: CGFloat = 20

    // MARK: - Text

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Spacing (4-point grid)

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 20
    }

    /// Fixed colors for the Dynamic Island, which is always drawn on black whatever the system appearance.
    public enum Island {
        public static let textPrimary = Color.white
        public static let textSecondary = Color.white.opacity(0.62)
        public static let textTertiary = Color.white.opacity(0.4)
        public static let fill = Color.white.opacity(0.08)
        public static let fillHover = Color.white.opacity(0.14)
        public static let fillActive = Color.white.opacity(0.2)
        public static let hairline = Color.white.opacity(0.1)
    }
}

// MARK: - Tinted Icon Tile

/// The colored rounded square System Settings uses for its sidebar and for app features: a white symbol on a tinted
/// gradient. Use it to give each feature a recognisable color.
public struct ZenithIconTile: View {
    public let systemName: String
    public let tint: Color
    public var size: CGFloat

    public init(systemName: String, tint: Color, size: CGFloat = 20) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.88), tint],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Named feature tints, so the same feature has the same color everywhere (Settings sidebar, Command Hub, island).
public enum ZenithTint {
    public static let capture = Color(nsColor: .systemBlue)
    public static let screen = Color(nsColor: .systemIndigo)
    public static let ocr = Color(nsColor: .systemTeal)
    public static let clipboard = Color(nsColor: .systemOrange)
    public static let general = Color(nsColor: .systemGray)
    public static let shortcuts = Color(nsColor: .systemPink)
    public static let audio = Color(nsColor: .systemRed)
    public static let privacy = Color(nsColor: .systemGreen)
    public static let cleaner = Color(nsColor: .systemPurple)
    public static let permissions = Color(nsColor: .systemBlue)
    public static let island = Color(white: 0.14)
    public static let timer = Color(nsColor: .systemOrange)
    public static let calendar = Color(nsColor: .systemRed)
}

// MARK: - Section Header

/// A small, sentence-case group title like the ones in macOS menus and System Settings, with optional trailing text.
public struct ZenithSectionHeader<Trailing: View>: View {
    public let title: Text
    public let trailing: Trailing

    /// A title from the string table.
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(titleKey)
        self.trailing = trailing()
    }

    /// A title shown as it is (already localized, or data).
    public init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
    }
}

public extension ZenithSectionHeader where Trailing == EmptyView {
    init(_ titleKey: LocalizedStringKey) {
        self.init(titleKey) { EmptyView() }
    }

    init(verbatim title: String) {
        self.init(verbatim: title) { EmptyView() }
    }
}

// MARK: - Shortcut Text

/// A keyboard shortcut drawn the way a macOS menu draws it: plain, tertiary, right-aligned, never wrapped.
public struct ZenithShortcutText: View {
    public let shortcut: String
    public var isOnSelection: Bool

    public init(_ shortcut: String, isOnSelection: Bool = false) {
        self.shortcut = shortcut
        self.isOnSelection = isOnSelection
    }

    public var body: some View {
        Text(shortcut)
            .font(.system(size: 12))
            .foregroundStyle(isOnSelection ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Shortcut \(shortcut)")
    }
}

// MARK: - Key Hint

/// One "key + what it does" hint for a footer: the key in a small keycap, the action as plain text, kept on one line.
public struct ZenithKeyHint: View {
    public let key: String
    public let label: LocalizedStringKey

    public init(_ key: String, _ label: LocalizedStringKey) {
        self.key = key
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 4) {
            KeycapBadgeView(text: key)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - View Modifiers

/// Row background for lists: the AppKit selection color when selected, a light fill on hover.
public struct ZenithRowBackgroundModifier: ViewModifier {
    public var isSelected: Bool
    public var isHovered: Bool
    public var cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? ZenithTheme.selection : (isHovered ? ZenithTheme.surfaceHover : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// Window-style background: a translucent material with the window color under it.
public struct ZenithUnifiedCanvasModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content.background(.regularMaterial)
    }
}

/// Inset row highlight on hover / keyboard focus.
public struct ZenithInsetHoverRowModifier: ViewModifier {
    public var isHovered: Bool
    public var isSelected: Bool = false
    public var cornerRadius: CGFloat = ZenithTheme.radiusMedium

    public func body(content: Content) -> some View {
        content.modifier(ZenithRowBackgroundModifier(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

/// A grouped box like the sections of a grouped `Form` in System Settings.
public struct ZenithGlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat = ZenithTheme.radiusCard
    public var padding: CGFloat = 10

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ZenithTheme.surfaceSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ZenithTheme.hairlineSubtle, lineWidth: ZenithTheme.hairline)
            )
    }
}

/// The section box used across Settings; matches a `.formStyle(.grouped)` section.
public struct ZenithSettingsCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var padding: CGFloat

    public init(cornerRadius: CGFloat = ZenithTheme.radiusCard, padding: CGFloat = 14) {
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ZenithTheme.groupedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ZenithTheme.groupedStroke, lineWidth: ZenithTheme.hairline)
            )
    }
}

public extension View {
    func zenithUnifiedCanvas() -> some View {
        modifier(ZenithUnifiedCanvasModifier())
    }

    func zenithRowBackground(isSelected: Bool = false, isHovered: Bool, cornerRadius: CGFloat = ZenithTheme.radiusMedium) -> some View {
        modifier(ZenithRowBackgroundModifier(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius))
    }

    func zenithInsetHoverRow(isHovered: Bool, isSelected: Bool = false, cornerRadius: CGFloat = ZenithTheme.radiusMedium) -> some View {
        modifier(ZenithInsetHoverRowModifier(isHovered: isHovered, isSelected: isSelected, cornerRadius: cornerRadius))
    }

    func zenithCard(cornerRadius: CGFloat = ZenithTheme.radiusCard, padding: CGFloat = 10) -> some View {
        modifier(ZenithGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func zenithSettingsCard(cornerRadius: CGFloat = ZenithTheme.radiusCard, padding: CGFloat = 14) -> some View {
        modifier(ZenithSettingsCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}
