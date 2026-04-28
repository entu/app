// Sign-in screen — shown when the user has no stored token and no saved
// public database. Displays the app logo, a list of authentication providers
// (Apple, Google, email, Estonian ID methods, passkey), and an entry point
// for browsing public databases as a guest.

import AuthenticationServices
import SwiftUI

/// Sign-in screen with grouped authentication provider buttons.
struct AuthView: View {
    @Environment(AuthService.self) private var authService
    @Environment(PasskeyService.self) private var passkeyService

    @State private var isLoading = false
    @State private var error: String?
    @State private var showingPublicEntry = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.top, 48)
                .padding(.bottom, 16)

            VStack(spacing: 4) {
                Text("signInTitle")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("signInDescription")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            // MARK: - Provider buttons + browse public

            // Provider buttons grouped by type. The "Browse public database"
            // button lives inside the same ScrollView so it stays visually
            // tied to the provider list and doesn't get pushed to the bottom
            // edge on compact iPhone layouts. Gradient mask fades the top/
            // bottom edges of the scroll area.
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 36) {
                        ForEach(AuthProviderGroup.allCases, id: \.self) { group in
                            let providers = AuthProvider.allCases.filter {
                                $0.group == group && $0.isAvailableOnCurrentPlatform
                            }

                            VStack(spacing: 12) {
                                ForEach(providers, id: \.self) { provider in
                                    AuthButton(provider: provider, isLoading: isLoading) {
                                        await signIn(with: provider)
                                    }
                                }
                            }
                        }
                    }

                    VStack(spacing: 20) {
                        OrSeparator()
                        BrowsePublicDatabaseButton(isLoading: isLoading) {
                            showingPublicEntry = true
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 320)
            }
            .scrollFadeMask()

            // MARK: - Error message

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.top, 16)
                    .padding(.horizontal, 32)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("")
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .publicDatabaseEntry(isPresented: $showingPublicEntry)
    }

    private func signIn(with provider: AuthProvider) async {
        error = nil
        isLoading = true
        defer { isLoading = false }

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

// MARK: - AuthButton

// Styled button for a single auth provider row.
private struct AuthButton: View {
    let provider: AuthProvider
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if provider.icon.hasPrefix("sf:") {
                        Image(systemName: String(provider.icon.dropFirst(3)))
                    } else {
                        Image(provider.icon).resizable().scaledToFit()
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: 24)
                Text(provider.label)
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
