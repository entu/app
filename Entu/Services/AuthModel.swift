// Global authentication state — tracks whether the user is signed in,
// which databases they can access, and who they are.
//
// @Observable = SwiftUI automatically re-renders views when these properties change.
// @MainActor = all mutations happen on the main thread (safe for UI updates).

import Foundation

/// Global authentication state — token, databases, current user.
@MainActor @Observable
final class AuthModel {
    /// Databases the signed-in user can access. Persisted to the keychain on change.
    var databases: [Database] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(databases) {
                KeychainService.saveDatabases(data)
            }
        }
    }

    /// Currently signed-in user, or nil when logged out.
    var user: AuthUser?

    /// True when a valid JWT is stored on the API client.
    var isAuthenticated: Bool { api.token != nil }

    let api: APIClient

    init(api: APIClient) {
        self.api = api

        // Restore previous session from keychain on app launch
        if let data = KeychainService.loadDatabases(),
           let saved = try? JSONDecoder().decode([Database].self, from: data),
           !saved.isEmpty {
            self.databases = saved
            self.api.token = KeychainService.loadToken()
            self.api.databaseId = UserDefaults.standard.string(forKey: "auth.lastDatabaseId")
        }

        // Auto-logout when the API returns 401 (expired/invalid token)
        self.api.onUnauthorized = { [weak self] in
            self?.logOut()
        }
    }

    /// Exchange a temporary auth key for a permanent JWT token and database list.
    func handleAuthCallback(key: String, databaseId: String?) async throws {
        var params: [String: String] = [:]
        if let databaseId { params["db"] = databaseId }

        let response: AuthResponse = try await api.requestWithToken("auth", params: params, bearerToken: key)

        if let newDatabases = response.accounts, !newDatabases.isEmpty {
            databases = newDatabases
        }

        if let newToken = response.token {
            KeychainService.saveToken(newToken)
            api.token = newToken
        }

        user = response.user
    }

    /// Set the active database for all subsequent API calls.
    func selectDatabase(_ database: Database) {
        api.databaseId = database._id
        UserDefaults.standard.set(database._id, forKey: "auth.lastDatabaseId")
    }

    /// Clear all stored credentials and return to the sign-in screen.
    func logOut() {
        KeychainService.deleteToken()
        KeychainService.deleteDatabases()
        api.token = nil
        api.databaseId = nil
        UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
        databases = []
        user = nil
    }
}
