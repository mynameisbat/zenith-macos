import SwiftUI
import ZenithCore

/// The Command Hub's matching ports: while searching ("3000", ":5432", "node") a module with the matching ports, each
/// with a Stop button. With no search it draws nothing; the count lives on `HubPortsButton` in the footer.
struct HubPortsSection: View {
    @ObservedObject var model: PortManagerModel = .shared
    @ObservedObject var hubState: ZenithCommandHubState = .shared
    let query: String
    let onShowAll: () -> Void

    private static let maxRows = 4

    var body: some View {
        let matches = query.isEmpty ? [] : PortManagerModel.filter(model.ports, query: query)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Matching Ports")
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    if matches.count > Self.maxRows {
                        Button("Show All") { onShowAll() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(ZenithTheme.accent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(matches.prefix(Self.maxRows)) { entry in
                        row(entry)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hubModule()
            .padding(.top, 10)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(entry.processName), \(entry.proto.rawValue) port \(String(entry.port))"))
    }
}

/// The footer's Listening Ports capsule: the number of distinct ports, and a chevron; opens Settings → Ports.
struct HubPortsButton: View {
    @ObservedObject var model: PortManagerModel = .shared
    @ObservedObject var hubState: ZenithCommandHubState = .shared
    let onShowAll: () -> Void

    var body: some View {
        let isHovered = hubState.hoveredFooterId == "ports"
        let distinct = Set(model.ports.map(\.port)).count
        return Button(action: onShowAll) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ZenithTheme.accent)
                Text("Listening Ports")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                if model.hasLoaded {
                    Text(verbatim: String(distinct))
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Capsule().fill(isHovered ? ZenithTheme.surfaceHover : Color.clear))
            .hubCapsule()
            .contentShape(Capsule())
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
}
