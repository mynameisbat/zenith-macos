import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZenithCore

public struct AudioSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    private static var assignments: [(effect: SoundEffect, title: String, description: String)] {
        [
            (.clipboardCopy, String(localized: "Copy"), String(localized: "When something is added to the clipboard history.")),
            (.paste, String(localized: "Paste"), String(localized: "When you paste an item from the history.")),
            (.capture, String(localized: "Screen Capture"), String(localized: "When a screenshot is taken.")),
            (.colorSample, String(localized: "Color Sample"), String(localized: "When the loupe picks a color.")),
            (.pinToggle, String(localized: "Pin"), String(localized: "When an item is pinned or unpinned.")),
            (.delete, String(localized: "Delete"), String(localized: "When an item is removed from the history.")),
            (.error, String(localized: "Error"), String(localized: "When something cannot be done."))
        ]
    }

    public var body: some View {
        ZenithSettingsPage {
            ZenithSettingsSection("Sound Effects") {
                ZenithSettingsRow(
                    "Play Sound Effects",
                    subtitle: "Short sounds for copying, pasting and capturing.",
                    symbol: "speaker.wave.2.fill",
                    tint: ZenithTint.audio
                ) {
                    Toggle("Play Sound Effects", isOn: $viewModel.soundEffectsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if viewModel.soundEffectsEnabled {
                    ZenithSettingsDivider(inset: 44)
                    ZenithSettingsRow("Volume", symbol: "dial.medium.fill", tint: ZenithTint.audio) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.soundVolume) },
                                    set: { viewModel.soundVolume = Float($0) }
                                ),
                                in: 0.0...1.0
                            )
                            .frame(width: 160)
                            .accessibilityLabel("Volume")
                            .accessibilityValue("\(Int(viewModel.soundVolume * 100)) percent")
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ZenithSettingsSection("Sounds") {
                ForEach(Array(Self.assignments.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        ZenithSettingsDivider()
                    }
                    soundPickerRow(effect: entry.effect, title: entry.title, description: entry.description)
                }
            }
            .disabled(!viewModel.soundEffectsEnabled)
            .opacity(viewModel.soundEffectsEnabled ? 1 : 0.5)

            ZenithSettingsSection(
                "Your Sounds",
                footer: "Imported files are copied to ~/Library/Application Support/Zenith/Sounds and appear in every menu above."
            ) {
                ZenithSettingsRow(
                    "Import a Sound",
                    subtitle: "WAV, AIFF, M4A or MP3.",
                    symbol: "waveform",
                    tint: Color(nsColor: .systemPink)
                ) {
                    Button("Import…") {
                        importSoundFile()
                    }
                }

                ForEach(viewModel.customSounds, id: \.self) { choice in
                    ZenithSettingsDivider(inset: 44)
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(choice.displayName)
                            .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
        }
        .onAppear {
            refreshCustomSounds()
        }
    }

    private func soundPickerRow(effect: SoundEffect, title: String, description: String) -> some View {
        ZenithSettingsRow(title: Text(verbatim: title), subtitle: Text(verbatim: description)) {
            HStack(spacing: 6) {
                Picker(title, selection: Binding(
                    get: { viewModel.soundChoice(for: effect) },
                    set: { newChoice in
                        viewModel.setSoundChoice(newChoice, for: effect)
                    }
                )) {
                    Section("System Sounds") {
                        ForEach(SoundChoice.standardSystemSounds, id: \.self) { name in
                            Text(name).tag(SoundChoice.system(name: name))
                        }
                    }

                    if !viewModel.customSounds.isEmpty {
                        Section("Your Sounds") {
                            ForEach(viewModel.customSounds, id: \.self) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                    }

                    Section {
                        Text("None").tag(SoundChoice.muted)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                Button {
                    viewModel.playTestSound(effect: effect)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                }
                .controlSize(.small)
                .disabled(!viewModel.soundEffectsEnabled || viewModel.soundChoice(for: effect) == .muted)
                .help("Play")
                .accessibilityLabel("Play \(title) sound")
            }
        }
    }

    private func refreshCustomSounds() {
        viewModel.refreshCustomSounds()
    }

    private func importSoundFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.wav,
            UTType.aiff,
            UTType.mp3,
            UTType.mpeg4Audio,
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "aif")
        ].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Choose an audio file to import into Zenith"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            let targetDir = SoundChoice.customSoundsDirectoryURL
            let targetURL = targetDir.appendingPathComponent(selectedURL.lastPathComponent)

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: selectedURL.path),
                  let size = attrs[.size] as? Int64, size > 0 else {
                ToastHUDController.shared.show(
                    message: "Cannot import empty audio file",
                    icon: "exclamationmark.triangle"
                )
                return
            }

            do {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: selectedURL, to: targetURL)
                refreshCustomSounds()
                ToastHUDController.shared.show(
                    message: "Imported \(selectedURL.lastPathComponent)",
                    icon: "speaker.wave.3.fill"
                )
            } catch {
                ToastHUDController.shared.show(
                    message: "Failed to import: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle"
                )
            }
        }
    }
}
