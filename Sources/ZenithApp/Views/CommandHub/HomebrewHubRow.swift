import SwiftUI
import ZenithCore

/// A Command Hub line that appears only when Homebrew has packages to upgrade, and opens Settings → Homebrew.
/// It checks with `brew outdated` (read-only, fast) at most every few hours, and only if brew is installed.
struct HomebrewHubRow: View {
    @ObservedObject private var model: HomebrewManagerModel = .shared
    @ObservedObject private var hubState: ZenithCommandHubState = .shared
    let onOpen: () -> Void

    private static let checkInterval: TimeInterval = 6 * 3600

    var body: some View {
        VStack(spacing: 0) {
            if model.brewPath != nil && !model.upgradable.isEmpty {
                Divider().padding(.horizontal, 12)
                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        ZenithIconTile(systemName: "shippingbox.fill", tint: HomebrewSettingsTab.tint, size: 20)
                        Text("Homebrew")
                            .font(.system(size: 12.5))
                        Spacer(minLength: 4)
                        Text(updatesText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("Review and upgrade them in Settings → Homebrew")
            }
        }
        .onAppear(perform: check)
        .onValueChange(of: hubState.presentationID) { _ in check() }
    }

    private var updatesText: LocalizedStringKey {
        let count = model.upgradable.count
        return count == 1 ? "1 update" : "\(count) updates"
    }

    private func check() {
        Task { await model.refreshOutdated(ifOlderThan: Self.checkInterval) }
    }
}
