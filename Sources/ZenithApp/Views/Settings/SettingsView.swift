import SwiftUI
import ZenithCore

/// Compatibility wrapper forwarding to the modern ZenithPreferencesView.
public struct SettingsView: View {
    @ObservedObject public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel = SettingsViewModel()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZenithPreferencesView(viewModel: viewModel)
    }
}
