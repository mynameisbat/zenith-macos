import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZenithCore

public struct AudioSettingsTab: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Audio Feedback Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUDIO FEEDBACK")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Enable Sound Effects", isOn: $viewModel.soundEffectsEnabled)
                                .toggleStyle(.checkbox)

                            Text("Auditory cues provide tactile acoustic feedback for system events.")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }

                        if viewModel.soundEffectsEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Feedback Volume:")
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(Int(viewModel.soundVolume * 100))%")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                }

                                HStack(spacing: 8) {
                                    Image(systemName: "speaker.wave.1.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11))

                                    Slider(
                                        value: Binding(
                                            get: { Double(viewModel.soundVolume) },
                                            set: { viewModel.soundVolume = Float($0) }
                                        ),
                                        in: 0.0...1.0
                                    )

                                    Image(systemName: "speaker.wave.3.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11))
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .zenithSettingsCard()
                }

                // 2. Sound Assignments Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("SOUND ASSIGNMENTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(spacing: 10) {
                        soundPickerRow(
                            effect: .clipboardCopy,
                            title: "Clipboard Copy",
                            description: "Tactile acoustic cue emitted when copying content to clipboard."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .paste,
                            title: "Paste Selection",
                            description: "Auditory feedback when restoring an item from history."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .capture,
                            title: "Screen Capture",
                            description: "Shutter cue emitted upon completing a screenshot."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .colorSample,
                            title: "Color Sampler",
                            description: "Resonant ping when sampling colors with the Loupe magnifier."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .pinToggle,
                            title: "Pin Toggle",
                            description: "Mechanical latch cue when pinning or unpinning an item."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .delete,
                            title: "Delete Item",
                            description: "Subtle cue emitted when removing an item from history."
                        )

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                        soundPickerRow(
                            effect: .error,
                            title: "Error Boundary",
                            description: "Alert sound emitted when an invalid action occurs."
                        )
                    }
                    .zenithSettingsCard()
                }

                // 3. Audio Library Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUDIO LIBRARY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom Sound Files")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Import .wav, .aiff, .m4a, or .mp3 files into ~/Library/Application Support/Zenith/Sounds/")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button {
                                importSoundFile()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Import Sound...")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if !viewModel.customSounds.isEmpty {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Available Custom Sounds:")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                ForEach(viewModel.customSounds, id: \.self) { choice in
                                    HStack {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 11))
                                            .foregroundColor(.accentColor)
                                        Text(choice.displayName)
                                            .font(.system(size: 11.5, design: .monospaced))
                                        Spacer()
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                    .zenithSettingsCard()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onAppear {
            refreshCustomSounds()
        }
    }

    private func soundPickerRow(effect: SoundEffect, title: String, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("", selection: Binding(
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
                    Section("Custom Sounds") {
                        ForEach(viewModel.customSounds, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                }

                Section {
                    Text("Muted").tag(SoundChoice.muted)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 130, maxWidth: 160)

            Button {
                viewModel.playTestSound(effect: effect)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("Test")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!viewModel.soundEffectsEnabled || viewModel.soundChoice(for: effect) == .muted)
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
