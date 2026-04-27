// Reusable row used in sheet-style pickers — currently DatabaseListView
// (database picker) and UserSheet (account picker rows). A 24pt SF Symbol on
// the leading edge, a bold title with an optional caption-sized subtitle, and
// a chevron on the trailing edge inside a rounded translucent background.

import SwiftUI

/// Tappable row used inside the post-login database picker and the user sheet.
struct SheetRow: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
