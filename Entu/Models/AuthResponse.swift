// JSON response from the /auth endpoint after a successful sign-in.
// Contains a JWT token, the list of databases the user can access,
// and basic user info.
//
// Note: the API returns the field as "accounts" but we map it to Database
// in the app layer since "database" is the correct domain term.

import Foundation

/// API response from the auth endpoint after sign-in.
struct AuthResponse: Codable {
    let token: String?
    let accounts: [Database]?
    let user: AuthUser?
}

/// Basic user info returned by the auth API.
struct AuthUser: Codable {
    let _id: String?
    let name: String?
    let email: String?
}
