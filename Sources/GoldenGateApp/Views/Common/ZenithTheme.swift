import SwiftUI
import AppKit

/// Central design system tokens and Apple Design Award aesthetic for Zenith 2.0.
/// Incorporates Raycast minimalist information density and macOS Sequoia Liquid Glass materiality.
public enum ZenithTheme {
    // MARK: - Brand Identity
    public static let appName = "Zenith"
    public static let appTagline = "Precision Mac Workspace"
    public static let appVersion = "2.0.0"

    // MARK: - Color Palette & Canvas Materials
    /// Deep Obsidian Canvas: blended on top of .ultraThinMaterial for authentic desktop glass depth
    public static let canvasBackground = Color(red: 0.04, green: 0.045, blue: 0.065)
    
    /// Pure pitch black (sRGB #000000) strictly reserved for Dynamic Island hardware notch alignment
    /// to guarantee Mini-LED dimming zones remain 100% off.
    public static let pureBlack = Color(nsColor: .black)

    /// Subtle surface overlays for inset hover rows and groupings
    public static let surfaceSubtle = Color.white.opacity(0.04)
    public static let surfaceHover = Color.white.opacity(0.07)
    public static let surfaceActive = Color.white.opacity(0.11)

    // MARK: - Functional Accents (Punctuation Colors)
    /// Signature Royal Indigo used strictly as functional punctuation
    public static let accent = Color(red: 0.36, green: 0.42, blue: 0.98)
    public static let accentSecondary = Color(red: 0.52, green: 0.36, blue: 0.98)
    
    public static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Semantic status colors (CleanMyMac X clarity)
    public static let success = Color(red: 0.12, green: 0.76, blue: 0.52) // Emerald Protected
    public static let warning = Color(red: 0.96, green: 0.62, blue: 0.16) // Amber Junk
    public static let danger = Color(red: 0.96, green: 0.36, blue: 0.36)

    // MARK: - Hairline & Specular Borders
    public static let hairline: CGFloat = 0.5
    public static let borderStandard: CGFloat = 1.0

    public static let hairlineColor = Color.white.opacity(0.08)
    public static let hairlineSubtle = Color.white.opacity(0.04)
    public static let specularHighlight = Color.white.opacity(0.24)

    // MARK: - Corner Radii (Apple Continuous Squircle)
    public static let radiusSmall: CGFloat = 5
    public static let radiusMedium: CGFloat = 8
    public static let radiusLarge: CGFloat = 12
    public static let radiusCard: CGFloat = 12
    public static let radiusPill: CGFloat = 20

    // MARK: - Typography & Text Colors
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.65)
    public static let textTertiary = Color.white.opacity(0.38)
}

// MARK: - View Modifiers

/// Applies the Unified Frosted Canvas background with .ultraThinMaterial base and obsidian tint.
public struct ZenithUnifiedCanvasModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    ZenithTheme.canvasBackground.opacity(0.78)
                }
            )
    }
}

/// Inset row highlight on hover / keyboard focus (Raycast style)
public struct ZenithInsetHoverRowModifier: ViewModifier {
    public var isHovered: Bool
    public var isSelected: Bool = false
    public var cornerRadius: CGFloat = ZenithTheme.radiusMedium

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? ZenithTheme.accent.opacity(0.18)
                            : (isHovered ? ZenithTheme.surfaceHover : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? ZenithTheme.accent.opacity(0.35)
                            : (isHovered ? ZenithTheme.hairlineColor : Color.clear),
                        lineWidth: ZenithTheme.hairline
                    )
            )
            .animation(.easeOut(duration: 0.12), value: isHovered || isSelected)
    }
}

/// Legacy backward compatibility for existing view calls while upgrading to sleek borderless glass.
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
                    .stroke(ZenithTheme.hairlineColor, lineWidth: ZenithTheme.hairline)
            )
    }
}

public extension View {
    func zenithUnifiedCanvas() -> some View {
        modifier(ZenithUnifiedCanvasModifier())
    }

    func zenithInsetHoverRow(isHovered: Bool, isSelected: Bool = false, cornerRadius: CGFloat = ZenithTheme.radiusMedium) -> some View {
        modifier(ZenithInsetHoverRowModifier(isHovered: isHovered, isSelected: isSelected, cornerRadius: cornerRadius))
    }

    func zenithCard(cornerRadius: CGFloat = ZenithTheme.radiusCard, padding: CGFloat = 10) -> some View {
        modifier(ZenithGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func zenithSettingsCard(cornerRadius: CGFloat = 10, padding: CGFloat = 14) -> some View {
        modifier(ZenithSettingsCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

/// Unified Preferences / Settings Card modifier matching Menu Bar aesthetic tokens
public struct ZenithSettingsCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var padding: CGFloat

    public init(cornerRadius: CGFloat = 10, padding: CGFloat = 14) {
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

