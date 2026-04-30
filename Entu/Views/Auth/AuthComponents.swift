// Reusable building blocks for the auth and database-picker screens.

import SwiftUI

/// Divider · localized "or" · divider, used between the auth/database
/// options and the Browse-public button below them.
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

extension View {
    /// Shared row chrome — padding, quaternary fill, 10pt rounded corners.
    func authRowStyle() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Button that opens the public-database entry alert; styled to match
/// `AuthButton` so the two flows read as one list.
struct BrowsePublicDatabaseButton: View {
    /// Drives the spinner while the surrounding modifier's API probe runs.
    var isWorking: Bool = false

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AuthRowIcon(isWorking: isWorking) {
                    Image(systemName: "globe")
                }
                Text("browsePublicDatabase")
                Spacer()
            }
            .authRowStyle()
        }
        .buttonStyle(.plain)
    }
}
