// Reusable row used in sheet-style pickers — currently DatabaseListView
// (database picker) and AccountSheet (account rows). A 24pt SF Symbol on
// the leading edge, a bold title with an optional caption-sized subtitle, and
// a chevron on the trailing edge inside a rounded translucent background.

import SwiftUI

/// Tappable row used inside the post-login database picker and the user sheet.
///
/// Title and subtitle are `Text` so callers can mix `Text("key")`
/// (`LocalizedStringKey`, observes env locale) with `Text(verbatim:)` for
/// dynamic, non-localizable content like database names.
struct SheetRow: View {
    let icon: String
    let title: Text
    var subtitle: Text?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                title.fontWeight(.semibold)

                if let subtitle {
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: CardMetrics.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius)
                .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: CardMetrics.cornerRadius))
    }
}
