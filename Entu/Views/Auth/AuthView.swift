// Sign-in screen — shown when the user has no stored token and no saved
// public database. Entu logo header above the shared `AuthOptionsColumn`
// (also used by `AddLoginMethodSheet`): a promoted Continue-with-Passkey
// pill, the remaining providers in two grouped cards (e-mail/Apple/Google
// and the Estonian ID methods), and a View-public-database link below. There is no
// passkey sign-up here: a new passkey links to nothing without an invite,
// and the app has no database creation (`PUT /new` is not ported) — passkeys
// are created through an invite in `AddLoginMethodSheet`.

import AuthenticationServices
import SwiftUI

/// Sign-in screen with a primary passkey button and grouped provider rows.
struct AuthView: View {
    @Environment(AuthService.self) private var authService
    @Environment(PasskeyService.self) private var passkeyService

    @State private var error: String?
    @State private var showingPublicEntry = false
    @State private var isProbingPublicDatabase = false

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

            AuthOptionsColumn(isAuthenticating: isAuthenticating) {
                await signIn(with: $0)
            } passkey: {
                PasskeyPillButton(isAuthenticating: isAuthenticating) {
                    await authenticate {
                        try await passkeyService.signIn()
                    }
                }
            } footer: {
                AuthLinkButton(
                    title: "browsePublicDatabase",
                    isWorking: showingPublicEntry || isProbingPublicDatabase
                ) {
                    showingPublicEntry = true
                }
                // 34 + the stack's 10pt gap = the canonical 44pt gap under
                // the provider cards.
                .padding(.top, 34)
            }

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

    /// OAuth provider rows — the passkey has its own pill above.
    private func signIn(with provider: AuthProvider) async {
        await authenticate {
            try await authService.signIn(with: provider)
        }
    }

    /// Run one sign-in attempt, surfacing failures other than the user
    /// dismissing the system sheet.
    private func authenticate(_ attempt: () async throws -> Void) async {
        error = nil
        // One attempt at a time — every auth option is disabled while a
        // sign-in (OAuth browser, passkey sheet) is pending.
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await attempt()
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

