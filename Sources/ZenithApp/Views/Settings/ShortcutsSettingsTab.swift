import SwiftUI
import ZenithCore

public struct ShortcutsSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZenithSettingsPage {
            if let error = viewModel.shortcutConflictError {
                ZenithSettingsSection {
                    ZenithSettingsNotice(text: error)
                }
            }

            ZenithSettingsSection(
                "Global Shortcuts",
                footer: "Click a shortcut, then press the new keys (Escape cancels). They work in every app. Avoid ⇧⌘3 to ⇧⌘6: those are macOS's own screenshot shortcuts, and both would run."
            ) {
                shortcutRow(
                    id: HotKeyDefinition.clipboardToggleId,
                    title: String(localized: "Clipboard History"),
                    symbol: "list.clipboard.fill",
                    tint: ZenithTint.clipboard,
                    defaultPreset: HotKeyDefinition.defaultClipboard,
                    altPreset: HotKeyDefinition.alternativeClipboardOptionV
                )
                ZenithSettingsDivider(inset: 44)
                shortcutRow(
                    id: HotKeyDefinition.captureAreaId,
                    title: String(localized: "Capture Area"),
                    symbol: "crop",
                    tint: ZenithTint.capture,
                    defaultPreset: HotKeyDefinition.defaultAreaCapture,
                    altPreset: HotKeyDefinition.alternativeAreaCaptureX
                )
                ZenithSettingsDivider(inset: 44)
                shortcutRow(
                    id: HotKeyDefinition.captureFullscreenId,
                    title: String(localized: "Capture Screen"),
                    symbol: "macwindow",
                    tint: ZenithTint.screen,
                    defaultPreset: HotKeyDefinition.defaultFullscreenCapture,
                    altPreset: nil
                )
                ZenithSettingsDivider(inset: 44)
                shortcutRow(
                    id: HotKeyDefinition.captureOCRId,
                    title: String(localized: "Copy Text from Screen"),
                    symbol: "text.viewfinder",
                    tint: ZenithTint.ocr,
                    defaultPreset: HotKeyDefinition.defaultOCR,
                    altPreset: nil
                )
            }
        }
    }

    private func shortcutRow(
        id: String,
        title: String,
        symbol: String,
        tint: Color,
        defaultPreset: HotKeyDefinition,
        altPreset: HotKeyDefinition?
    ) -> some View {
        let current = viewModel.hotkey(for: id) ?? defaultPreset
        let isDefault = current.keyCode == defaultPreset.keyCode && current.carbonModifiers == defaultPreset.carbonModifiers
        let offersAlternative = altPreset.map { current.keyCode != $0.keyCode || current.carbonModifiers != $0.carbonModifiers } ?? false
        return ZenithSettingsRow(
            title: Text(verbatim: title),
            subtitle: isDefault ? nil : Text("Default: \(defaultPreset.menuStyleKeyEquivalent)"),
            symbol: symbol,
            tint: tint
        ) {
            HStack(spacing: 6) {
                // A ready-made alternative, offered only while it is not the one in use.
                if offersAlternative, let alt = altPreset {
                    Button("Use \(alt.menuStyleKeyEquivalent)") {
                        _ = viewModel.updateHotkey(alt)
                    }
                    .controlSize(.small)
                }

                if !isDefault {
                    Button {
                        viewModel.resetHotkeyToDefault(id: id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .help("Reset to \(defaultPreset.menuStyleKeyEquivalent)")
                    .accessibilityLabel("Reset to default shortcut")
                }

                InteractiveShortcutRecorderView(
                    id: id,
                    title: title,
                    currentDefinition: current,
                    onUpdate: { newDef in
                        viewModel.updateHotkey(newDef)
                    }
                )
            }
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
            Text(model.isRecording ? "Type Shortcut" : currentDefinition.menuStyleKeyEquivalent)
                .font(.system(size: 12.5, weight: model.isRecording ? .regular : .medium))
                .foregroundStyle(model.isRecording ? AnyShapeStyle(ZenithTheme.accent) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .frame(minWidth: 86)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.isRecording ? ZenithTheme.accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(model.isRecording ? ZenithTheme.accent : Color.primary.opacity(0.15), lineWidth: model.isRecording ? 1.5 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(model.isRecording ? "Press the new keys, or Escape to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("\(title) shortcut, \(currentDefinition.menuStyleKeyEquivalent)")
        .accessibilityHint(model.isRecording ? "Press the new keys, or Escape to cancel" : "Records a new shortcut")
        .onDisappear {
            model.stopRecording()
        }
    }
}
