// Small reusable building blocks for the auth and database-picker screens.
// Both `AuthView` and `DatabaseListView` close their scroll content with the
// same OR divider followed by a "Browse public database" button — these
// helpers keep that pair in lockstep.

import SwiftUI

/// Horizontal "OR" separator: divider · localized "or" · divider.
/// Sits inside the scroll area between sign-in / database options and the
/// "Browse public database" button below it.
struct OrSeparator: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }
}

/// Provider-style button that opens the public-database entry alert.
/// Visually identical to `AuthButton` and `SheetRow` so the three flows feel
/// like one continuous list of options.
struct BrowsePublicDatabaseButton: View {
    /// Drives `Button(.disabled:)` while the surrounding view is loading.
    var isLoading: Bool = false

    /// Tapped to present the public-database entry alert (the
    /// `.publicDatabaseEntry(isPresented:)` modifier on the parent).
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .frame(width: 18, height: 18)
                    .frame(width: 24)
                Text("browsePublicDatabase")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
