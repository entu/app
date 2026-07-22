// Provider chooser completing a self-invite — the native stand-in for the
// webapp's `/{account}/invite?token=…` page that "Add Login Method" on the
// user's own entity redirects to. Signing in with any provider while the
// exchange carries the invite JWT attaches that provider as a new login
// (`GET /auth?db=…&invite=…` — see `AuthModel.handleAuthCallback`).
//
// Visual design mirrors `AuthView`: the providers in the same grouped
// hairline-separated cards (`AuthButton` rows on `cardSurface`), minus the
// promoted passkey button — a passkey is registered via `entu_passkey`,
// not invites.

import AuthenticationServices
import SwiftUI

/// Sheet listing the auth providers in `AuthView`'s grouped-card design;
/// picking one runs the regular OAuth flow with the invite token threaded
/// through the token exchange.
struct AddLoginMethodSheet: View {
    @Environment(AuthService.self) private var authService
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let inviteToken: String

    /// Database the invite belongs to. nil (the self-invite path) falls
    /// back to the active database; the invite deep link passes the slug
    /// from the URL — the user may not even be signed in yet.
    var databaseId: String?

    /// Header title override — the invite deep link uses the webapp invite
    /// page's "You have been invited…" wording; nil keeps "Add Login Method".
    var title: String?

    /// Subtitle (disclaimer) override — the invite deep link passes the
    /// "accept your invitation" wording; nil keeps the add-login-method
    /// wording for the self-invite path.
    var subtitle: String?

    /// Fires after a provider flow completes the invite — the self-invite
    /// caller refetches the entity, the deep-link caller selects the
    /// invited database.
    var onCompleted: () -> Void

    @State private var error: String?

    /// True while a sign-in attempt is pending — disables every provider
    /// row so a second attempt can't start mid-flight (same model as
    /// `AuthView`; the active row's `AuthButton` shows its own spinner).
    @State private var isAuthenticating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                SheetHeader(title: headerTitle, subtitle: headerSubtitle)
                #endif

                ScrollView {
                    VStack(spacing: CardMetrics.gap) {
                        AuthProviderCard(group: .main) { await signIn(with: $0) }
                        AuthProviderCard(group: .estonian) { await signIn(with: $0) }
                    }
                    .disabled(isAuthenticating)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }

                if let error {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }
            }
            .background(Color("WindowBackground"))
            .sheetNavigationTitle(headerTitle, subtitle: headerSubtitle)
            .blocksCommandPalette()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton(isDisabled: isAuthenticating) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #else
        // Standard centered form sheet, same policy as `TypePickerSheet`.
        .presentationSizing(.form)
        #endif
        .appLanguageScoped()
    }

    private var headerTitle: String {
        title ?? String(localized: "addLoginMethod", bundle: .currentLocalized)
    }

    /// The disclaimer rides in the title's subtitle slot — same pattern as
    /// `EntityEditView`'s entity-name subtitle.
    private var headerSubtitle: String {
        subtitle ?? String(localized: "addLoginMethodDescription", bundle: .currentLocalized)
    }

    private func signIn(with provider: AuthProvider) async {
        error = nil
        // One attempt at a time — every provider row is disabled while a
        // sign-in is pending.
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await authService.signIn(with: provider, invite: inviteToken, databaseId: databaseId ?? api.databaseId)
            onCompleted()
            dismiss()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // User dismissed the OAuth browser — not an error
        } catch is CancellationError {
            // Rapid double-tap cancelled the prior pending session — not an error
        } catch {
            self.error = error.localizedDescription
        }
    }
}
