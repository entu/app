// Provider chooser completing a self-invite — the native stand-in for the
// webapp's `/{account}/invite?token=…` page that "Add Login Method" on the
// user's own entity redirects to. Signing in with any provider while the
// exchange carries the invite JWT attaches that provider as a new login
// (`GET /auth?db=…&invite=…` — see `AuthModel.handleAuthCallback`).

import AuthenticationServices
import SwiftUI

/// Sheet listing the auth providers; picking one runs the regular OAuth
/// flow with the invite token threaded through the token exchange.
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

    /// Fires after a provider flow completes the invite — the self-invite
    /// caller refetches the entity, the deep-link caller selects the
    /// invited database.
    var onCompleted: () -> Void

    /// Provider whose flow is in flight — rows disable and the active one
    /// shows a spinner. One attempt at a time.
    @State private var signingIn: AuthProvider?
    @State private var error: String?

    /// Same catalog as the webapp's invite page — every provider except
    /// passkey (a passkey is registered via `entu_passkey`, not invites),
    /// filtered to what this platform supports.
    private var providers: [AuthProvider] {
        AuthProvider.allCases.filter { $0 != .passkey && $0.isAvailableOnCurrentPlatform }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                SheetHeader(title: headerTitle)
                #endif

                List(providers, id: \.self) { provider in
                    providerRow(provider)
                }
                .listStyle(.plain)

                if let error {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Text("addLoginMethodDescription")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .sheetNavigationTitle(headerTitle)
            .blocksCommandPalette()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton(isDisabled: signingIn != nil) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 300)
        #else
        // Standard centered form sheet, same policy as `TypePickerSheet`.
        .presentationSizing(.form)
        #endif
        .appLanguageScoped()
    }

    private var headerTitle: String {
        title ?? String(localized: "addLoginMethod", bundle: .currentLocalized)
    }

    private func providerRow(_ provider: AuthProvider) -> some View {
        Button {
            guard signingIn == nil else { return }
            Task { await signIn(with: provider) }
        } label: {
            HStack(spacing: 10) {
                AuthRowIcon(isWorking: signingIn == provider) {
                    if provider.icon.hasPrefix("sf:") {
                        Image(systemName: String(provider.icon.dropFirst(3)))
                    } else {
                        Image(provider.icon).resizable().scaledToFit()
                    }
                }
                .foregroundStyle(.secondary)

                Text(provider.label)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(signingIn != nil && signingIn != provider)
    }

    private func signIn(with provider: AuthProvider) async {
        error = nil
        signingIn = provider
        defer { signingIn = nil }

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
