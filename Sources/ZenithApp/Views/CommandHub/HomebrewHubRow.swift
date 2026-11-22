import SwiftUI
import ZenithCore

/// A Command Hub capsule that appears only when Homebrew has packages to upgrade, and opens Settings → Homebrew.
/// It checks with `brew outdated` (read-only, fast) at most every few hours, and only if brew is installed.
struct HomebrewHubRow: View {
    @ObservedObject private var model: HomebrewManagerModel = .shared
    @ObservedObject private var hubState: ZenithCommandHubState = .shared
    let onOpen: () -> Void

    private static let checkInterval: TimeInterval = 6 * 3600

    var body: some View {
        VStack(spacing: 0) {
            if model.brewPath != nil && !model.upgradable.isEmpty {
                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        ZenithIconTile(systemName: "shippingbox.fill", tint: HomebrewSettingsTab.tint, size: 22)
                        Text("Homebrew")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(updatesText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .hubCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Review and upgrade them in Settings → Homebrew")
                .padding(.top, 10)
            }
        }
        .onAppear(perform: check)
        .onChange(of: hubState.presentationID) { _, _ in check() }
    }

    private var updatesText: LocalizedStringKey {
        let count = model.upgradable.count
        return count == 1 ? "1 update" : "\(count) updates"
    }

    private func check() {
        Task { await model.refreshOutdated(ifOlderThan: Self.checkInterval) }
    }
}
