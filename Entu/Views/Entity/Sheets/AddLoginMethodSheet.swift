// Provider chooser completing an invite — the native stand-in for the
// webapp's `/{account}/invite?token=…` page. Two callers: "Add Login
// Method" on the user's own entity (self-invite) and the invite deep link.
// Signing in with any provider while the exchange carries the invite JWT
// attaches that login to the invited person (`GET /auth?db=…&invite=…`, or
// `db` + `invite` in the passkey POST bodies) — see
// `AuthModel.applyAuthResponse`.
//
// The content column is `AuthView`'s shared `AuthOptionsColumn`: the
// promoted "Continue with Passkey" pill (use a stored passkey) with a quiet
// "Create a Passkey" link directly under it, the 44pt section gap, then the
// two grouped provider cards. The sheet keeps its own chrome — navigation
// title/subtitle, close button and error line.
//
// A self-invite keeps the current session: the new login is linked
// server-side and the response's token is discarded, so finishing it with
// another identity never swaps who is signed in.

import AuthenticationServices
import SwiftUI

/// Sheet showing `AuthView`'s passkey pill and provider cards plus a
/// create-passkey link; picking one runs the regular sign-in flow with the
/// invite token threaded through the token exchange.
struct AddLoginMethodSheet: View {
    @Environment(AuthService.self) private var authService
    @Environment(PasskeyService.self) private var passkeyService
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let inviteToken: String

    /// Database the invite belongs to. nil (the self-invite path) falls
    /// back to the active database; the invite deep link passes the slug
    /// from the URL — the user may not even be signed in yet.
    var databaseId: String?

    /// True for the self-invite: complete the invite but keep the current
    /// session instead of signing in with the new login.
    var keepSession = false

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
    /// `AuthView`; the active row, pill or link shows its own spinner).
    @State private var isAuthenticating = false

    /// True while the "Create a Passkey" link's attempt is pending — drives
    /// its spinner and keeps it enabled-looking during its own attempt.
    @State private var isCreatingPasskey = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                SheetHeader(title: headerTitle, subtitle: headerSubtitle)
                #endif

                AuthOptionsColumn(isAuthenticating: isAuthenticating) {
                    await signIn(with: $0)
                } passkey: {
                    VStack(spacing: CardMetrics.gap) {
                        PasskeyPillButton(isAuthenticating: isAuthenticating) {
                            await complete {
                                try await passkeyService.signIn(invite: inviteToken, databaseId: inviteDatabaseId, keepSession: keepSession)
                            }
                        }

                        AuthLinkButton(title: "createPasskey", isWorking: isCreatingPasskey) {
                            createPasskey()
                        }
                        // Same lock rule as the pill: disabled while another
                        // attempt is pending, enabled-looking while it spins.
                        .disabled(isAuthenticating && !isCreatingPasskey)
                    }
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

    /// The invite's database — the self-invite falls back to the active one.
    private var inviteDatabaseId: String? {
        databaseId ?? api.databaseId
    }

    /// Secondary passkey action — creates a new passkey as the invite's login.
    private func createPasskey() {
        guard !isAuthenticating else { return }
        Task {
            isCreatingPasskey = true
            await complete {
                try await passkeyService.create(invite: inviteToken, databaseId: inviteDatabaseId, keepSession: keepSession)
            }
            isCreatingPasskey = false
        }
    }

    private func signIn(with provider: AuthProvider) async {
        await complete {
            try await authService.signIn(with: provider, invite: inviteToken, databaseId: inviteDatabaseId, keepSession: keepSession)
        }
    }

    /// Run one invite-completing attempt; on success report back and close.
    /// An invalid invite or a conflicting identity surfaces as the error line.
    private func complete(_ attempt: () async throws -> Void) async {
        error = nil
        // One attempt at a time — every row is disabled while a sign-in is
        // pending.
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            try await attempt()
            onCompleted()
            dismiss()
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
