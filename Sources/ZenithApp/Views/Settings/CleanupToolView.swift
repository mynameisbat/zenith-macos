import SwiftUI
import AppKit
import ZenithCore

/// One of the Cleaner tab's extra tools: what it does, a Scan button, the tickable list, and the confirmed removal.
struct CleanupToolView: View {
    @ObservedObject var model: CleanupToolModel
    @ObservedObject var projectRoots: ProjectSearchRootsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.kind == .projects {
                rootsCard
            }

            if model.isScanning && model.candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if model.candidates.isEmpty {
                Text(model.hasScanned ? (model.status ?? "Nothing to clean here.") : "Press Scan to look. Nothing is removed until you confirm.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                selectionToolbar
                VStack(spacing: 2) {
                    ForEach(model.candidates) { candidate in
                        row(candidate)
                    }
                }
                .zenithSettingsCard(cornerRadius: 10, padding: 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .bold))
                    Text(model.explanation)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            if model.isScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Scan", systemImage: "arrow.clockwise").font(.system(size: 11.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isScanning || model.isCleaning)

                        Button {
                            Task { await clean() }
                        } label: {
                            if model.isCleaning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(model.movesToTrash ? "Move to Trash" : "Delete", systemImage: model.movesToTrash ? "trash" : "xmark.bin")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.selectedCandidates.isEmpty || model.isScanning || model.isCleaning)
                    }
                    if !model.selectedCandidates.isEmpty {
                        Text("\(model.selectedCandidates.count) selected · \(format(model.selectedBytes))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            if let status = model.status, !model.candidates.isEmpty || model.isCleaning {
                Text(status).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 14)
    }

    private var selectionToolbar: some View {
        let allSelected = model.selectedCandidates.count == model.candidates.count
        return HStack {
            Button {
                model.selectAll(!allSelected)
            } label: {
                Text(allSelected ? "Deselect All" : "Select All").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("\(model.selectedCandidates.count) of \(model.candidates.count) selected")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func row(_ candidate: CleanupCandidate) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setSelected(!candidate.isSelected, id: candidate.id)
            } label: {
                Image(systemName: candidate.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(candidate.isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(candidate.title), \(candidate.isSelected ? "selected" : "not selected")")

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(candidate.detail)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(format(candidate.bytes))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    // MARK: Where projects are searched

    private var rootsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Folders searched")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(ProjectPurgeService.defaultSearchRoots().map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ") + ", plus:")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            if projectRoots.custom.isEmpty {
                Text("(none added)").font(.system(size: 10.5)).foregroundColor(.secondary)
            }
            ForEach(projectRoots.custom, id: \.self) { root in
                HStack {
                    Text((root as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        projectRoots.remove(root)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop searching \(root)")
                }
            }
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 12)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Search This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectRoots.add(url.path)
    }

    // MARK: Removal

    private func clean() async {
        let freed = await model.cleanSelected { confirmation in
            DestructiveConfirmation.confirm(
                title: confirmation.title,
                message: confirmation.message,
                destructiveTitle: confirmation.actionTitle
            )
        }
        if freed > 0 {
            ToastHUDController.shared.show(message: "Freed \(format(freed))!", icon: "sparkles")
            AudioFeedbackManager.shared.playNewCopySound()
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
