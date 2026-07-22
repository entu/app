// Reusable building blocks for the auth and database-picker screens.

import SwiftUI

/// Provider glyph — SF Symbol at label size or custom asset scaled to
/// fit. Shared by the sign-in rows (`AuthView`) and the invite sheet
/// (`AddLoginMethodSheet`); `AuthChip` renders its own resizable variant.
struct AuthProviderGlyph: View {
    let provider: AuthProvider

    var body: some View {
        if let symbol = provider.systemImageName {
            Image(systemName: symbol)
        } else {
            Image(provider.icon).resizable().scaledToFit()
        }
    }
}

/// One white card with a hairline-separated `AuthButton` row per provider
/// of a visual group, filtered to the current platform. Shared by the
/// sign-in screen (`AuthView`) and the invite sheet (`AddLoginMethodSheet`).
struct AuthProviderCard: View {
    let group: AuthProviderGroup
    let signIn: (AuthProvider) async -> Void

    private var providers: [AuthProvider] {
        AuthProvider.allCases.filter {
            $0.group == group && $0.isAvailableOnCurrentPlatform
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(providers, id: \.self) { provider in
                AuthButton(provider: provider) {
                    await signIn(provider)
                }

                if provider != providers.last {
                    Divider()
                }
            }
        }
        .cardSurface()
    }
}

/// Single auth-provider row with its own spinner state — a slow provider
/// can't gate the others. Shared by the sign-in screen (`AuthView`) and
/// the invite sheet (`AddLoginMethodSheet`); the host disables the rows
/// while any attempt is pending.
struct AuthButton: View {
    let provider: AuthProvider
    let action: () async -> Void

    @State private var isWorking = false

    var body: some View {
        Button {
            guard !isWorking else { return }
            Task {
                isWorking = true
                await action()
                isWorking = false
            }
        } label: {
            HStack(spacing: 10) {
                AuthRowIcon(isWorking: isWorking) {
                    AuthProviderGlyph(provider: provider)
                }
                .foregroundStyle(.secondary)

                Text(provider.label)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                // Body size — same as the passkey and provider labels.
                Text("browsePublicDatabase")
                    .fontWeight(.medium)
            }
            // Explicit accent — macOS borderless buttons render the label
            // in the label color, not the tint.
            .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
    }
}
