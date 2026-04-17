// Handles OAuth sign-in via an in-app browser sheet.
// Opens the Entu API auth URL, waits for the OAuth callback,
// then exchanges the returned key for a JWT token.

import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#endif

// Provides the window that ASWebAuthenticationSession attaches its browser sheet to.
// Required on both macOS and iOS for the session to know where to present.
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene!.keyWindow!
        #endif
    }
}

/// Handles OAuth sign-in via ASWebAuthenticationSession.
@MainActor
final class AuthService {
    private let auth: AuthModel
    private let callbackScheme = "entu"
    private let contextProvider = PresentationContextProvider()

    init(auth: AuthModel) {
        self.auth = auth
    }

    /// Open the OAuth browser sheet for the given provider and complete the auth callback.
    /// The API redirects back to `entu://callback?key=...` after successful auth.
    func signIn(with provider: AuthProvider) async throws {
        let callbackURL = "\(callbackScheme)://callback?key="
        let encoded = callbackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackURL
        let authURL = URL(string: "\(APIClient.baseURL)/auth/\(provider.rawValue)?next=\(encoded)")!

        let key = try await startWebAuth(url: authURL)
        try await auth.handleAuthCallback(key: key, databaseId: nil)
    }

    /// Wrap the callback-based ASWebAuthenticationSession in async/await and return the OAuth key.
    /// The session opens a browser sheet; when the provider redirects back to the custom URL scheme,
    /// the callback fires with the URL carrying the one-time `key` parameter.
    nonisolated private func startWebAuth(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let key = components.queryItems?.first(where: { $0.name == "key" })?.value else {
                    continuation.resume(throwing: APIError.invalidResponse)
                    return
                }

                continuation.resume(returning: key)
            }

            session.presentationContextProvider = self.contextProvider
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}
