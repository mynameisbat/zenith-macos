import SwiftUI
import ZenithCore

// Building blocks for the Settings tabs, shaped like System Settings: a scrolling page of grouped sections, each a
// rounded box of rows (title and explanation on the left, the control on the right) with hairlines between them.

/// The scrolling page a Settings tab is laid out on.
struct ZenithSettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

/// A section title: small, semibold, secondary, above its card.
struct ZenithSettingsHeader: View {
    let title: Text

    init(_ titleKey: LocalizedStringKey) {
        self.title = Text(titleKey)
    }

    init(text: Text) {
        self.title = text
    }

    var body: some View {
        title
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A titled group of rows in one rounded box, with an optional explanation under it.
struct ZenithSettingsSection<Content: View>: View {
    let title: Text?
    let footer: Text?
    let content: Content

    init(_ titleKey: LocalizedStringKey? = nil, footer footerKey: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = titleKey.map { Text($0) }
        self.footer = footerKey.map { Text($0) }
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                ZenithSettingsHeader(text: title)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .zenithSettingsCard(cornerRadius: ZenithSettingsMetrics.cardRadius, padding: 0)
            if let footer {
                footer
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a section: an optional colored icon, a title with an optional explanation, and a trailing control.
struct ZenithSettingsRow<Trailing: View>: View {
    let title: Text
    let subtitle: Text?
    let symbol: String?
    let tint: Color
    let trailing: Trailing

    init(
        _ titleKey: LocalizedStringKey,
        subtitle subtitleKey: LocalizedStringKey? = nil,
        symbol: String? = nil,
        tint: Color = ZenithTint.general,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: Text(titleKey), subtitle: subtitleKey.map { Text($0) }, symbol: symbol, tint: tint, trailing: trailing)
    }

    /// For text built at run time: pass `Text(verbatim:)` (already localized) or any `Text`.
    init(
        title: Text,
        subtitle: Text? = nil,
        symbol: String? = nil,
        tint: Color = ZenithTint.general,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                ZenithIconTile(systemName: symbol, tint: tint, size: ZenithSettingsMetrics.rowIcon, cornerRatio: 0.3)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    subtitle
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            trailing
        }
        .padding(.horizontal, ZenithSettingsMetrics.rowInset)
        .padding(.vertical, 12)
    }
}

extension ZenithSettingsRow where Trailing == EmptyView {
    init(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, symbol: String? = nil, tint: Color = ZenithTint.general) {
        self.init(titleKey, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// The hairline between two rows of a section. `inset` is what callers have always passed: the default (12) is a row
/// without an icon, anything larger a row with one, so the line starts under the title text.
struct ZenithSettingsDivider: View {
    var inset: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, inset > 12 ? ZenithSettingsMetrics.rowInset + ZenithSettingsMetrics.rowIcon + 12 : ZenithSettingsMetrics.rowInset)
    }
}

/// Sizes shared by the Settings rows and their dividers.
enum ZenithSettingsMetrics {
    static let cardRadius: CGFloat = 20
    static let rowInset: CGFloat = 16
    static let rowIcon: CGFloat = 30
}

/// A small status capsule: green "Allowed", orange "Not Allowed", or a neutral note.
struct ZenithStatusBadge: View {
    enum Kind {
        case ok, warning, neutral
    }

    let text: LocalizedStringKey
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            switch kind {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(ZenithTheme.success)
            case .warning:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ZenithTheme.warning)
            case .neutral:
                EmptyView()
            }
            Text(text)
                .foregroundStyle(kind == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(.system(size: 11.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A message row inside a section (a warning or an error), with an icon.
struct ZenithSettingsNotice: View {
    /// Usually an error message from a service, already in the user's language.
    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = ZenithTheme.warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZenithSettingsMetrics.rowInset)
        .padding(.vertical, 12)
    }
}
