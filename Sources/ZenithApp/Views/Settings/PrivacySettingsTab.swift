import SwiftUI
import AppKit
import ZenithCore

@MainActor
public final class PrivacyTabViewModel: ObservableObject {
    public static let shared = PrivacyTabViewModel()

    public enum ProviderType: String, CaseIterable, Identifiable {
        case cloudflare = "Cloudflare (1.1.1.1)"
        case adguard = "AdGuard DNS"
        case google = "Google Public DNS"
        case quad9 = "Quad9 (9.9.9.9)"
        case nextdns = "NextDNS"
        case custom = "Custom DoH"

        public var id: String { rawValue }

        /// The name shown in the menu.
        public var title: String {
            self == .custom ? String(localized: "Custom DoH") : rawValue
        }
    }

    @Published public var selectedProviderType: ProviderType = .cloudflare
    @Published public var nextDNSProfileID: String = ""
    @Published public var customURLString: String = "https://dns.quad9.net/dns-query"
    @Published public var customBootstrapIP: String = ""
    @Published public var newBlockedDomain: String = ""
    @Published public var newAllowedDomain: String = ""
    /// The last thing the tracker-blocking card has to say about what the user did (a rejected name, an import result).
    @Published public var trackerMessage: String? = nil
    /// Why the typed resolver was not applied, when it was not.
    @Published public var providerMessage: String? = nil

    public init() {}
}

public struct PrivacySettingsTab: View {
    typealias ProviderType = PrivacyTabViewModel.ProviderType

    @ObservedObject public var controller: PrivacyShieldController = .shared
    @ObservedObject public var stats: PrivacyShieldStatistics = .shared
    @ObservedObject public var tabModel: PrivacyTabViewModel = .shared
    @ObservedObject private var blocking: TrackerBlockingSettings

    public init(blocking: TrackerBlockingSettings = .shared) {
        self.blocking = blocking
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Master Activation Card
                activationCard

                // 2. Tracker blocking
                trackerCard

                // 3. Real-time Telemetry & Live Monitor
                telemetryCard

                // 3. Live Traffic Inspector Card
                liveInspectorCard

                // 4. DoH Configuration Card
                configurationCard

                // 5. Diagnostic Self-Test Card
                diagnosticCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .onAppear {
            syncFromCurrentProvider()
        }
    }

    // MARK: - Tracker blocking

    /// The second layer: a resolver that blocks ads itself (AdGuard DNS, a NextDNS profile). Zenith turns its
    /// `0.0.0.0` answers into the same 403 as its own list, and asks an unfiltered resolver for Never Block names.
    @ViewBuilder
    private var dnsFilteringRow: some View {
        let provider = controller.statistics.selectedProvider
        if provider.blocksAdsItself {
            Label {
                Text("\(provider.displayName) also blocks ads and trackers, with a list it keeps up to date. Its blocks are counted here, and Never Block applies to it too.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield")
                    .foregroundColor(.green)
            }
        } else if case .custom = provider {
            // A custom resolver may be the user's own filter (AdGuard Home, Pi-hole): no AdGuard offer over it.
            Label {
                Text("If your custom resolver filters ads, its blocks are counted here too, and Never Block applies to it.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "shield")
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block More with AdGuard DNS")
                        .font(.system(size: 12, weight: .medium))
                    Text("AdGuard DNS answers ad and tracker names with nothing, from a long list it keeps up to date, so nothing has to be downloaded here. Like any resolver, it sees the names you look up.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Use AdGuard DNS") {
                    controller.updateProvider(.adguard)
                    syncFromCurrentProvider()
                }
                .controlSize(.small)
            }
        }
    }

    private var trackerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZenithSettingsHeader("Tracker Blocking")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Block Ads and Trackers")
                            .font(.system(size: 12, weight: .medium))
                        Text("Refuses connections to the domains on your lists before any lookup is made for them, and to the ones a filtering resolver blocks. It applies to apps that use the system proxy, and only while Privacy Shield is on.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Block Ads and Trackers", isOn: $blocking.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if blocking.isEnabled {
                    divider

                    HStack {
                        Text(domainCountText(blocking.activeDomainCount))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                        Spacer()
                        Text(stats.totalRequestsBlocked == 1
                             ? String(localized: "1 request refused")
                             : String(localized: "\(stats.totalRequestsBlocked) requests refused"))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    if !controller.isRunning {
                        Label("Turn on Privacy Shield above for blocking to take effect.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }

                    if blocking.activeDomainCount == 0,
                       !controller.statistics.selectedProvider.blocksAdsItself,
                       !isCustomProvider(controller.statistics.selectedProvider) {
                        // Since the built-in list went away, a switch that is on can block nothing at all.
                        Label("Nothing is blocked: your lists are empty and this resolver does not filter ads. Use AdGuard DNS below, or import a list.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    divider
                    dnsFilteringRow

                    divider

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Domain List")
                                .font(.system(size: 12, weight: .medium))
                            if let name = blocking.importedListName {
                                Text(importedListText(name: name, count: blocking.importedDomainCount))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("No list imported. Import a hosts file, or use a filtering resolver.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if blocking.importedListName != nil {
                            Button("Remove") {
                                blocking.removeImportedList()
                                tabModel.trackerMessage = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button("Import List…") { chooseListFile() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    domainListEditor(
                        title: "Always Block",
                        placeholder: "ads.example.com",
                        text: $tabModel.newBlockedDomain,
                        domains: blocking.customDomains,
                        add: { addDomain(tabModel.newBlockedDomain, allow: false) },
                        remove: { blocking.removeCustomDomain($0) }
                    )

                    neverBlockEditor
                    trackerMessageText
                } else if controller.statistics.selectedProvider.blocksAdsItself {
                    // The switch is off, but the resolver still filters: show that, and the override for it.
                    divider
                    dnsFilteringRow
                    neverBlockEditor
                    trackerMessageText
                }
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 12)
        }
    }

    private func isCustomProvider(_ provider: DoHProvider) -> Bool {
        if case .custom = provider { return true }
        return false
    }

    /// Never Block also wins over a filtering resolver, so it is shown whenever one is in use, switch on or off.
    private var neverBlockEditor: some View {
        domainListEditor(
            title: "Never Block",
            placeholder: "example.com",
            text: $tabModel.newAllowedDomain,
            domains: blocking.allowedDomains,
            add: { addDomain(tabModel.newAllowedDomain, allow: true) },
            remove: { blocking.removeAllowedDomain($0) }
        )
    }

    @ViewBuilder
    private var trackerMessageText: some View {
        if let message = tabModel.trackerMessage {
            Text(verbatim: message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    private func domainListEditor(
        title: LocalizedStringKey,
        placeholder: String,
        text: Binding<String>,
        domains: [String],
        add: @escaping () -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 6) {
                TextField(placeholder, text: text, onCommit: add)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                Button("Add", action: add)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(domains, id: \.self) { domain in
                HStack(spacing: 6) {
                    Text(verbatim: domain)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        remove(domain)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel(Text("Remove \(domain)"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func domainCountText(_ count: Int) -> String {
        // With no list of its own, a "0 domains blocked" headline reads as broken while a filtering resolver blocks.
        if count == 0 { return String(localized: "No domains on your lists") }
        return count == 1 ? String(localized: "1 domain blocked") : String(localized: "\(count) domains blocked")
    }

    private func importedListText(name: String, count: Int) -> String {
        count == 1
            ? String(localized: "\(name): 1 domain")
            : String(localized: "\(name): \(count) domains")
    }

    private func addDomain(_ text: String, allow: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = allow ? blocking.addAllowedDomain(trimmed) : blocking.addCustomDomain(trimmed)
        switch result {
        case .added:
            tabModel.trackerMessage = nil
            if allow { tabModel.newAllowedDomain = "" } else { tabModel.newBlockedDomain = "" }
        case .alreadyListed(let domain):
            tabModel.trackerMessage = String(localized: "\(domain) is already in the list.")
        case .invalid:
            tabModel.trackerMessage = String(localized: "That is not a domain name Zenith can block. Use a name such as ads.example.com.")
        }
    }

    private func chooseListFile() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a hosts file or a list of domains")
        panel.prompt = String(localized: "Import")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try blocking.importList(from: url)
            tabModel.trackerMessage = count == 1
                ? String(localized: "Imported 1 domain.")
                : String(localized: "Imported \(count) domains.")
        } catch {
            tabModel.trackerMessage = error.localizedDescription
        }
    }

    private var activationCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(controller.isRunning ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(controller.isRunning ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1)
                    )
                Image(systemName: controller.isRunning ? SymbolName.shieldProtected : "shield.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(controller.isRunning ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Privacy Shield")
                        .font(.system(size: 13, weight: .semibold))
                    Text(controller.isRunning ? "On" : "Off")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(controller.isRunning ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                        )
                        .foregroundColor(controller.isRunning ? .accentColor : .secondary)
                }

                Text("Looks up site names over encrypted DNS and splits the first TLS packet of each connection. It is not a VPN and does not hide your IP address.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { controller.isRunning },
                set: { _ in controller.toggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .zenithSettingsCard(cornerRadius: 10, padding: 14)
    }

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZenithSettingsHeader("Activity")

            VStack(spacing: 8) {
                telemetryRow(
                    label: "DPI Bypassed Requests",
                    value: String(localized: "\(stats.totalRequestsProtected) requests (\(stats.formattedShieldedBytes))"),
                    icon: "lock.shield"
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                if blocking.isEnabled || stats.totalRequestsBlocked > 0 {
                    telemetryRow(
                        label: "Blocked Requests",
                        value: stats.totalRequestsBlocked == 1
                            ? String(localized: "1 request")
                            : String(localized: "\(stats.totalRequestsBlocked) requests"),
                        icon: "hand.raised"
                    )
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                }

                telemetryRow(
                    label: "DoH Resolver Latency",
                    value: stats.dohLatencyMs > 0 ? String(localized: "\(stats.dohLatencyMs) ms") : String(localized: "Untested"),
                    icon: "network"
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                telemetryRow(
                    label: "Last Protected Domain",
                    value: stats.lastProtectedDomain ?? String(localized: "None yet"),
                    icon: "globe"
                )
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 12)
        }
    }

    private func telemetryRow(label: LocalizedStringKey, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private var liveInspectorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZenithSettingsHeader("Recent Connections")

                if !stats.recentRequests.isEmpty {
                    Text("\(stats.recentRequests.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        stats.toggleRecording()
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(stats.isRecordingEnabled ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(stats.isRecordingEnabled ? "Recording" : "Paused")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    if !stats.recentRequests.isEmpty {
                        Button {
                            stats.clearRecentRequests()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                                Text("Clear")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            VStack(spacing: 0) {
                if stats.recentRequests.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: controller.isRunning ? "antenna.radiowaves.left.and.right" : "shield.slash")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.top, 14)
                        Text(controller.isRunning ? "Listening for live traffic..." : "Privacy Shield is OFF")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(controller.isRunning ? "Browse any website or run terminal requests to inspect routed traffic." : "Turn on Privacy Shield above to start intercepting and shielding requests.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 4) {
                            ForEach(stats.recentRequests) { req in
                                requestLogRow(req)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 180)
                }
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 0)
        }
    }

    private func requestLogRow(_ req: PrivacyRequestLogRecord) -> some View {
        HStack(spacing: 8) {
            // Timestamp
            Text(req.formattedTime)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)

            // Domain & Port
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(req.domain)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(verbatim: ":\(req.port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if let ip = req.resolvedIP {
                    Text("DoH → \(ip)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer()

            // Status Badge
            statusBadge(for: req)

            // Bytes
            Text(req.formattedBytes)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
    }

    private func statusBadge(for req: PrivacyRequestLogRecord) -> some View {
        let (bg, fg, border, title): (Color, Color, Color, String) = {
            switch req.status {
            case .shielded:
                return (
                    Color.accentColor.opacity(0.12),
                    Color.accentColor,
                    Color.accentColor.opacity(0.25),
                    req.chunkSize > 0 ? String(localized: "SHIELDED (\(req.chunkSize)B)") : String(localized: "SHIELDED")
                )
            case .plain:
                return (
                    Color.primary.opacity(0.06),
                    Color.secondary,
                    Color.primary.opacity(0.1),
                    req.protocolType
                )
            case .blocked:
                return (
                    Color.orange.opacity(0.14),
                    Color.orange,
                    Color.orange.opacity(0.3),
                    String(localized: "BLOCKED")
                )
            case .failed:
                return (
                    Color.red.opacity(0.12),
                    Color.red,
                    Color.red.opacity(0.25),
                    String(localized: "FAILED")
                )
            }
        }()

        return Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(border, lineWidth: 0.8)
            )
            .foregroundColor(fg)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZenithSettingsHeader("DNS-over-HTTPS Server")

            VStack(alignment: .leading, spacing: 10) {
                Picker("Resolver Provider", selection: Binding(
                    get: { tabModel.selectedProviderType },
                    set: { newType in
                        tabModel.selectedProviderType = newType
                        applyProviderChange()
                    }
                )) {
                    ForEach(ProviderType.allCases) { type in
                        Text(verbatim: type.title).tag(type)
                    }
                }
                .pickerStyle(.menu)

                if tabModel.selectedProviderType == .nextdns {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profile ID:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        // Applied when editing ends (Return, Tab, or clicking away), not on every key: a half-typed ID
                        // would otherwise become the live resolver and break browsing until the typing was done.
                        TextField("e.g. 2b489c", text: $tabModel.nextDNSProfileID, onCommit: applyProviderChange)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    .padding(.top, 2)
                }

                if tabModel.selectedProviderType == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DoH URL:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("https://example.com/dns-query", text: $tabModel.customURLString, onCommit: applyProviderChange)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Bootstrap IP (Optional):")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("e.g. 9.9.9.9", text: $tabModel.customBootstrapIP, onCommit: applyProviderChange)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    .padding(.top, 2)
                }

                Text(controller.statistics.selectedProvider.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)

                if let message = tabModel.providerMessage {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Local Proxy Endpoint:")
                            .font(.system(size: 12))
                        Spacer()
                        HStack(spacing: 4) {
                            Text("127.0.0.1 :")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)

                            if controller.isRunning {
                                Text(verbatim: "\(stats.port)")
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            } else {
                                TextField("Port", value: $stats.port, format: .number.grouping(.never))
                                    .frame(width: 58)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .monospacedDigit()
                            }
                        }
                    }

                    if controller.isRunning {
                        Text("Stop Privacy Shield to reconfigure local proxy port.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    } else {
                        HStack(spacing: 6) {
                            Text("Common Ports:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            Button("8080") { stats.port = 8080 }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                            Button("8085") { stats.port = 8085 }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                            Button("1080") { stats.port = 1080 }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                }
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 12)
        }
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZenithSettingsHeader("Check That It Works")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automated Connectivity Probe")
                            .font(.system(size: 12, weight: .medium))
                        Text("Send sample requests through the local proxy to verify DoH resolution and TLS bypass.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        Task {
                            await controller.runDiagnosticTest()
                        }
                    } label: {
                        if controller.isDiagnosticRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                Text("Run Test")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isDiagnosticRunning)
                }

                if let message = controller.diagnosticMessage {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)

                    HStack(spacing: 6) {
                        Image(systemName: message.contains("✔") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(message.contains("✔") ? .accentColor : .red)
                        Text(message)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 12)
        }
    }

    private func syncFromCurrentProvider() {
        switch controller.statistics.selectedProvider {
        case .cloudflare:
            tabModel.selectedProviderType = .cloudflare
        case .adguard:
            tabModel.selectedProviderType = .adguard
        case .google:
            tabModel.selectedProviderType = .google
        case .quad9:
            tabModel.selectedProviderType = .quad9
        case .nextdns(let profileID):
            tabModel.selectedProviderType = .nextdns
            tabModel.nextDNSProfileID = profileID
        case .custom(let url, let bootstrapIP):
            tabModel.selectedProviderType = .custom
            tabModel.customURLString = url.absoluteString
            tabModel.customBootstrapIP = bootstrapIP ?? ""
        }
    }

    private func applyProviderChange() {
        let newProvider: DoHProvider
        switch tabModel.selectedProviderType {
        case .cloudflare:
            newProvider = .cloudflare
        case .adguard:
            newProvider = .adguard
        case .google:
            newProvider = .google
        case .quad9:
            newProvider = .quad9
        case .nextdns:
            guard let provider = DoHProvider.nextDNS(profileID: tabModel.nextDNSProfileID) else {
                tabModel.providerMessage = String(localized: "A NextDNS profile ID has only letters and numbers. The resolver was not changed.")
                return
            }
            newProvider = provider
        case .custom:
            guard let provider = DoHProvider.custom(urlString: tabModel.customURLString, bootstrapIP: tabModel.customBootstrapIP) else {
                tabModel.providerMessage = String(localized: "The custom resolver needs an https:// address (and an IP address if you fill in the bootstrap field). The resolver was not changed.")
                return
            }
            newProvider = provider
        }
        tabModel.providerMessage = nil
        controller.updateProvider(newProvider)
    }
}
