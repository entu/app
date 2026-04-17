// Sign-in screen — shown when the user has no stored token.
// Displays the app logo and a list of authentication providers
// (Apple, Google, email, Estonian ID methods, passkey).

import AuthenticationServices
import SwiftUI

/// Sign-in screen with grouped authentication provider buttons.
struct AuthView: View {
    @Environment(AuthModel.self) private var auth

    @State private var authService: AuthService?
    @State private var isLoading = false
    @State private var error: String?

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
                Text(String(localized: "signInTitle"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(String(localized: "signInDescription"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            // MARK: - Provider buttons

            // Provider buttons grouped by type, with dividers between groups.
            // Gradient mask fades the top/bottom edges of the scroll area.
            ScrollView {
                VStack(spacing: 36) {
                    ForEach(AuthProviderGroup.allCases, id: \.self) { group in
                        let providers = AuthProvider.allCases.filter { $0.group == group }

                        VStack(spacing: 12) {
                            ForEach(providers, id: \.self) { provider in
                                AuthButton(provider: provider, isLoading: isLoading || !provider.isEnabled) {
                                    await signIn(with: provider)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 320)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            )

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

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("")
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .onAppear { authService = AuthService(auth: auth) }
    }

    private func signIn(with provider: AuthProvider) async {
        error = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService?.signIn(with: provider)
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // User dismissed the browser — not an error
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
