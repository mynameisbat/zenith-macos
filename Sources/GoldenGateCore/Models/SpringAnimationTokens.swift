import SwiftUI

/// Standardized spring micro-animation tokens for GoldenGate (Feature F39).
/// Encapsulates Apple-standard spring dynamics for micro-interactions, popups, and transitions.
public struct SpringAnimationTokens: Sendable, Equatable {
    /// Fluid Apple spring response (duration in seconds). Default: 0.3s.
    public static let response: Double = 0.3

    /// Viscous damping fraction (0.75 provides crisp settling without overshoot). Default: 0.75.
    public static let dampingFraction: Double = 0.75

    /// Blending duration between consecutive animations. Default: 0.0.
    public static let blendDuration: Double = 0.0

    /// Interactive spring parameters for responsive drag tracking
    public static let interactiveResponse: Double = 0.25
    public static let interactiveDamping: Double = 0.8

    /// Default response constant (0.3).
    public static let defaultResponse: Double = 0.3

    /// Default damping fraction constant (0.75).
    public static let defaultDampingFraction: Double = 0.75

    /// Default blend duration constant (0.0).
    public static let defaultBlendDuration: Double = 0.0

    /// Default GoldenGate spring animation
    public static let defaultSpring = Animation.spring(
        response: response,
        dampingFraction: dampingFraction,
        blendDuration: blendDuration
    )

    /// Panel presentation & dismissal spring
    public static let panelTransition = Animation.spring(
        response: response,
        dampingFraction: dampingFraction,
        blendDuration: blendDuration
    )

    /// Interactive continuous spring for sliders and drags
    public static let interactiveSpring = Animation.interactiveSpring(
        response: interactiveResponse,
        dampingFraction: interactiveDamping
    )

    /// Canonical fluid spring token instance
    public static let fluidSpring = SpringAnimationTokens(
        response: response,
        dampingFraction: dampingFraction,
        blendDuration: blendDuration
    )

    public let responseValue: Double
    public let dampingFractionValue: Double
    public let blendDurationValue: Double

    public init(
        response: Double = Self.response,
        dampingFraction: Double = Self.dampingFraction,
        blendDuration: Double = Self.blendDuration
    ) {
        self.responseValue = response
        self.dampingFractionValue = dampingFraction
        self.blendDurationValue = blendDuration
    }

    /// Accessors for instance properties if needed
    public var response: Double { responseValue }
    public var dampingFraction: Double { dampingFractionValue }
    public var blendDuration: Double { blendDurationValue }
}
