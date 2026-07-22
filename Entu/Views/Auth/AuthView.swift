// Sign-in screen — shown when the user has no stored token and no saved
// public database. Entu logo header, a promoted Continue-with-Passkey pill,
// the remaining providers in two grouped cards (e-mail/Apple/Google and the
// Estonian ID methods), and a View-public-database link below.

import AuthenticationServices
import SwiftUI

/// Sign-in screen with a primary passkey button and grouped provider rows.
struct AuthView: View {
    @Environment(AuthService.self) private var authService
    @Environment(PasskeyService.self) private var passkeyService

    @State private var error: String?
    @State private var showingPublicEntry = false
    @State private var isProbingPublicDatabase = false
    @State private var isPasskeySigningIn = false

    /// True while any sign-in attempt is pending — disables every auth
    /// option so a second attempt can't start mid-flight.
    @State private var isAuthenticating = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .padding(.top, 44)
                .padding(.bottom, 14)

            VStack(spacing: 4) {
                Text("signInTitle")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("signInDescription")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)

            // MARK: - Auth options (passkey promoted first) + browse public

            ScrollView {
                VStack(spacing: CardMetrics.gap) {
                    passkeyButton
                        // 34 + the stack's 10pt gap = the canonical 44pt
                        // section gap above the provider cards.
                        .padding(.bottom, 34)

                    // Provider rows + public link lock while a sign-in
                    // attempt is pending (the passkey button manages its
                    // own disabled state to keep its spinner look).
                    VStack(spacing: CardMetrics.gap) {
                        AuthProviderCard(group: .main) { await signIn(with: $0) }
                        AuthProviderCard(group: .estonian) { await signIn(with: $0) }

                        BrowsePublicDatabaseButton(
                            isWorking: showingPublicEntry || isProbingPublicDatabase
                        ) {
                            showingPublicEntry = true
                        }
                        // Canonical 44pt gap under the provider cards.
                        .padding(.top, 34)
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

            // MARK: - Error message

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 32)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("")
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        // Design-token window background behind the fixed header and the
        // Form's scroll area alike.
        .background(Color("WindowBackground").ignoresSafeArea())
        .publicDatabaseEntry(
            isPresented: $showingPublicEntry,
            isSubmitting: $isProbingPublicDatabase
        )
        .onAppear {
            // Reset any stuck session left over from a prior attempt.
            authService.cancelPending()
        }
    }

    /// Promoted primary action — scrolls with the provider cards.
    private var passkeyButton: some View {
        Button {
            guard !isAuthenticating else { return }
            Task {
                isPasskeySigningIn = true
                await signIn(with: .passkey)
                isPasskeySigningIn = false
            }
        } label: {
            HStack(spacing: 8) {
                if isPasskeySigningIn {
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
        // Disable while ANOTHER attempt is pending; keep enabled-look
        // during its own attempt (the label shows the spinner).
        .disabled(isAuthenticating && !isPasskeySigningIn)
    }

    private func signIn(with provider: AuthProvider) async {
        error = nil
        // One attempt at a time — every auth option is disabled while a
        // sign-in (OAuth browser, passkey sheet) is pending.
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            if provider == .passkey {
                try await passkeyService.signIn()
            } else {
                try await authService.signIn(with: provider)
            }
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // User dismissed the OAuth browser — not an error
        } catch let authError as ASAuthorizationError where authError.code == .canceled {
            // User dismissed the passkey sheet — not an error
        } catch is CancellationError {
            // Rapid double-tap cancelled the prior pending session — not an error
        } catch {
            self.error = error.localizedDescription
        }
    }
}

