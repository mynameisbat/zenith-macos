import AppKit
import ZenithCore

/// Runs the destructive per-app actions offered by the island shelf's context menu.
///
/// Each action says what it is about to do and waits for a yes, does the slow file work off the main thread,
/// and reports the outcome. One action runs at a time.
@MainActor
public final class IslandAppActionCoordinator {
    public static let shared = IslandAppActionCoordinator()

    private var isBusy = false

    private init() {}

    /// Moves an app and its leftovers to the Trash after the user confirms what will be removed.
    public func confirmAndUninstall(appAt url: URL, onFinished: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        isBusy = true

        Task {
            defer { isBusy = false }

            let path = url.path
            let analysis = await Task.detached(priority: .userInitiated) {
                AppUninstallerService.shared.analyzeApp(atPath: path)
            }.value
            guard let plan = analysis else {
                ToastHUDController.shared.show(message: "Can't read this app", icon: "exclamationmark.triangle")
                return
            }

            let name = plan.app.displayName
            let leftoverCount = plan.leftovers.count
            let size = SystemCleanerService.formatBytes(plan.totalReclaimableBytes)
            let related = leftoverCount == 0 ? "no related files" : "\(leftoverCount) related \(leftoverCount == 1 ? "item" : "items")"
            guard DestructiveConfirmation.confirm(
                title: "Uninstall \(name)?",
                message: "\(name) and \(related) (\(size) in total) will be moved to the Trash. You can restore them from there.",
                destructiveTitle: "Move to Trash"
            ) else { return }

            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try AppUninstallerService.shared.uninstall(plan: plan, moveToTrash: true) }
            }.value

            switch outcome {
            case .success(let freed):
                ToastHUDController.shared.show(
                    message: "Uninstalled \(name)",
                    icon: "trash.fill",
                    subtitle: "Freed \(SystemCleanerService.formatBytes(freed)) · in the Trash"
                )
                onFinished()
            case .failure(let error):
                ToastHUDController.shared.show(message: "Uninstall error", icon: "exclamationmark.triangle", subtitle: error.localizedDescription)
            }
        }
    }

    /// Strips the Intel code from a universal app after the user confirms the side effects.
    public func confirmAndSlim(appAt url: URL) {
        guard !isBusy else { return }
        isBusy = true

        Task {
            defer { isBusy = false }

            let path = url.path
            let scanned = await Task.detached(priority: .userInitiated) {
                BinarySlimmerService.shared.scanApp(atPath: path)
            }.value
            guard let plan = scanned else {
                ToastHUDController.shared.show(message: "Already native Apple Silicon binary", icon: "checkmark.seal")
                return
            }

            let name = plan.appName
            guard DestructiveConfirmation.confirm(
                title: "Remove Intel code from \(name)?",
                message: "This saves about \(SystemCleanerService.formatBytes(plan.reclaimableIntelBytes)) but changes the app: "
                    + "it is re-signed on this Mac, so its developer signature is lost and automatic updates may stop working. "
                    + "The original app is moved to the Trash, and nothing is changed if anything goes wrong. Quit \(name) first.",
                destructiveTitle: "Slim App"
            ) else { return }

            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try BinarySlimmerService.shared.slimApp(plan: plan) }
            }.value

            switch outcome {
            case .success(let saved):
                ToastHUDController.shared.show(
                    message: "Slimmed \(name)",
                    icon: "scissors",
                    subtitle: "Saved \(SystemCleanerService.formatBytes(saved)) · original in the Trash"
                )
            case .failure(let error):
                ToastHUDController.shared.show(message: "Slimming error", icon: "exclamationmark.triangle", subtitle: error.localizedDescription)
            }
        }
    }
}
