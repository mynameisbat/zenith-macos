import SwiftUI
import CoreGraphics
import GoldenGateCore

/// Floating styling toolbar for tool selection, colors, stroke widths, and export actions.
public struct StylingToolbarView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel

    public init(viewModel: AnnotationEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 1. Tool Selection Group
            HStack(spacing: 4) {
                toolButton(tool: .pen, icon: "pencil.tip", label: "Pen", shortcut: "P")
                toolButton(tool: .arrow, icon: "arrow.up.right", label: "Arrow", shortcut: "A")
                toolButton(tool: .rectangle, icon: "rectangle", label: "Rectangle", shortcut: "R")
                toolButton(tool: .text, icon: "textformat", label: "Text", shortcut: "T")
                toolButton(tool: .blur, icon: "checkerboard.rectangle", label: "Blur", shortcut: "B")
                toolButton(tool: .crop, icon: "crop", label: "Crop", shortcut: "C")
            }

            divider

            // 2. 8 Preset Color Swatches
            HStack(spacing: 6) {
                let colorNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White", "Black"]
                ForEach(0..<PresetColors.all.count, id: \.self) { idx in
                    let color = PresetColors.all[idx]
                    let name = idx < colorNames.count ? colorNames[idx] : "Color \(idx + 1)"
                    colorSwatch(color: color, name: name, shortcut: "\(idx + 1)")
                }
            }

            divider

            // 3. Stroke Width Selector (2, 4, 8 pt)
            HStack(spacing: 8) {
                strokeButton(width: 2.0, label: "Fine", shortcut: "[")
                strokeButton(width: 4.0, label: "Regular", shortcut: nil)
                strokeButton(width: 8.0, label: "Bold", shortcut: "]")
            }

            divider

            // 4. Undo / Redo Actions
            HStack(spacing: 4) {
                Button(action: { viewModel.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.commandStack.canUndo ? .primary : .secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.commandStack.canUndo)
                .help("Undo (⌘Z)")

                Button(action: { viewModel.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(viewModel.commandStack.canRedo ? .primary : .secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.commandStack.canRedo)
                .help("Redo (⇧⌘Z)")
            }

            divider

            // 5. Quick Actions: Copy (⌘C) and Save (⌘S)
            HStack(spacing: 6) {
                Button(action: { viewModel.copyToClipboard() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium))
                        Text("Copy")
                            .font(.system(size: 11.5, weight: .medium))
                        KeycapBadgeView(text: "⌘C")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.saveToDisk(parentWindow: nil) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Save")
                            .font(.system(size: 11.5, weight: .medium))
                        KeycapBadgeView(text: "⌘S")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .goldenGateMaterial(cornerRadius: 10)
    }

    private var divider: some View {
        Divider()
            .frame(height: 18)
            .opacity(0.4)
    }

    private func toolButton(tool: AnnotationTool, icon: String, label: String, shortcut: String) -> some View {
        let isSelected = viewModel.selectedTool == tool
        return Button(action: { viewModel.selectedTool = tool }) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("\(label) (\(shortcut))")
    }

    private func colorSwatch(color: CGColor, name: String, shortcut: String) -> some View {
        let isSelected = viewModel.selectedColor == color
        return Button(action: { viewModel.selectedColor = color }) {
            ZStack {
                Circle()
                    .fill(Color(cgColor: color))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))

                if isSelected {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(name) (\(shortcut))")
    }

    private func strokeButton(width: CGFloat, label: String, shortcut: String?) -> some View {
        let isSelected = viewModel.selectedStrokeWidth == width
        let helpText = shortcut != nil ? "\(label) (\(Int(width))pt) [\(shortcut!)]" : "\(label) (\(Int(width))pt)"
        return Button(action: { viewModel.selectedStrokeWidth = width }) {
            Circle()
                .fill(isSelected ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: width + 4, height: width + 4)
                .padding(4)
                .background(
                    Circle()
                        .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
