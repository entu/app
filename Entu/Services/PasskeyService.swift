// Handles passkey sign-in via the AuthenticationServices framework.
// Fetches WebAuthn options from the API, prompts the system passkey UI,
// then posts the assertion back to the API to receive a JWT.
//
// Passkeys are bound to the entu.app domain via the Associated Domains
// entitlement and the apple-app-site-association file served there, so the
// same passkey registered in the web app can be used here and vice versa.

import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// WebAuthn authentication options returned by GET /auth/passkey.
private struct PasskeyAuthOptions: Decodable {
    let challenge: String
    let rpId: String
}

/// WebAuthn assertion body sent to POST /auth/passkey.
private struct PasskeyAuthBody: Encodable {
    let id: String
    let rawId: String
    let type: String
    let response: Response
    let expectedChallenge: String

    struct Response: Encodable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }
}

/// Handles passkey sign-in via AuthenticationServices.
@Observable
@MainActor
final class PasskeyService: NSObject {
    private let auth: AuthModel
    private var continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>?

    init(auth: AuthModel) {
        self.auth = auth
        super.init()
    }

    /// Run passkey sign-in: fetch options, present the system passkey UI,
    /// then exchange the assertion for a JWT and database list.
    func signIn() async throws {
        let options: PasskeyAuthOptions = try await auth.api.get("auth/passkey")

        guard let challengeData = Data(base64URLEncoded: options.challenge) else {
            throw APIError.invalidResponse
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challengeData)

        let assertion = try await performAssertion(request: request)

        let userHandle = assertion.userID.isEmpty ? nil : assertion.userID.base64URLEncodedString()
        let credentialID = assertion.credentialID.base64URLEncodedString()

        let body = PasskeyAuthBody(
            id: credentialID,
            rawId: credentialID,
            type: "public-key",
            response: PasskeyAuthBody.Response(
                clientDataJSON: assertion.rawClientDataJSON.base64URLEncodedString(),
                authenticatorData: assertion.rawAuthenticatorData.base64URLEncodedString(),
                signature: assertion.signature.base64URLEncodedString(),
                userHandle: userHandle
            ),
            expectedChallenge: options.challenge
        )

        let response: AuthResponse = try await auth.api.post("auth/passkey", body: body)

        if let newDatabases = response.accounts, !newDatabases.isEmpty {
            auth.databases = newDatabases
        }

        if let newToken = response.token {
            KeychainService.saveToken(newToken)
            auth.api.token = newToken
        }

        auth.user = response.user
    }

    // Wrap the callback-based ASAuthorizationController in async/await and return the assertion.
    private func performAssertion(
        request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                continuation?.resume(throwing: APIError.invalidResponse)
                continuation = nil
                return
            }
            continuation?.resume(returning: assertion)
            continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension PasskeyService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
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

// MARK: - Base64URL helpers

private extension Data {
    // WebAuthn uses base64url (RFC 4648 §5): '+'→'-', '/'→'_', no padding.
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: s)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
