// Global authentication state — tracks whether the user is signed in,
// which authenticated databases they can access, which public databases
// they have added for guest browsing, and who they are.
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

    /// Names of public databases the user has added (independent of any sign-in).
    /// The API gives us no display name or user info for unauthenticated reads,
    /// so the id doubles as the rendered label. Persisted to UserDefaults
    /// (non-sensitive list of public ids — no token attached).
    var publicDatabases: [String] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(publicDatabases) {
                UserDefaults.standard.set(data, forKey: "auth.publicDatabases")
            }
        }
    }

    /// Currently signed-in user, or nil when logged out.
    var user: AuthUser?

    /// True when a valid JWT is stored on the API client.
    var isAuthenticated: Bool { api.token != nil }

    /// True when the active database is being browsed as a guest.
    var isCurrentDatabasePublic: Bool {
        guard let id = api.databaseId else { return false }
        return publicDatabases.contains(id) && !databases.contains(where: { $0._id == id })
    }

    let api: APIClient

    init(api: APIClient) {
        self.api = api

        // Restore previous session from keychain on app launch
        if let data = KeychainService.loadDatabases(),
           let saved = try? JSONDecoder().decode([Database].self, from: data),
           !saved.isEmpty {
            self.databases = saved
            self.api.token = KeychainService.loadToken()
        }

        // Restore the saved public-database list (no secrets — just ids).
        if let data = UserDefaults.standard.data(forKey: "auth.publicDatabases"),
           let savedPublic = try? JSONDecoder().decode([String].self, from: data) {
            self.publicDatabases = savedPublic
        }

        // Resolve the previously-active database. Authenticated dbs win when
        // the same id appears in both sets (shouldn't happen, but defensive).
        if let lastId = UserDefaults.standard.string(forKey: "auth.lastDatabaseId") {
            if databases.contains(where: { $0._id == lastId }) {
                self.api.databaseId = lastId
                self.api.suppressToken = false
            } else if publicDatabases.contains(lastId) {
                self.api.databaseId = lastId
                self.api.suppressToken = true
            } else {
                UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
            }
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

        // Reject the response unless the user has at least one database — a
        // token without databases is unusable and would strand the user on an
        // empty picker. Validate before saving the token so isAuthenticated
        // stays false on this branch.
        guard let newDatabases = response.accounts, !newDatabases.isEmpty else {
            throw APIError.noAccessibleDatabases
        }
        databases = newDatabases

        if let newToken = response.token {
            KeychainService.saveToken(newToken)
            api.token = newToken
        }

        user = response.user
    }

    /// Set the active database for all subsequent API calls (authenticated).
    func selectDatabase(_ database: Database) {
        api.databaseId = database._id
        api.suppressToken = false
        UserDefaults.standard.set(database._id, forKey: "auth.lastDatabaseId")
    }

    /// Set the active database to one of the saved public databases.
    /// Suppresses the Authorization header for as long as it remains active,
    /// so a signed-in user is treated as a guest by the API.
    func selectPublicDatabase(_ id: String) {
        api.databaseId = id
        api.suppressToken = true
        UserDefaults.standard.set(id, forKey: "auth.lastDatabaseId")
    }

    /// Add a public database id to the saved list (no-op if already present).
    func addPublicDatabase(_ id: String) {
        guard !publicDatabases.contains(id) else { return }
        publicDatabases.append(id)
    }

    /// Reset everything — clear stored credentials, the saved public-database
    /// list, and the active database. Returns the user to `AuthView`.
    func logOut() {
        KeychainService.deleteToken()
        KeychainService.deleteDatabases()
        api.token = nil
        api.suppressToken = false
        api.databaseId = nil
        databases = []
        publicDatabases = []
        user = nil
        UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
        MenuModel.clearCache()
        EntityDetailModel.clearCache()
    }

    /// Permanently delete the signed-in user's person entity in the active
    /// database. Before deleting the entity, hard-deletes the user's auth
    /// properties (`entu_user`, `entu_passkey`, `entu_api_key`) so a stale
    /// passkey or OAuth provider mapping cannot be matched on a later sign-in.
    /// After success, drops the database from the local list and either
    /// switches to another database or signs out entirely.
    func deleteCurrentAccount() async throws {
        guard let activeId = api.databaseId,
              let database = databases.first(where: { $0._id == activeId }),
              let personId = database.user?._id else {
            throw APIError.invalidResponse
        }

        await deleteAuthProperties(personId: personId)

        let _: DeleteResponse = try await api.delete("entity/\(personId)")

        databases.removeAll { $0._id == activeId }

        // Drop cached menu/type entries — the deleted database's entries are
        // now stale, and `logOut()` would clear them anyway in the no-more-
        // databases branch.
        MenuModel.clearCache()
        EntityDetailModel.clearCache()

        if let next = databases.first {
            selectDatabase(next)
        } else {
            logOut()
        }
    }

    /// Best-effort hard delete of the auth-related properties on the user's
    /// person entity. Failures are swallowed so the entity delete still
    /// proceeds — the entity-level soft-delete is the source of truth, this
    /// is a belt-and-braces cleanup.
    private func deleteAuthProperties(personId: String) async {
        let authPropertyNames = ["entu_user", "entu_passkey", "entu_api_key"]

        guard let response: EntityDetailResponse = try? await api.get(
            "entity/\(personId)",
            params: ["props": authPropertyNames.joined(separator: ",")]
        ) else { return }

        for name in authPropertyNames {
            for value in response.entity?.properties[name] ?? [] {
                guard let propId = value._id else { continue }

                let _: DeleteResponse? = try? await api.delete("property/\(propId)")
            }
        }
    }
}

/// Response shape from `DELETE /{db}/entity/{_id}` and `DELETE /{db}/property/{_id}`.
struct DeleteResponse: Decodable {
    let deleted: Bool?
}
