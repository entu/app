// Auth response models — token, accessible databases, user info, and
// expiry returned by `GET /auth`, `GET /auth/refresh` and the passkey
// sign-in / creation POSTs, which all answer in the same shape.

import Foundation

/// API response from the auth endpoints after sign-in or refresh.
struct AuthResponse: Codable {
    let token: String?
    let accounts: [Database]?
    let user: AuthUser?
    /// Token expiry as an ISO 8601 datetime string.
    let expires: String?
    /// `"invite"` when the invite was not accepted because the login
    /// identity already is another person in the invite's database.
    let conflict: String?
    /// After a passkey sign-in or creation that sent `rename: true`: the
    /// name to show for the passkey in the password manager. Sent once, and
    /// again only when the person name changes.
    let rename: String?
}

/// Login identity returned by the auth API. A passkey identity carries no
/// e-mail; its `name` is the person name from the first database (by name)
/// that has one.
struct AuthUser: Codable {
    let _id: String?
    let name: String?
    let email: String?
}
