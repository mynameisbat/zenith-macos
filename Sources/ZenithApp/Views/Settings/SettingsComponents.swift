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
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }
}

/// A section title in the System Settings style: sentence case, semibold, primary.
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
            .foregroundStyle(.primary)
            .padding(.leading, 2)
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
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                ZenithSettingsHeader(text: title)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .zenithSettingsCard(padding: 0)
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
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                ZenithIconTile(systemName: symbol, tint: tint, size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let subtitle {
                    subtitle
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

extension ZenithSettingsRow where Trailing == EmptyView {
    init(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, symbol: String? = nil, tint: Color = ZenithTint.general) {
        self.init(titleKey, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// The hairline between two rows of a section, inset like System Settings.
struct ZenithSettingsDivider: View {
    var inset: CGFloat = 12

    var body: some View {
        Divider().padding(.leading, inset)
    }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
