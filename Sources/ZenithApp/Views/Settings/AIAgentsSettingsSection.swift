import SwiftUI
import AppKit
import ZenithCore

/// Settings → Dynamic Island → AI Agents: the feature, each tool, and the "finished" notice.
struct AIAgentsSettingsSection: View {
    /// Swapped by `--render-screenshots` for made-up settings, so a published picture never shows this Mac's.
    static var settingsProvider: @MainActor () -> AIAgentSettings = { .shared }
    /// Whether a tool is on this Mac. Swapped by `--render-screenshots` so the picture does not depend on this Mac.
    static var installedProvider: @MainActor (AIAgentKind) -> Bool = { AIAgentMonitor.liveSource($0).isInstalled() }

    @ObservedObject private var settings: AIAgentSettings
    @ObservedObject private var monitor: AIAgentMonitor = .shared
    @StateObject private var tools = InstalledTools()

    /// Which tools are on this Mac, looked up when the section appears.
    final class InstalledTools: ObservableObject {
        @Published var kinds: Set<AIAgentKind> = []
    }

    init() {
        _settings = ObservedObject(wrappedValue: Self.settingsProvider())
    }

    var body: some View {
        ZenithSettingsSection(
            "AI Agents",
            footer: "Zenith reads only the token counts, times, model names and project folder names in the logs these tools keep on this Mac. Prompts and replies are never read, and nothing leaves your Mac."
        ) {
            ZenithSettingsRow(
                "Coding Agents",
                subtitle: "Show Claude Code, Codex and Antigravity at work on the island, with today's tokens and plan limits.",
                symbol: "sparkles",
                tint: Color(nsColor: .systemPurple)
            ) {
                Toggle("Coding Agents", isOn: $settings.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if settings.isEnabled {
                ForEach(AIAgentKind.allCases) { kind in
                    ZenithSettingsDivider(inset: 44)
                    toolRow(kind)
                }

                ZenithSettingsDivider(inset: 44)

                ZenithSettingsRow(
                    "Notice When Work Ends",
                    subtitle: "A notice on the island when an agent finishes a long task.",
                    symbol: "bell.badge",
                    tint: Color(nsColor: .systemRed)
                ) {
                    Toggle("Notice When Work Ends", isOn: $settings.notifyWhenFinished)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if settings.notifyWhenFinished {
                    ZenithSettingsDivider(inset: 44)
                    ZenithSettingsRow("Tasks Longer Than") {
                        HStack(spacing: 6) {
                            Text("\(settings.longTaskMinutes) min")
                                .font(.system(size: 12.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .trailing)
                            Stepper("Tasks Longer Than", value: $settings.longTaskMinutes, in: AIAgentSettings.longTaskRange)
                                .labelsHidden()
                        }
                    }
                    .padding(.leading, 32)
                }
            }
        }
        .onAppear(perform: refreshInstalled)
        .onValueChange(of: settings.isEnabled) { _ in refreshInstalled() }
    }

    private func refreshInstalled() {
        tools.kinds = Set(AIAgentKind.allCases.filter { Self.installedProvider($0) })
        AIAgentMonitor.shared.refresh()
    }

    private func toolRow(_ kind: AIAgentKind) -> some View {
        ZenithSettingsRow(
            title: Text(verbatim: kind.displayName),
            subtitle: Text(subtitle(for: kind))
        ) {
            HStack(spacing: 10) {
                status(for: kind)
                Toggle(kind.displayName, isOn: Binding(
                    get: { settings.isToolEnabled(kind) },
                    set: { settings.setTool(kind, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.leading, 32)
    }

    private func subtitle(for kind: AIAgentKind) -> LocalizedStringKey {
        switch kind {
        case .claudeCode: return "Working state, tokens and model. Claude Code does not record plan limits on this Mac."
        case .codex: return "Working state, tokens, model and plan limits with their reset time."
        case .antigravity: return "Working state, project and model. Antigravity keeps no token counts Zenith can read."
        }
    }

    @ViewBuilder
    private func status(for kind: AIAgentKind) -> some View {
        if monitor.snapshots.first(where: { $0.kind == kind })?.availability == .unreadable {
            ZenithStatusBadge(text: "Unreadable", kind: .warning)
                .help("Its logs are not in a format Zenith knows. Turn the tool off and on again after updating Zenith.")
        } else if tools.kinds.contains(kind) {
            ZenithStatusBadge(text: "Found", kind: .ok)
        } else {
            ZenithStatusBadge(text: "Not found", kind: .neutral)
        }
    }
}
