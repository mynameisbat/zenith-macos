import AppKit
import SwiftUI
import ZenithCore

/// Settings → General → Screen Recording: where recordings go, the file format and the GIF size. The switches for
/// sound, pointer, clicks, frame rate and countdown sit in the bar shown before each recording.
struct ScreenRecordingSettingsSection: View {
    @ObservedObject var settings: ScreenRecordingSettings

    init(settings: ScreenRecordingSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        ZenithSettingsSection(
            "Screen Recording",
            footer: "Press ⌃⌥R (or choose Record Screen… in the menu bar menu) to record an area, a window or the whole screen; press it again or click the stop button in the menu bar to finish. Sound, microphone, pointer and countdown are set in the bar shown before recording."
        ) {
            ZenithSettingsRow(
                title: Text("Save To"),
                subtitle: Text(verbatim: settings.saveFolder.path),
                symbol: "folder.fill",
                tint: ZenithTint.screen
            ) {
                Picker("Save To", selection: saveLocationBinding) {
                    Text("Movies").tag(RecordingSaveLocation.movies)
                    Text("Desktop").tag(RecordingSaveLocation.desktop)
                    Text("Other Folder…").tag(RecordingSaveLocation.custom)
                }
                .labelsHidden()
                .fixedSize()
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "Video Format",
                subtitle: "HEVC files are smaller; H.264 plays everywhere.",
                symbol: "film.fill",
                tint: ZenithTint.screen
            ) {
                HStack(spacing: 6) {
                    Picker("File Type", selection: $settings.format) {
                        Text(verbatim: "MOV").tag(RecordingFileFormat.mov)
                        Text(verbatim: "MP4").tag(RecordingFileFormat.mp4)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Codec", selection: $settings.codec) {
                        Text(verbatim: "H.264").tag(RecordingVideoCodec.h264)
                        Text(verbatim: "HEVC").tag(RecordingVideoCodec.hevc)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            ZenithSettingsDivider(inset: 44)

            ZenithSettingsRow(
                "GIF Export",
                subtitle: "Width and frames per second of an exported GIF. Smaller GIFs are easier to share.",
                symbol: "photo.stack.fill",
                tint: ZenithTint.screen
            ) {
                HStack(spacing: 10) {
                    Stepper(value: $settings.gifMaxWidth, in: GIFExportOptions.widthRange, step: 80) {
                        Text("\(String(settings.gifMaxWidth)) px wide")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                    }
                    Stepper(value: $settings.gifFrameRate, in: GIFExportOptions.frameRateRange) {
                        Text("\(settings.gifFrameRate) fps")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Choosing "Other Folder…" asks for the folder; cancelling keeps the previous choice.
    private var saveLocationBinding: Binding<RecordingSaveLocation> {
        Binding(
            get: { settings.saveLocation },
            set: { newValue in
                guard newValue == .custom else {
                    settings.saveLocation = newValue
                    return
                }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = String(localized: "Choose")
                panel.directoryURL = settings.saveFolder
                if panel.runModal() == .OK, let url = panel.url {
                    settings.customFolder = url
                    settings.saveLocation = .custom
                }
            }
        )
    }
}
