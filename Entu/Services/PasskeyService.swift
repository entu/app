// Passkeys are bound to the `entu.app` domain via the Associated
// Domains entitlement and the apple-app-site-association file served
// there, so the same passkey registered in the web app can be used
// here and vice versa.

import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// WebAuthn authentication options returned by GET /auth/passkey.
/// `challengeToken` is a short-lived JWT wrapping the challenge — the POST
/// routes verify it instead of trusting a client-echoed challenge.
private struct PasskeyAuthOptions: Decodable {
    let challenge: String
    let rpId: String
    let challengeToken: String
}

/// WebAuthn assertion body sent to POST /auth/passkey.
private struct PasskeyAuthBody: Encodable {
    let id: String
    let rawId: String
    let type: String
    let response: Response
    let challengeToken: String

    struct Response: Encodable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }
}

/// WebAuthn registration options returned by GET /{db}/passkey
/// (`@simplewebauthn/server generateRegistrationOptions` shape).
private struct PasskeyRegistrationOptions: Decodable {
    let challenge: String
    let rp: RelyingParty
    let user: User
    let challengeToken: String

    struct RelyingParty: Decodable {
        let id: String
    }

    struct User: Decodable {
        /// base64url-encoded user handle.
        let id: String
        let name: String
    }
}

/// WebAuthn attestation body sent to POST /{db}/passkey.
private struct PasskeyRegisterBody: Encodable {
    let id: String
    let rawId: String
    let type: String
    let response: Response
    let challengeToken: String
    let deviceName: String

    struct Response: Encodable {
        let clientDataJSON: String
        let attestationObject: String
    }
}

/// Response from POST /{db}/passkey — the just-stored `entu_passkey`
/// property, `string` pre-masked to "{device} {last-4-of-id}".
struct PasskeyRegistrationResult: Decodable {
    let success: Bool
    let properties: [RegisteredProperty]?

    struct RegisteredProperty: Decodable {
        let _id: String?
        let type: String?
        let string: String?
    }
}

/// Handles passkey sign-in and registration via AuthenticationServices.
@Observable
@MainActor
final class PasskeyService: NSObject {
    private let auth: AuthModel
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

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
            challengeToken: options.challengeToken
        )

        let response: AuthResponse = try await auth.api.post("auth/passkey", body: body)

        if let newDatabases = response.accounts, !newDatabases.isEmpty {
            auth.databases = newDatabases
        }

        if let newToken = response.token {
            auth.storeToken(newToken, expires: response.expires)
        }

        auth.user = response.user
    }

    /// Register a new passkey on the signed-in user's entity in the active
    /// database: fetch options from `GET /{db}/passkey`, present the system
    /// registration UI, commit the attestation via `POST /{db}/passkey`.
    /// Returns the stored `entu_passkey` property (id + masked display
    /// string) so the caller can update its row without a refetch.
    func register() async throws -> PasskeyRegistrationResult.RegisteredProperty? {
        let options: PasskeyRegistrationOptions = try await auth.api.get("passkey")

        guard let challengeData = Data(base64URLEncoded: options.challenge),
              let userID = Data(base64URLEncoded: options.user.id) else {
            throw APIError.invalidResponse
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rp.id)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challengeData,
            name: options.user.name,
            userID: userID
        )

        let registration = try await performRegistration(request: request)

        guard let attestationObject = registration.rawAttestationObject else {
            throw APIError.invalidResponse
        }

        let credentialID = registration.credentialID.base64URLEncodedString()

        let body = PasskeyRegisterBody(
            id: credentialID,
            rawId: credentialID,
            type: "public-key",
            response: PasskeyRegisterBody.Response(
                clientDataJSON: registration.rawClientDataJSON.base64URLEncodedString(),
                attestationObject: attestationObject.base64URLEncodedString()
            ),
            challengeToken: options.challengeToken,
            deviceName: Self.deviceName
        )

        let result: PasskeyRegistrationResult = try await auth.api.post("passkey", body: body)

        return result.properties?.first { $0.type == "entu_passkey" }
    }

    /// Mirrors webapp's `getDeviceName()` in `pages/[account]/passkey.vue`.
    private static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    // Wrap the callback-based ASAuthorizationController in async/await and return the assertion.
    private func performAssertion(
        request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        guard let assertion = try await performRequest(request).credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw APIError.invalidResponse
        }
        return assertion
    }

    // Same wrapper for the registration request.
    private func performRegistration(
        request: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialRegistration {
        guard let registration = try await performRequest(request).credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw APIError.invalidResponse
        }
        return registration
    }

    private func performRequest(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
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
            continuation?.resume(returning: authorization)
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
