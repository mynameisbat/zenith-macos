import SwiftUI
import ZenithCore

/// Settings → Ports: which of this user's processes listen on a network port, and stopping one.
/// It reads the list when it appears and when Refresh is clicked; it never polls.
public struct PortsSettingsTab: View {
    @ObservedObject private var model: PortManagerModel

    public init(model: PortManagerModel = .shared) {
        self.model = model
    }

    public var body: some View {
        ZenithSettingsPage {
            toolbar

            ZenithSettingsSection(footer: "Only your own processes are listed: ports held by system services and other users need administrator rights to see. Zenith never stops those, nor parts of macOS.") {
                content
            }
        }
        .onAppear {
            model.refresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField("Port, process or PID", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )

            Toggle("Include UDP", isOn: $model.includesUDP)
                .toggleStyle(.checkbox)
                .help("Also list UDP sockets that are bound to a port")

            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Read the list again")
            .accessibilityLabel("Refresh")
            .disabled(model.isRefreshing)
        }
    }

    @ViewBuilder
    private var content: some View {
        let ports = model.filteredPorts
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = model.errorMessage {
            ZenithSettingsNotice(text: error)
        } else if !model.hasLoaded {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 16)
        } else if ports.isEmpty {
            Group {
                if query.isEmpty {
                    Text("None of your processes is listening on a port.")
                } else {
                    Text("No port matches \u{201C}\(query)\u{201D}")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            ForEach(Array(ports.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    ZenithSettingsDivider(inset: 44)
                }
                row(entry)
            }
        }
    }

    private func row(_ entry: ListeningPort) -> some View {
        HStack(spacing: 10) {
            PortProcessIcon(entry: entry)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.processName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: entry.detailLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: entry.proto.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

            Text(verbatim: String(entry.port))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 48, alignment: .trailing)

            PortStopControl(model: model, entry: entry)
                .frame(minWidth: 74, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(entry.processName), \(entry.proto.rawValue) port \(String(entry.port)), \(entry.addressDescription)"))
    }
}
