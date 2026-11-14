import SwiftUI
import CoreGraphics
import ZenithCore

/// The annotation editor's floating toolbar, in the manner of Preview's Markup bar: tools, colors and line widths as
/// segmented groups, then undo/redo, then Copy and Save. Every control names its keyboard shortcut in its tooltip.
public struct StylingToolbarView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel

    public init(viewModel: AnnotationEditorViewModel) {
        self.viewModel = viewModel
    }

    private static var colorNames: [String] {
        [
            String(localized: "Red"), String(localized: "Orange"), String(localized: "Yellow"), String(localized: "Green"),
            String(localized: "Blue"), String(localized: "Purple"), String(localized: "White"), String(localized: "Black")
        ]
    }

    public var body: some View {
        HStack(spacing: 10) {
            group {
                toolButton(tool: .pen, icon: "pencil.tip", label: String(localized: "Pen"), shortcut: "P")
                toolButton(tool: .arrow, icon: "arrow.up.right", label: String(localized: "Arrow"), shortcut: "A")
                toolButton(tool: .rectangle, icon: "rectangle", label: String(localized: "Rectangle"), shortcut: "R")
                toolButton(tool: .text, icon: "textformat", label: String(localized: "Text"), shortcut: "T")
                toolButton(tool: .blur, icon: "checkerboard.rectangle", label: String(localized: "Pixelate"), shortcut: "B")
                toolButton(tool: .redact, icon: "rectangle.fill", label: String(localized: "Redact"), shortcut: "X")
                toolButton(tool: .crop, icon: "crop", label: String(localized: "Crop"), shortcut: "C")
            }

            group {
                ForEach(0..<PresetColors.all.count, id: \.self) { idx in
                    let name = idx < Self.colorNames.count ? Self.colorNames[idx] : String(localized: "Color \(idx + 1)")
                    colorSwatch(color: PresetColors.all[idx], name: name, shortcut: "\(idx + 1)")
                }
            }

            group {
                strokeButton(width: 2.0, label: String(localized: "Thin"), shortcut: "[")
                strokeButton(width: 4.0, label: String(localized: "Medium"), shortcut: nil)
                strokeButton(width: 8.0, label: String(localized: "Thick"), shortcut: "]")
            }

            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", label: String(localized: "Undo"), shortcut: "⌘Z", enabled: viewModel.commandStack.canUndo) {
                    viewModel.undo()
                }
                iconButton("arrow.uturn.forward", label: String(localized: "Redo"), shortcut: "⇧⌘Z", enabled: viewModel.commandStack.canRedo) {
                    viewModel.redo()
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Button {
                    viewModel.saveToDisk(parentWindow: nil)
                } label: {
                    Text("Save…")
                }
                .help("Save as PNG or JPEG (⌘S)")

                Button {
                    viewModel.copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy the annotated image and close (⌘C)")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 16, x: 0, y: 6)
    }

    /// A rounded well holding one group of choices.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func toolButton(tool: AnnotationTool, icon: String, label: String, shortcut: String) -> some View {
        let isSelected = viewModel.selectedTool == tool
        return Button(action: { viewModel.selectedTool = tool }) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? ZenithTheme.accent : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func colorSwatch(color: CGColor, name: String, shortcut: String) -> some View {
        let isSelected = viewModel.selectedColor == color
        return Button(action: { viewModel.selectedColor = color }) {
            ZStack {
                Circle()
                    .fill(Color(cgColor: color))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                if isSelected {
                    Circle()
                        .strokeBorder(ZenithTheme.accent, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 24, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name) (\(shortcut))")
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func strokeButton(width: CGFloat, label: String, shortcut: String?) -> some View {
        let isSelected = viewModel.selectedStrokeWidth == width
        let helpText = shortcut.map { String(localized: "\(label), \(Int(width)) pt (\($0))") } ?? String(localized: "\(label), \(Int(width)) pt")
        return Button(action: { viewModel.selectedStrokeWidth = width }) {
            Capsule()
                .fill(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(width: 16, height: max(1.5, width * 0.75))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? ZenithTheme.accent : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("\(label) line")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func iconButton(_ symbol: String, label: String, shortcut: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
    }
}
