// Handles OAuth sign-in via an in-app browser sheet.
// Opens the Entu API auth URL, waits for the OAuth callback (either inside
// the ASWebAuthenticationSession or delivered externally via Universal Link),
// then exchanges the returned key for a JWT token.

import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Provides the window that ASWebAuthenticationSession attaches its browser sheet to.
// Required on both macOS and iOS for the session to know where to present.
// Returns an existing window — creating a new NSWindow/UIWindow here is unsafe
// because the system may invoke this method off the main queue on macOS.
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            return scene?.keyWindow ?? UIWindow()
            #endif
        }
    }
}

/// Handles OAuth sign-in via ASWebAuthenticationSession + Universal Link callback.
@Observable
@MainActor
final class AuthService {
    private let auth: AuthModel
    private let callbackHost = "entu.app"
    private let callbackPath = "/auth/app-callback"
    private let contextProvider = PresentationContextProvider()

    private var pendingSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<String, Error>?

    init(auth: AuthModel) {
        self.auth = auth
    }

    /// Open the OAuth browser sheet for the given provider and complete the auth callback.
    /// The API redirects back to `https://entu.app/auth/app-callback?key=...` after successful auth.
    func signIn(with provider: AuthProvider) async throws {
        let callbackURL = "https://\(callbackHost)\(callbackPath)?key="
        let encoded = callbackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackURL
        let authURL = URL(string: "\(APIClient.baseURL)/auth/\(provider.rawValue)?next=\(encoded)")!

        let key = try await startWebAuth(url: authURL)
        try await auth.handleAuthCallback(key: key, databaseId: nil)
    }

    /// Handle a callback URL delivered externally (e.g. via Universal Link after email magic link or Smart-ID).
    /// Only URLs matching the configured host + path are accepted; anything else is ignored silently.
    func handleIncoming(url: URL) {
        guard url.host == callbackHost, url.path == callbackPath else { return }

        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let key = components?.queryItems?.first(where: { $0.name == "key" })?.value else {
            resume(.failure(APIError.invalidResponse))
            return
        }

        resume(.success(key))
    }

    /// Wrap the callback-based ASWebAuthenticationSession in async/await and return the OAuth key.
    /// The session opens a browser sheet; when the provider redirects back to the Universal Link URL,
    /// the callback fires either inside the sheet (Apple/Google) or via `handleIncoming` (email, Smart-ID).
    private func startWebAuth(url: URL) async throws -> String {
        resume(.failure(CancellationError()))

        return try await withCheckedThrowingContinuation { continuation in
            // @Sendable on the closure is load-bearing: without it, Swift 6 infers
            // @MainActor isolation from the enclosing class and inserts a runtime
            // executor check at closure entry. ASWebAuthenticationSession invokes
            // the callback from its XPC reply queue (e.g. during `_startDryRun`),
            // which fails that check and crashes before the body can hop to main.
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: callbackHost, path: callbackPath)
            ) { @Sendable [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let error {
                        self.resume(.failure(error))
                        return
                    }

                    guard let callbackURL,
                          let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                          let key = components.queryItems?.first(where: { $0.name == "key" })?.value else {
                        self.resume(.failure(APIError.invalidResponse))
                        return
                    }

                    self.resume(.success(key))
                }
            }

            session.presentationContextProvider = self.contextProvider
            session.prefersEphemeralWebBrowserSession = false

            self.pendingSession = session
            self.pendingContinuation = continuation

            session.start()
        }
    }

    // Single sink for resolving the in-flight continuation. Idempotent.
    // State is cleared before cancel() so any synchronous re-entry from the session's
    // completion handler finds a nil continuation and no-ops.
    private func resume(_ result: Result<String, Error>) {
        guard let continuation = pendingContinuation else { return }

        let sessionToCancel = pendingSession
        pendingSession = nil
        pendingContinuation = nil

        sessionToCancel?.cancel()
        continuation.resume(with: result)
    }
}
