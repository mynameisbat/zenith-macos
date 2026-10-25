import SwiftUI
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
    }

    @Published public var selectedProviderType: ProviderType = .cloudflare
    @Published public var nextDNSProfileID: String = ""
    @Published public var customURLString: String = "https://dns.quad9.net/dns-query"
    @Published public var customBootstrapIP: String = ""

    public init() {}
}

public struct PrivacySettingsTab: View {
    typealias ProviderType = PrivacyTabViewModel.ProviderType

    @ObservedObject public var controller: PrivacyShieldController = .shared
    @ObservedObject public var stats: PrivacyShieldStatistics = .shared
    @ObservedObject public var tabModel: PrivacyTabViewModel = .shared

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Master Activation Card
                activationCard

                // 2. Real-time Telemetry & Live Monitor
                telemetryCard

                // 3. Live Traffic Inspector Card
                liveInspectorCard

                // 4. DoH Configuration Card
                configurationCard

                // 5. Diagnostic Self-Test Card
                diagnosticCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .onAppear {
            syncFromCurrentProvider()
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
                Image(systemName: controller.isRunning ? "shield.checkered" : "shield.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(controller.isRunning ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Privacy Shield")
                        .font(.system(size: 13, weight: .semibold))
                    Text(controller.isRunning ? "ACTIVE" : "OFF")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(controller.isRunning ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                        )
                        .foregroundColor(controller.isRunning ? .accentColor : .secondary)
                }

                Text("Mask web traffic and bypass censorship via encrypted DoH and fragmented TLS SNI packets.")
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
            Text("REAL-TIME TELEMETRY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                telemetryRow(
                    label: "DPI Bypassed Requests",
                    value: "\(stats.totalRequestsProtected) requests (\(stats.formattedShieldedBytes))",
                    icon: "lock.shield"
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                telemetryRow(
                    label: "DoH Resolver Latency",
                    value: stats.dohLatencyMs > 0 ? "\(stats.dohLatencyMs) ms" : "Untested",
                    icon: "network"
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                telemetryRow(
                    label: "Last Protected Domain",
                    value: stats.lastProtectedDomain ?? "None yet",
                    icon: "globe"
                )
            }
            .zenithSettingsCard(cornerRadius: 10, padding: 12)
        }
    }

    private func telemetryRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private var liveInspectorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LIVE TRAFFIC INSPECTOR")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

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
                    Text(":\(req.port)")
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
                    req.chunkSize > 0 ? "SHIELDED (\(req.chunkSize)B)" : "SHIELDED"
                )
            case .plain:
                return (
                    Color.primary.opacity(0.06),
                    Color.secondary,
                    Color.primary.opacity(0.1),
                    req.protocolType
                )
            case .failed:
                return (
                    Color.red.opacity(0.12),
                    Color.red,
                    Color.red.opacity(0.25),
                    "FAILED"
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
            Text("DOH RESOLVER CONFIGURATION")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Resolver Provider", selection: Binding(
                    get: { tabModel.selectedProviderType },
                    set: { newType in
                        tabModel.selectedProviderType = newType
                        applyProviderChange()
                    }
                )) {
                    ForEach(ProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.menu)

                if tabModel.selectedProviderType == .nextdns {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profile ID:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("e.g. 2b489c", text: Binding(
                            get: { tabModel.nextDNSProfileID },
                            set: { val in
                                tabModel.nextDNSProfileID = val
                                applyProviderChange()
                            }
                        ))
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
                            TextField("https://example.com/dns-query", text: Binding(
                                get: { tabModel.customURLString },
                                set: { val in
                                    tabModel.customURLString = val
                                    applyProviderChange()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Bootstrap IP (Optional):")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("e.g. 9.9.9.9", text: Binding(
                                get: { tabModel.customBootstrapIP },
                                set: { val in
                                    tabModel.customBootstrapIP = val
                                    applyProviderChange()
                                }
                            ))
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
                                Text("\(stats.port)")
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
            Text("DIAGNOSTIC VERIFICATION")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

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
            newProvider = .nextdns(profileID: tabModel.nextDNSProfileID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .custom:
            let trimmed = tabModel.customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed) ?? URL(string: "https://dns.quad9.net/dns-query")!
            let boot = tabModel.customBootstrapIP.trimmingCharacters(in: .whitespacesAndNewlines)
            newProvider = .custom(url: url, bootstrapIP: boot.isEmpty ? nil : boot)
        }
        controller.updateProvider(newProvider)
    }
}
