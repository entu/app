// Passkey sign-in and creation through AuthenticationServices. Passkeys
// are bound to the `entu.app` domain via the Associated Domains
// entitlement and the apple-app-site-association file served there, so a
// passkey made in the webapp works here and vice versa.
//
// Neither flow needs a session: sign-in is `GET /auth/passkey/options` →
// assertion → `POST /auth/passkey`, creation is
// `GET /auth/passkey/register/options` → registration →
// `POST /auth/passkey/register`. Both answer like `GET /auth` and go through
// `AuthModel.applyAuthResponse`. Adding a passkey to the user's own person
// is a self-invite ("Add login method") like any other provider.
//
// The Signal API keeps the device's passkey list in step with the server:
// the person name replaces the "Entu" placeholder after a sign-in or
// creation, and a passkey the server rejects or never stored is reported
// unknown so the system can drop it.

import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#endif

/// WebAuthn authentication options returned by GET /auth/passkey/options.
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
    let db: String?
    let invite: String?

    struct Response: Encodable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
    }
}

/// WebAuthn creation options returned by GET /auth/passkey/register/options
/// (`@simplewebauthn/server generateRegistrationOptions` shape). `user.id`
/// is a random handle and `user.name` always "Entu" — a passkey belongs to
/// no person until an invite, automatic user creation or `PUT /new` links it.
private struct PasskeyCreationOptions: Decodable {
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

/// WebAuthn attestation body sent to POST /auth/passkey/register.
private struct PasskeyCreationBody: Encodable {
    let id: String
    let rawId: String
    let type: String
    let response: Response
    let challengeToken: String
    let deviceName: String
    let db: String?
    let invite: String?

    struct Response: Encodable {
        let clientDataJSON: String
        let attestationObject: String
    }
}

/// Handles passkey sign-in and creation via AuthenticationServices.
@Observable
@MainActor
final class PasskeyService: NSObject {
    private let auth: AuthModel

    /// The one in-flight authorization: its controller (to match delegate
    /// callbacks and to cancel it) and the continuation awaiting it.
    @ObservationIgnored private var pending: (controller: ASAuthorizationController, continuation: CheckedContinuation<ASAuthorization, Error>)?

    init(auth: AuthModel) {
        self.auth = auth
        super.init()
    }

    /// Sign in with a stored passkey: fetch options, present the system
    /// passkey UI, exchange the assertion for a JWT and database list.
    /// `invite` + `databaseId` accept an invite with that passkey;
    /// `keepSession` is the self-invite, which keeps the current session.
    func signIn(invite: String? = nil, databaseId: String? = nil, keepSession: Bool = false) async throws {
        let options: PasskeyAuthOptions = try await auth.api.getWithoutToken("auth/passkey/options")

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
            challengeToken: options.challengeToken,
            db: databaseId,
            invite: invite
        )

        let response: AuthResponse
        do {
            response = try await auth.exchange {
                try await auth.api.postWithoutToken("auth/passkey", body: body)
            }
        } catch let error as APIError where error.isServerError(400, message: "Authentication verification failed") {
            // No database stores this passkey any more — tell the system so
            // it stops offering it.
            PasskeySignal.reportUnknown(relyingParty: options.rpId, credentialID: assertion.credentialID)
            throw APIError.passkeyNotRecognized
        }

        try auth.applyAuthResponse(response, keepSession: keepSession)

        if let name = response.user?.name, !assertion.userID.isEmpty {
            PasskeySignal.reportName(relyingParty: options.rpId, userHandle: assertion.userID, name: name)
        }
    }

    /// Create a new passkey and sign in with it: fetch creation options,
    /// present the system registration UI, send the attestation. The API
    /// stores the passkey only where it gets linked — an invite (with
    /// `invite` + `databaseId`), or automatic user creation in `databaseId`.
    /// `keepSession` is the self-invite, which keeps the current session.
    func create(invite: String? = nil, databaseId: String? = nil, keepSession: Bool = false) async throws {
        let options: PasskeyCreationOptions = try await auth.api.getWithoutToken("auth/passkey/register/options")

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

        let body = PasskeyCreationBody(
            id: credentialID,
            rawId: credentialID,
            type: "public-key",
            response: PasskeyCreationBody.Response(
                clientDataJSON: registration.rawClientDataJSON.base64URLEncodedString(),
                attestationObject: attestationObject.base64URLEncodedString()
            ),
            challengeToken: options.challengeToken,
            deviceName: Self.deviceName,
            db: databaseId,
            invite: invite
        )

        let response: AuthResponse
        do {
            response = try await auth.exchange {
                try await auth.api.postWithoutToken("auth/passkey/register", body: body)
            }
            try auth.applyAuthResponse(response, keepSession: keepSession)
        } catch let error as APIError where Self.leavesPasskeyUnlinked(error) {
            // The server answered without storing the new passkey anywhere —
            // drop it from the device instead of leaving one that never works.
            // Network failures are excluded: the server may have stored it.
            PasskeySignal.reportUnknown(relyingParty: options.rp.id, credentialID: registration.credentialID)
            throw error
        }

        if let name = response.user?.name {
            PasskeySignal.reportName(relyingParty: options.rp.id, userHandle: userID, name: name)
        }
    }

    /// True for the definite server answers after which a just-created
    /// passkey is linked to no person: a rejected or conflicting invite, a
    /// sign-up with no database, or any other 400 (verification failed,
    /// credential id taken).
    private static func leavesPasskeyUnlinked(_ error: APIError) -> Bool {
        switch error {
        case .inviteInvalid, .inviteConflict, .noAccessibleDatabases: return true
        case .serverError(let code, _): return code == 400
        default: return false
        }
    }

    /// Mirrors webapp's `getDeviceName()` in `pages/[account]/passkey.vue`.
    private static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    // MARK: - Authorization controller

    /// Present an assertion request and return the assertion.
    private func performAssertion(
        request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        guard let assertion = try await performRequest(request).credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw APIError.invalidResponse
        }
        return assertion
    }

    /// Present a registration request and return the new credential.
    private func performRegistration(
        request: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialRegistration {
        guard let registration = try await performRequest(request).credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw APIError.invalidResponse
        }
        return registration
    }

    /// Wrap the callback-based ASAuthorizationController in async/await.
    /// One request at a time: a second one while the system sheet is up
    /// throws `CancellationError` instead of replacing — and orphaning —
    /// the pending continuation. Cancelling the awaiting task cancels the
    /// controller, so the continuation always resumes.
    private func performRequest(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        guard pending == nil else { throw CancellationError() }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let controllerId = ObjectIdentifier(controller)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (controller, continuation)
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(controllerId, with: .failure(CancellationError()), cancelController: true)
            }
        }
    }

    /// Resolve the pending continuation if it belongs to `controllerId` —
    /// a late callback from an earlier controller is ignored.
    private func finish(_ controllerId: ObjectIdentifier, with result: Result<ASAuthorization, Error>, cancelController: Bool = false) {
        guard let current = pending, ObjectIdentifier(current.controller) == controllerId else { return }

        pending = nil

        if cancelController {
            current.controller.cancel()
        }

        current.continuation.resume(with: result)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let controllerId = ObjectIdentifier(controller)
        Task { @MainActor in
            finish(controllerId, with: .success(authorization))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let controllerId = ObjectIdentifier(controller)
        Task { @MainActor in
            finish(controllerId, with: .failure(error))
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension PasskeyService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        AuthPresentationAnchor.current()
    }
}

// MARK: - Signal API

/// Fire-and-forget Signal API reports. Failures are silent — the reports
/// only tidy the device's passkey list and must never fail a sign-in.
/// `ASCredentialDataManager` replaced `ASCredentialUpdater` in 26.2; the
/// older class covers 26.0–26.1.
private enum PasskeySignal {
    /// Show the person name instead of the "Entu" placeholder for this passkey.
    static func reportName(relyingParty: String, userHandle: Data, name: String) {
        Task {
            if #available(iOS 26.2, macOS 26.2, *) {
                try? await ASCredentialDataManager().reportPublicKeyCredentialUpdate(
                    relyingPartyIdentifier: relyingParty,
                    userHandle: userHandle,
                    newName: name
                )
            } else {
                try? await ASCredentialUpdater().reportPublicKeyCredentialUpdate(
                    relyingPartyIdentifier: relyingParty,
                    userHandle: userHandle,
                    newName: name
                )
            }
        }
    }

    /// Tell the system the server does not know this passkey.
    static func reportUnknown(relyingParty: String, credentialID: Data) {
        Task {
            if #available(iOS 26.2, macOS 26.2, *) {
                try? await ASCredentialDataManager().reportUnknownPublicKeyCredential(
                    relyingPartyIdentifier: relyingParty,
                    credentialID: credentialID
                )
            } else {
                try? await ASCredentialUpdater().reportUnknownPublicKeyCredential(
                    relyingPartyIdentifier: relyingParty,
                    credentialID: credentialID
                )
            }
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
