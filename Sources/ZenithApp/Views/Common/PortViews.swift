import SwiftUI
import AppKit
import ZenithCore

/// Stopping the process behind a port from a view: confirmation dialogs, the Force Quit offer, and a toast with the
/// result. The rules and signals themselves are `PortManagerModel`'s.
@MainActor
enum PortStopActions {
    private static func confirm(_ title: String, _ message: String, _ action: String) -> Bool {
        DestructiveConfirmation.confirm(verbatimTitle: title, message: message, destructiveTitle: action)
    }

    /// Asks, sends SIGTERM, and if the process is still there after the grace period, offers Force Quit.
    static func stop(_ entry: ListeningPort, model: PortManagerModel = .shared) {
        Task { @MainActor in
            let outcome = await model.stop(entry, confirm: confirm)
            if outcome == .stillRunning {
                forceQuit(entry, model: model)
            } else {
                report(outcome, for: entry)
            }
        }
    }

    static func forceQuit(_ entry: ListeningPort, model: PortManagerModel = .shared) {
        Task { @MainActor in
            report(await model.forceQuit(entry, confirm: confirm), for: entry)
        }
    }

    private static func report(_ outcome: PortStopOutcome, for entry: ListeningPort) {
        switch outcome {
        case .stopped:
            ToastHUDController.shared.show(verbatim: String(localized: "\(entry.processName) has quit"), icon: "checkmark.circle.fill")
        case .refused(let refusal):
            ToastHUDController.shared.show(verbatim: refusal.message, icon: "hand.raised.fill")
        case .failed(let message):
            ToastHUDController.shared.show(verbatim: message, icon: "exclamationmark.triangle.fill")
        case .cancelled, .stillRunning:
            break // the row keeps offering Force Quit
        }
    }
}

/// The icon of the process behind a port: its app's icon (a helper shows its app's), otherwise a symbol tile.
struct PortProcessIcon: View {
    let entry: ListeningPort
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let icon = Self.icon(for: entry) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZenithIconTile(systemName: "network", tint: ZenithTint.network, size: size - 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: ListeningPort) -> NSImage? {
        // Screenshots show made-up processes; never put a real app's icon next to them.
        guard !ProcessIconProvider.symbolsOnly else { return nil }
        let key = "\(entry.pid):\(entry.processName)"
        if let cached = cache[key] { return cached }
        var icon: NSImage?
        if let app = NSRunningApplication(processIdentifier: entry.pid), app.bundleURL != nil {
            icon = app.icon
        } else if let bundle = entry.appBundlePath, FileManager.default.fileExists(atPath: bundle) {
            icon = NSWorkspace.shared.icon(forFile: bundle)
        }
        guard let icon else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = icon
        return icon
    }
}

/// The trailing control of a port row: Stop, a spinner while it quits, Force Quit when it did not, or a lock with
/// the reason when Zenith will not stop it.
struct PortStopControl: View {
    @ObservedObject var model: PortManagerModel
    let entry: ListeningPort
    var compact = false

    var body: some View {
        if let refusal = model.refusal(for: entry) {
            Image(systemName: "lock.fill")
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.tertiary)
                .frame(width: compact ? 18 : nil)
                .help(Text(verbatim: refusal.message))
                .accessibilityLabel(Text(verbatim: refusal.message))
        } else {
            switch model.stopStates[entry.pid] {
            case .stopping?, .forceQuitting?:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(compact ? 0.7 : 1)
                    .frame(width: compact ? 18 : nil)
                    .accessibilityLabel("Stopping")
            case .stillRunning?, .failed?:
                Button("Force Quit") {
                    PortStopActions.forceQuit(entry, model: model)
                }
                .controlSize(.small)
                .help("End \(entry.processName) at once; asks first")
            case nil:
                if compact {
                    Button {
                        PortStopActions.stop(entry, model: model)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop \(entry.processName) to free port \(String(entry.port)); asks first")
                    .accessibilityLabel("Stop \(entry.processName)")
                } else {
                    Button("Stop") {
                        PortStopActions.stop(entry, model: model)
                    }
                    .controlSize(.small)
                    .help("Ask \(entry.processName) to quit, which frees port \(String(entry.port)); asks first")
                }
            }
        }
    }
}

extension ListeningPort {
    /// "PID 4242 · All interfaces" for the second line of a row.
    var detailLine: String {
        String(localized: "PID \(String(pid)) · \(addressDescription)")
    }
}

extension SettingsTab {
    /// The tab the Settings window should show next time it appears (for opening it on a given tab from elsewhere).
    @MainActor static var pendingSelection: SettingsTab?

    /// Opens Settings on `tab`: the window's view picks it up when it appears, or at once if it is already showing.
    @MainActor static func requestSelection(_ tab: SettingsTab) {
        pendingSelection = tab
        NotificationCenter.default.post(name: .zenithSelectSettingsTab, object: nil)
    }
}

extension Notification.Name {
    static let zenithSelectSettingsTab = Notification.Name("ZenithSelectSettingsTab")
}
