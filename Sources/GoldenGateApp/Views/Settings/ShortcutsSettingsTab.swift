import SwiftUI
import GoldenGateCore

public struct ShortcutsSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = viewModel.shortcutConflictError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    .zenithSettingsCard()
                }

                // 1. Clipboard Shortcut
                VStack(alignment: .leading, spacing: 8) {
                    Text("CLIPBOARD SHORTCUT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    shortcutRow(
                        id: HotKeyDefinition.clipboardToggleId,
                        title: "Toggle Clipboard History",
                        defaultPreset: HotKeyDefinition.defaultClipboard,
                        altPreset: HotKeyDefinition.alternativeClipboardOptionV
                    )
                    .zenithSettingsCard()
                }

                // 2. Area Screenshot Shortcut
                VStack(alignment: .leading, spacing: 8) {
                    Text("AREA SCREENSHOT SHORTCUT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    shortcutRow(
                        id: HotKeyDefinition.captureAreaId,
                        title: "Area Screen Capture",
                        defaultPreset: HotKeyDefinition.defaultAreaCapture,
                        altPreset: HotKeyDefinition.alternativeAreaCaptureX
                    )
                    .zenithSettingsCard()
                }

                // 3. Fullscreen Screenshot Shortcut
                VStack(alignment: .leading, spacing: 8) {
                    Text("FULLSCREEN SCREENSHOT SHORTCUT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    shortcutRow(
                        id: HotKeyDefinition.captureFullscreenId,
                        title: "Fullscreen Capture",
                        defaultPreset: HotKeyDefinition.defaultFullscreenCapture,
                        altPreset: nil
                    )
                    .zenithSettingsCard()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func shortcutRow(
        id: String,
        title: String,
        defaultPreset: HotKeyDefinition,
        altPreset: HotKeyDefinition?
    ) -> some View {
        let current = viewModel.hotkey(for: id) ?? defaultPreset
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(current.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()

            InteractiveShortcutRecorderView(
                id: id,
                title: title,
                currentDefinition: current,
                onUpdate: { newDef in
                    viewModel.updateHotkey(newDef)
                }
            )

            if let alt = altPreset {
                Button(alt.keyEquivalent) {
                    _ = viewModel.updateHotkey(alt)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Reset (\(defaultPreset.keyEquivalent))") {
                viewModel.resetHotkeyToDefault(id: id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}


public struct InteractiveShortcutRecorderView: View {
    public let id: String
    public let title: String
    public let currentDefinition: HotKeyDefinition
    public let onUpdate: (HotKeyDefinition) -> Bool

    @StateObject private var model = ShortcutRecorderModel()

    public init(
        id: String,
        title: String,
        currentDefinition: HotKeyDefinition,
        onUpdate: @escaping (HotKeyDefinition) -> Bool
    ) {
        self.id = id
        self.title = title
        self.currentDefinition = currentDefinition
        self.onUpdate = onUpdate
    }

    public var body: some View {
        Button {
            if model.isRecording {
                model.stopRecording()
            } else {
                model.startRecording(id: id, title: title, onUpdate: onUpdate)
            }
        } label: {
            if model.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("Type shortcut...")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
            } else {
                KeycapBadgeView(text: currentDefinition.keyEquivalent)
            }
        }
        .buttonStyle(.plain)
        .help(model.isRecording ? "Press Escape to cancel" : "Click to record a custom shortcut")
        .onDisappear {
            model.stopRecording()
        }
    }
}
