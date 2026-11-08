import SwiftUI

extension View {
    /// `onChange(of:)` that hands the closure the new value only.
    ///
    /// The `{ oldValue, newValue in }` form of `onChange` needs macOS 14; the one-parameter form is deprecated there but
    /// is the only one macOS 13 has. Use this instead of `onChange` so the views build for both.
    @ViewBuilder
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ newValue: Value) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
