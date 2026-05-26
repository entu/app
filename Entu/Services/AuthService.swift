import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Window anchor for `ASWebAuthenticationSession`'s browser sheet. Returns
/// an existing window — creating a fresh one here is unsafe because the
/// system may call this off the main queue on macOS.
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first!
            return scene.keyWindow ?? UIWindow(windowScene: scene)
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

    /// Clear any leftover pending session — e.g. one whose completion never
    /// fired because `SFAuthenticationViewController` deallocated mid-dismiss.
    func cancelPending() {
        resume(.failure(CancellationError()))
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

        // Let the prior `SFAuthenticationViewController` finish its dismiss
        // animation before we start a new one — there's no "did dismiss"
        // callback, and starting too early hangs UIKit on the deallocating
        // controller. 350 ms covers Apple's standard modal-dismiss duration.
        try? await Task.sleep(for: .milliseconds(350))

        // Safety timeout — if the OS never fires the completion callback,
        // the awaiter would hang and the per-button spinner would spin
        // forever. Resume after 60 s; no-op if the session already resumed.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await MainActor.run {
                self?.resume(.failure(CancellationError()))
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            // `@Sendable` is load-bearing: without it Swift 6 inserts a
            // @MainActor runtime check that crashes when the system invokes
            // this callback off-main from its XPC reply queue.
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

    /// Idempotent single sink for resolving the in-flight continuation. State
    /// is cleared before `cancel()` so synchronous re-entry from the session's
    /// completion handler finds a nil continuation and no-ops.
    private func resume(_ result: Result<String, Error>) {
        guard let continuation = pendingContinuation else { return }

        let sessionToCancel = pendingSession
        pendingSession = nil
        pendingContinuation = nil

        sessionToCancel?.cancel()
        continuation.resume(with: result)
    }
}
