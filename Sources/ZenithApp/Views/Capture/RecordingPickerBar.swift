import AppKit
import SwiftUI
import ZenithCore

/// How the recording selector picks what to record, like the choices in macOS's ⇧⌘5 toolbar.
enum RecordingPickMode: String, CaseIterable {
    case screen
    case window
    case selection

    var title: LocalizedStringKey {
        switch self {
        case .screen: return "Entire Screen"
        case .window: return "Window"
        case .selection: return "Selection"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .screen: return "Record the whole screen"
        case .window: return "Record one window: click it"
        case .selection: return "Record an area: drag over it"
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "display"
        case .window: return "macwindow"
        case .selection: return "rectangle.dashed"
        }
    }

    /// The line at the top of the screen while this mode is chosen.
    var hint: String {
        switch self {
        case .screen, .selection:
            return String(localized: "Drag over the area to record. Return records the whole screen, Esc cancels.")
        case .window:
            return String(localized: "Click the window to record. Return records the whole screen, Esc cancels.")
        }
    }
}

/// The mode the recording bar shows; the selector reads it to decide what a click or a drag means.
@MainActor
final class RecordingPickerModel: ObservableObject {
    /// Remembered while Zenith runs, so the bar opens on the last choice.
    private static var lastMode: RecordingPickMode = .selection

    @Published private(set) var mode: RecordingPickMode

    var onModeChange: ((RecordingPickMode) -> Void)?
    var onEntireScreen: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        mode = Self.lastMode
    }

    func choose(_ newMode: RecordingPickMode) {
        if newMode == .screen {
            onEntireScreen?()
            return
        }
        guard newMode != mode else { return }
        objectWillChange.send()
        mode = newMode
        Self.lastMode = newMode
        onModeChange?(newMode)
    }
}

/// The bar at the bottom of the screen while choosing what to record: Cancel, then Entire Screen, Window, Selection.
struct RecordingPickerBar: View {
    @ObservedObject var model: RecordingPickerModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.onCancel?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel")

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 36)
                .padding(.horizontal, 4)

            ForEach(RecordingPickMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            // The selector shows a crosshair everywhere else.
            (inside ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    private func modeButton(_ mode: RecordingPickMode) -> some View {
        let isSelected = mode != .screen && model.mode == mode
        return Button {
            model.choose(mode)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                Text(mode.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 72, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
