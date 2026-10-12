// Reusable building blocks for the auth and database-picker screens: the
// shared auth options column (passkey pill, provider cards, footer) used by
// `AuthView` and `AddLoginMethodSheet`, provider rows, and the quiet link
// button for secondary actions.

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

/// Scrolling content column of the auth option screens — the passkey section,
/// the canonical 44pt section gap, then the two grouped provider cards and an
/// optional footer. Shared by the sign-in screen (`AuthView`) and the invite
/// sheet (`AddLoginMethodSheet`) so both keep identical spacing and widths.
struct AuthOptionsColumn<Passkey: View, Footer: View>: View {
    /// True while any attempt is pending — locks the provider cards and the
    /// footer (the passkey section manages its own disabled state).
    let isAuthenticating: Bool

    let signIn: (AuthProvider) async -> Void
    @ViewBuilder let passkey: () -> Passkey
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(spacing: CardMetrics.gap) {
                passkey()
                    // 34 + the stack's 10pt gap = the canonical 44pt
                    // section gap above the provider cards.
                    .padding(.bottom, 34)

                VStack(spacing: CardMetrics.gap) {
                    AuthProviderCard(group: .main, signIn: signIn)
                    AuthProviderCard(group: .estonian, signIn: signIn)
                    footer()
                }
                .disabled(isAuthenticating)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            // Canonical 44pt section gap below the title block.
            .padding(.top, 44)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollFadeMask()
    }
}

extension AuthOptionsColumn where Footer == EmptyView {
    /// Column without a footer below the provider cards.
    init(
        isAuthenticating: Bool,
        signIn: @escaping (AuthProvider) async -> Void,
        @ViewBuilder passkey: @escaping () -> Passkey
    ) {
        self.init(isAuthenticating: isAuthenticating, signIn: signIn, passkey: passkey, footer: { EmptyView() })
    }
}

/// Promoted glass-capsule "Continue with Passkey" pill with its own spinner
/// state. Shared by the sign-in screen (`AuthView`) and the invite sheet
/// (`AddLoginMethodSheet`).
struct PasskeyPillButton: View {
    /// True while any attempt is pending — disables the pill unless the
    /// pending attempt is its own (it then keeps its enabled look and spins).
    let isAuthenticating: Bool

    let action: () async -> Void

    @State private var isWorking = false

    var body: some View {
        Button {
            guard !isAuthenticating, !isWorking else { return }
            Task {
                isWorking = true
                await action()
                isWorking = false
            }
        } label: {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "person.badge.key.fill")
                }
                Text("continueWithPasskey")
                    .fontWeight(.medium)
            }
            // Hugs its content (centered by the stack), unlike the
            // full-width provider cards.
            .frame(minHeight: 18)
            // Matches the ~44pt height of the provider rows below.
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .disabled(isAuthenticating && !isWorking)
    }
}

/// Single auth row with its own spinner state — a slow provider can't gate
/// the others. Shared by the sign-in screen (`AuthView`) and the invite
/// sheet (`AddLoginMethodSheet`); the host disables the rows while any
/// attempt is pending.
struct AuthButton<Glyph: View>: View {
    let label: LocalizedStringKey
    let glyph: Glyph
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
                    glyph
                }
                .foregroundStyle(.secondary)

                Text(label)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Self.verticalPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Touch rows get a taller tap target than pointer rows.
    #if os(iOS)
    private static var verticalPadding: CGFloat { 16 }
    #else
    private static var verticalPadding: CGFloat { 12 }
    #endif
}

extension AuthButton where Glyph == AuthProviderGlyph {
    /// Row for an auth provider — its label and glyph.
    init(provider: AuthProvider, action: @escaping () async -> Void) {
        self.init(label: provider.label, glyph: AuthProviderGlyph(provider: provider), action: action)
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

/// Quiet accent-colored text link for a secondary action on the auth screens
/// — "View public database" below the sign-in / database options, and
/// "Create a Passkey" under the passkey pill in the invite sheet.
struct AuthLinkButton: View {
    let title: LocalizedStringKey

    /// Drives the spinner while the action's work runs.
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
                Text(title)
                    .fontWeight(.medium)
            }
            // Explicit accent — macOS borderless buttons render the label
            // in the label color, not the tint.
            .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
    }
}
