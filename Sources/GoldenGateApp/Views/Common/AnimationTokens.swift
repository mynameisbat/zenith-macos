import SwiftUI
import GoldenGateCore

public extension Animation {
    /// Canonical GoldenGate fluid spring animation (response: 0.3, dampingFraction: 0.75, blendDuration: 0.0) (F39).
    static var goldenGateSpring: Animation {
        .spring(
            response: SpringAnimationTokens.fluidSpring.response,
            dampingFraction: SpringAnimationTokens.fluidSpring.dampingFraction,
            blendDuration: SpringAnimationTokens.fluidSpring.blendDuration
        )
    }

    /// Semantic alias for fluid spring animation across UI transitions.
    static var fluidSpring: Animation {
        goldenGateSpring
    }
}

/// Central animation token namespace for GoldenGate UI micro-interactions.
public enum GoldenGateAnimation {
    /// Canonical fluid spring animation (response: 0.3, dampingFraction: 0.75).
    public static var fluidSpring: Animation {
        .goldenGateSpring
    }
}
