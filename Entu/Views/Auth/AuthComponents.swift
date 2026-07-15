// Reusable building blocks for the auth and database-picker screens.

import SwiftUI

/// 18×18 icon (or spinner when loading) inside a 24-wide cell so labels
/// align consistently across rows.
struct AuthRowIcon<Icon: View>: View {
    let isWorking: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Group {
            if isWorking {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
            } else {
                icon()
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 24)
    }
}

/// Quiet accent-colored text link that opens the public-database entry
/// alert — the escape hatch below the sign-in / database options.
struct BrowsePublicDatabaseButton: View {
    /// Drives the spinner while the surrounding modifier's API probe runs.
    var isWorking: Bool = false

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("browsePublicDatabase")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            // Explicit accent — macOS borderless buttons render the label
            // in the label color, not the tint.
            .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
    }
}
