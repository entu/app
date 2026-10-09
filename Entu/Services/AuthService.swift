// OAuth sign-in — runs the provider flows through
// `ASWebAuthenticationSession` and exchanges the callback for an API token
// via `AuthModel.handleAuthCallback`.

import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#endif

/// Window anchor for `ASWebAuthenticationSession`'s browser sheet — see
/// `AuthPresentationAnchor`.
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        AuthPresentationAnchor.current()
    }
}

/// Handles OAuth sign-in via ASWebAuthenticationSession + custom URL scheme callback.
@Observable
@MainActor
final class AuthService {
    private let auth: AuthModel
    private let callbackScheme = "entu"
    private let callbackSchemeHost = "auth-callback"
    private let contextProvider = PresentationContextProvider()

    private var pendingSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<String, Error>?

    /// Identifies the in-flight attempt, so its safety timeout can never
    /// cancel a later attempt that reused the pending slot.
    private var pendingAttempt: UUID?

    init(auth: AuthModel) {
        self.auth = auth
    }

    /// Clear any leftover pending session — e.g. one whose completion never
    /// fired because `SFAuthenticationViewController` deallocated mid-dismiss.
    func cancelPending() {
        resume(.failure(CancellationError()))
    }

    /// Open the OAuth browser sheet for the given provider and complete the auth callback.
    /// The API redirects back to `entu://auth-callback?key=...` after successful auth —
    /// a custom scheme, so returning through any default browser reopens the app.
    /// `invite` + `databaseId` run the exchange through the invite-acceptance
    /// path; `keepSession` is the self-invite ("Add login method" on the
    /// user's own entity), which links the login and keeps the current session.
    func signIn(with provider: AuthProvider, invite: String? = nil, databaseId: String? = nil, keepSession: Bool = false) async throws {
        let callbackURL = "\(callbackScheme)://\(callbackSchemeHost)?key="
        let encoded = callbackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callbackURL

        guard let authURL = URL(string: "\(APIClient.baseURL)/auth/\(provider.rawValue)?next=\(encoded)&lang=\(AppLanguage.resolvedLanguageCode)") else {
            throw APIError.invalidResponse
        }

        let key = try await startWebAuth(url: authURL)
        try await auth.handleAuthCallback(key: key, databaseId: databaseId, invite: invite, keepSession: keepSession)
    }

    /// Handles a custom-scheme auth callback URL arriving outside the sheet (e.g. email, Smart-ID).
    func handleIncoming(url: URL) {
        guard url.scheme == callbackScheme, url.host == callbackSchemeHost else { return }

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
    /// The session opens a browser sheet; when the provider redirects back to the custom-scheme URL,
    /// the callback fires either inside the sheet (Apple/Google) or via `handleIncoming` (email, Smart-ID).
    private func startWebAuth(url: URL) async throws -> String {
        resume(.failure(CancellationError()))

        // Let the prior `SFAuthenticationViewController` finish its dismiss
        // animation before we start a new one — there's no "did dismiss"
        // callback, and starting too early hangs UIKit on the deallocating
        // controller. 350 ms covers Apple's standard modal-dismiss duration.
        try? await Task.sleep(for: .milliseconds(350))

        let attempt = UUID()

        // Safety timeout — if the OS never fires the completion callback,
        // the awaiter would hang and the per-button spinner would spin
        // forever. Resume after 5 min (the server's flow budget); a no-op
        // once this attempt resolved or a newer one replaced it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            self?.resume(.failure(CancellationError()), ifAttempt: attempt)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // `@Sendable` is load-bearing: without it Swift 6 inserts a
            // @MainActor runtime check that crashes when the system invokes
            // this callback off-main from its XPC reply queue.
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { @Sendable [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let error {
                        self.resume(.failure(error), ifAttempt: attempt)
                        return
                    }

                    guard let callbackURL,
                          let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                          let key = components.queryItems?.first(where: { $0.name == "key" })?.value else {
                        self.resume(.failure(APIError.invalidResponse), ifAttempt: attempt)
                        return
                    }

                    self.resume(.success(key), ifAttempt: attempt)
                }
            }

            session.presentationContextProvider = self.contextProvider
            session.prefersEphemeralWebBrowserSession = false

            self.pendingSession = session
            self.pendingContinuation = continuation
            self.pendingAttempt = attempt

            session.start()
        }
    }

    /// Idempotent single sink for resolving the in-flight continuation. State
    /// is cleared before `cancel()` so synchronous re-entry from the session's
    /// completion handler finds a nil continuation and no-ops. With
    /// `ifAttempt`, only that attempt is resolved — a stale timeout or
    /// session callback leaves a newer attempt alone.
    private func resume(_ result: Result<String, Error>, ifAttempt attempt: UUID? = nil) {
        guard let continuation = pendingContinuation else { return }

        if let attempt, attempt != pendingAttempt { return }

        let sessionToCancel = pendingSession
        pendingSession = nil
        pendingContinuation = nil
        pendingAttempt = nil

        sessionToCancel?.cancel()
        continuation.resume(with: result)
    }
}
