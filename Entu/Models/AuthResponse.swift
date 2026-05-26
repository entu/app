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
