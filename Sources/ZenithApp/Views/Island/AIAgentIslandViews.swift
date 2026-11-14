import SwiftUI
import AppKit
import ZenithCore

extension AIAgentKind {
    /// Generic system colors, one per tool, so two cards side by side are told apart at a glance.
    var tint: Color {
        switch self {
        case .claudeCode: return Color(nsColor: .systemOrange)
        case .codex: return Color(nsColor: .systemTeal)
        case .antigravity: return Color(nsColor: .systemBlue)
        }
    }
}

// MARK: - Pulsing dot

/// A small dot that breathes while an agent works. Core Animation runs it, so it costs no timer and no SwiftUI
/// redraws; with Reduce Motion it stays still.
@MainActor
final class PulsingDotLayerView: IslandWingLayerView {
    static let side: CGFloat = 7
    private static let pulseKey = "zenith.pulse"
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        dot.cornerRadius = Self.side / 2
        layer?.addSublayer(dot)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        withoutAnimation { dot.position = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    func setColor(_ color: Color) {
        withoutAnimation { dot.backgroundColor = NSColor(color).cgColor }
    }

    override func updateMotion() {
        if shouldMove {
            guard dot.animation(forKey: Self.pulseKey) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: Self.pulseKey)
        } else {
            dot.removeAnimation(forKey: Self.pulseKey)
        }
    }
}

struct AIAgentPulsingDot: NSViewRepresentable {
    let color: Color
    var isActive = true

    func makeNSView(context: Context) -> PulsingDotLayerView {
        PulsingDotLayerView(frame: NSRect(x: 0, y: 0, width: PulsingDotLayerView.side, height: PulsingDotLayerView.side))
    }

    func updateNSView(_ view: PulsingDotLayerView, context: Context) {
        view.setColor(color)
        view.isPlaying = isActive
    }

    static func dismantleNSView(_ view: PulsingDotLayerView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - Closed island

/// Beside the notch while an agent works: the tool's symbol on the left, a breathing dot on the right.
struct AIAgentCompactWings: View {
    let agent: AIAgentSnapshot
    let geometry: ZenithIslandGeometry

    var body: some View {
        HStack {
            Image(systemName: agent.kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(agent.kind.tint)
                .frame(width: 16, height: 16)
                .padding(.leading, 9)

            Spacer()

            AIAgentPulsingDot(color: agent.kind.tint)
                .frame(width: PulsingDotLayerView.side, height: PulsingDotLayerView.side)
                .padding(.trailing, 13)
        }
        .padding(.top, geometry.hasNotch ? (geometry.notchRect.height / 2 - 8) : 5)
        .frame(width: geometry.nowPlayingIdleWidth, height: geometry.nowPlayingIdleHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: agent.kind.displayName))
        .accessibilityValue(Text(verbatim: agent.statusText))
    }
}

// MARK: - Expanded island

/// The AI tab: one card per tool used today, side by side.
struct IslandAIAgentsPanel: View {
    @ObservedObject var islandState: ZenithIslandState

    var body: some View {
        let agents = Array(islandState.aiAgents.prefix(3))
        HStack(spacing: 8) {
            if agents.isEmpty {
                emptyCard
            } else {
                ForEach(agents) { agent in
                    AIAgentCard(agent: agent, compact: agents.count > 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { AIAgentMonitor.shared.recomputeNow() }
    }

    private var emptyCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(ZenithTheme.Island.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("No agent activity today")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                Text("Claude Code, Codex and Antigravity show here while they work.")
                    .font(.system(size: 10))
                    .foregroundStyle(ZenithTheme.Island.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .modifier(IslandCardBackground())
        .accessibilityElement(children: .combine)
    }
}

/// One tool: its name, whether it works and where, and the numbers its logs hold.
struct AIAgentCard: View {
    let agent: AIAgentSnapshot
    /// Two or three cards share the width: fewer details per line.
    let compact: Bool

    private var infoLine: String? {
        if compact {
            return agent.usageText ?? agent.limitsText ?? agent.model
        }
        let parts = [agent.usageText, agent.limitsText].compactMap { $0 }
        return parts.isEmpty ? agent.model : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: agent.kind.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(agent.kind.tint)
                Text(verbatim: agent.kind.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ZenithTheme.Island.textPrimary)
                    .layoutPriority(1)
                if !compact, let model = agent.model, infoLine != model {
                    Text(verbatim: model)
                        .font(.system(size: 9.5))
                        .foregroundStyle(ZenithTheme.Island.textTertiary)
                }
                Spacer(minLength: 2)
                if agent.isWorking {
                    AIAgentPulsingDot(color: agent.kind.tint)
                        .frame(width: PulsingDotLayerView.side, height: PulsingDotLayerView.side)
                }
            }
            Text(verbatim: agent.statusText)
                .font(.system(size: 10, weight: agent.isWorking ? .medium : .regular))
                .foregroundStyle(agent.isWorking ? AnyShapeStyle(agent.kind.tint) : AnyShapeStyle(ZenithTheme.Island.textSecondary))
            if let infoLine {
                Text(verbatim: infoLine)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(ZenithTheme.Island.textSecondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(IslandCardBackground())
        .help(Text(verbatim: agent.detailText(now: Date())))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: agent.kind.displayName))
        .accessibilityValue(Text(verbatim: agent.detailText(now: Date())))
    }
}
