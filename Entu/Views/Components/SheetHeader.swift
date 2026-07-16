// Shared sheet-title chrome. Every sheet carries the same header: an
// uppercase kicker title ("DUPLICATE") with the entity name (or other
// context) as a headline below it, per the design. macOS renders it
// in-content — macOS sheets don't render the NavigationStack's principal
// toolbar slot, and `.navigationTitle()` on sheet content leaks to the
// parent window's title. iOS uses the navigation bar via
// `sheetNavigationTitle`.

import SwiftUI

/// Uppercase kicker title + optional subtitle, hairline below — the macOS
/// in-content sheet header. `trailing` places an accessory (e.g. the
/// Parents sheet's autosave pill) on the header's right edge.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .textCase(.uppercase)
                        .font(.caption2.weight(.semibold))
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)

                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()
        }
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// iOS navigation-bar counterpart of `SheetHeader` — uppercased title
    /// (the bar has no `textCase` hook, so the string itself is uppercased)
    /// with the subtitle below. No-op on macOS, where the sheet places
    /// `SheetHeader` in its content instead.
    func sheetNavigationTitle(_ title: String, subtitle: String? = nil) -> some View {
        #if os(iOS)
        return self
            .navigationTitle(Text(verbatim: title.uppercased()))
            .navigationSubtitle(subtitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}
