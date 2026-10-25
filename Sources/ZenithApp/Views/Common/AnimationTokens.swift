import SwiftUI
import ZenithCore

public extension Animation {
    /// Canonical Zenith fluid spring animation (response: 0.3, dampingFraction: 0.75, blendDuration: 0.0) (F39).
    static var zenithSpring: Animation {
        .spring(
            response: SpringAnimationTokens.fluidSpring.response,
            dampingFraction: SpringAnimationTokens.fluidSpring.dampingFraction,
            blendDuration: SpringAnimationTokens.fluidSpring.blendDuration
        )
    }

    /// Backwards compatibility alias for fluid spring animation.
    static var goldenGateSpring: Animation {
        zenithSpring
    }

    /// Semantic alias for fluid spring animation across UI transitions.
    static var fluidSpring: Animation {
        zenithSpring
    }
}

/// Central animation token namespace for Zenith UI micro-interactions.
public enum ZenithAnimation {
    /// Canonical fluid spring animation (response: 0.3, dampingFraction: 0.75).
    public static var fluidSpring: Animation {
        .zenithSpring
    }
}

public typealias GoldenGateAnimation = ZenithAnimation
