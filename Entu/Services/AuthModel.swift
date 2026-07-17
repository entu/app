// Global authentication state — the JWT token, accessible databases, and
// current user, persisted to the keychain and shared app-wide.

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

    /// Expiry of the stored JWT, parsed from the API's ISO 8601 `expires` field.
    private(set) var tokenExpiresAt: Date?

    /// Refresh the token when less than this many seconds remain before expiry.
    private let refreshThreshold: TimeInterval = 60 * 60

    /// In-flight refresh, so a burst of concurrent requests triggers one refresh.
    private var refreshTask: Task<Void, Never>?

    /// True when a valid JWT is stored on the API client.
    var isAuthenticated: Bool { api.token != nil }

    /// True when the active database is being browsed as a guest.
    var isCurrentDatabasePublic: Bool {
        guard let id = api.databaseId else { return false }
        return publicDatabases.contains(id) && !databases.contains(where: { $0._id == id })
    }

    /// User id of the signed-in user *in the active authenticated database*.
    /// Nil while signed out and nil in public mode — write affordances treat
    /// nil as "no rights anywhere" via `EntityDetail.rights(for:)`.
    var currentUserId: String? {
        guard let id = api.databaseId else { return nil }
        return databases.first { $0._id == id }?.user?._id
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

            if let expires = KeychainService.loadTokenExpiry() {
                self.tokenExpiresAt = ISO8601DateFormatter.parse(expires)
            }
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

        // Refresh a near-expiry token before each authenticated request
        self.api.refreshIfNeeded = { [weak self] in
            await self?.refreshTokenIfNeeded()
        }
    }

    // MARK: - Token persistence & refresh

    /// Persist a freshly issued token and its expiry (keychain + in-memory).
    func storeToken(_ token: String, expires: String?) {
        KeychainService.saveToken(token)
        api.token = token

        if let expires {
            KeychainService.saveTokenExpiry(expires)
            tokenExpiresAt = ISO8601DateFormatter.parse(expires)
        }
    }

    /// Exchange the current token for a fresh one via `GET /auth/refresh`.
    /// The API refuses tokens older than 14 days, returning 401 → auto-logout.
    func refreshToken() async throws {
        let response: AuthResponse = try await api.requestSkippingRefresh("auth/refresh")

        if let newDatabases = response.accounts, !newDatabases.isEmpty {
            databases = newDatabases
        }

        if let newToken = response.token {
            storeToken(newToken, expires: response.expires)
        }

        if let newUser = response.user {
            user = newUser
        }
    }

    /// Refresh the token if it is close to expiry. Deduplicates concurrent
    /// callers so a burst of requests triggers a single refresh.
    func refreshTokenIfNeeded() async {
        guard api.token != nil, !api.suppressToken,
              let expiresAt = tokenExpiresAt,
              expiresAt.timeIntervalSinceNow < refreshThreshold else { return }

        let task: Task<Void, Never>
        if let existing = refreshTask {
            task = existing
        } else {
            task = Task { [weak self] in
                try? await self?.refreshToken()
                self?.refreshTask = nil
            }
            refreshTask = task
        }

        await task.value
    }

    // MARK: - Auth callback

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
            storeToken(newToken, expires: response.expires)
        }

        user = response.user
    }

    // MARK: - Database selection

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

    // MARK: - Sign out & account deletion

    /// Extra cleanup on sign-out for state this model can't reach — set by
    /// `ContentView` to reset the chat conversation, search state, and
    /// in-memory navigation.
    var onLogOut: (() -> Void)?

    /// Reset everything — credentials, caches, temp files, and (via
    /// `onLogOut`) all in-memory session state. Only app-general settings
    /// survive: language, column widths, table page size. Returns the user
    /// to `AuthView`.
    func logOut() {
        KeychainService.deleteToken()
        KeychainService.deleteTokenExpiry()
        KeychainService.deleteDatabases()
        api.token = nil
        api.suppressToken = false
        api.databaseId = nil
        tokenExpiresAt = nil
        databases = []
        publicDatabases = []
        user = nil
        UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
        MenuModel.clearCache()
        EntityColorCache.shared.clear()
        EntityDetailModel.clearCache()
        SessionState.clearStored()
        ImageCache.shared.clear()
        FileManager.default.clearTemporaryFiles()
        onLogOut?()
    }

    /// ⇧⌘R — drop everything local except credentials: every cache, temp
    /// files, and all `ui.*` settings (column widths, page size, language,
    /// session snapshots). The Keychain token, database list, and last
    /// database pointer survive, so the user stays signed in. In-memory
    /// session state (chat, search, navigation, deep links) resets via the
    /// same `onLogOut` hook sign-out uses.
    func clearLocalData() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ui.") {
            defaults.removeObject(forKey: key)
        }
        MenuModel.clearCache()
        EntityColorCache.shared.clear()
        EntityDetailModel.clearCache()
        ImageCache.shared.clear()
        FileManager.default.clearTemporaryFiles()
        onLogOut?()
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
