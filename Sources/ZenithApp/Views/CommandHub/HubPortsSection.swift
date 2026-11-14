import SwiftUI
import ZenithCore

/// The Command Hub's ports: with no search, one row with the number of listening ports that opens Settings → Ports;
/// while searching ("3000", ":5432", "node"), the matching ports, each with a Stop button.
struct HubPortsSection: View {
    @ObservedObject var model: PortManagerModel = .shared
    @ObservedObject var hubState: ZenithCommandHubState = .shared
    let query: String
    let onShowAll: () -> Void

    private static let maxRows = 4

    var body: some View {
        let matches = query.isEmpty ? [] : PortManagerModel.filter(model.ports, query: query)
        if query.isEmpty {
            summaryRow
        } else if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ZenithSectionHeader("Matching Ports") {
                    if matches.count > Self.maxRows {
                        Button("Show All") { onShowAll() }
                            .buttonStyle(.plain)
                            .foregroundStyle(ZenithTheme.accent)
                    }
                }
                .padding(.bottom, 2)
                VStack(spacing: 1) {
                    ForEach(matches.prefix(Self.maxRows)) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private var summaryRow: some View {
        let isHovered = hubState.hoveredFooterId == "ports"
        let distinct = Set(model.ports.map(\.port)).count
        return Button(action: onShowAll) {
            HStack(spacing: 9) {
                ZenithIconTile(systemName: "network", tint: ZenithTint.network, size: 22)
                    .frame(width: 24, height: 24)
                Text("Listening Ports")
                    .font(.system(size: 13))
                Spacer(minLength: 6)
                if model.hasLoaded {
                    Text(verbatim: String(distinct))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .zenithRowBackground(isHovered: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See which processes listen on network ports, and stop one. Type a port number to find it here.")
        .accessibilityLabel(Text("Listening Ports, \(String(distinct))"))
        .onHover { hovering in
            if hovering {
                hubState.setHoveredFooter("ports")
            } else {
                hubState.clearHoveredFooter(ifCurrent: "ports")
            }
        }
    }

    private func row(_ entry: ListeningPort) -> some View {
        HStack(spacing: 9) {
            PortProcessIcon(entry: entry, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.processName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: entry.detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(verbatim: ":" + String(entry.port))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            PortStopControl(model: model, entry: entry, compact: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(entry.processName), \(entry.proto.rawValue) port \(String(entry.port))"))
    }
}
