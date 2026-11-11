// Global authentication state — the JWT token, accessible databases,
// databases open to Entu support, and current user, persisted to the
// keychain and shared app-wide.

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

    /// Databases whose owner granted Entu support access to this identity
    /// (the auth response's `support`). Persisted to the keychain on change —
    /// like `databases`, the list reveals which databases the user can open.
    var supportDatabases: [Database] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(supportDatabases) {
                KeychainService.saveSupportDatabases(data)
            }
        }
    }

    /// Support databases whose grant still runs — the only ones listed or
    /// opened (webapp's `activeSupportAccounts`). An own database of the
    /// same id wins, mirroring the webapp's `account` lookup order.
    var activeSupportDatabases: [Database] {
        supportDatabases.filter { support in
            support.isActiveSupportGrant && !databases.contains { $0._id == support._id }
        }
    }

    /// True when the active database is open through an Entu support grant —
    /// the user then acts as the database entity with every right
    /// (webapp's `isSupport`).
    var isCurrentDatabaseSupport: Bool {
        currentSupportDatabase != nil
    }

    /// The active support database (with its `until`), nil otherwise.
    var currentSupportDatabase: Database? {
        guard let id = api.databaseId else { return nil }

        return activeSupportDatabases.first { $0._id == id }
    }

    /// Rights on `entity` for the active user — every right in a support
    /// database, where the API grants access per request while the grant
    /// runs (webapp's `right` in `utils/entity.js`).
    func rights(on entity: EntityDetail) -> EntityRights {
        if isCurrentDatabaseSupport {
            return .all
        }

        return entity.rights(for: currentUserId)
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
        return publicDatabases.contains(id) && database(for: id) == nil
    }

    /// User id of the signed-in user *in the active authenticated database*
    /// — in a support database the database entity's id, as the API acts as
    /// it there. Nil while signed out and nil in public mode — write
    /// affordances treat nil as "no rights anywhere" via `rights(on:)`.
    var currentUserId: String? {
        database(for: api.databaseId)?.user?._id
    }

    /// The authenticated database with `id` — own first, then a support
    /// database whose grant still runs — or nil for unknown/public ids
    /// (public databases carry no `Database` record — only their id).
    func database(for id: String?) -> Database? {
        guard let id else { return nil }

        return databases.first { $0._id == id } ?? activeSupportDatabases.first { $0._id == id }
    }

    let api: APIClient

    init(api: APIClient) {
        self.api = api

        // Restore previous session from keychain on app launch — a user
        // with only support databases is signed in too.
        let savedDatabases = KeychainService.loadDatabases()
            .flatMap { try? JSONDecoder().decode([Database].self, from: $0) } ?? []
        let savedSupport = KeychainService.loadSupportDatabases()
            .flatMap { try? JSONDecoder().decode([Database].self, from: $0) } ?? []

        if !savedDatabases.isEmpty || !savedSupport.isEmpty {
            self.databases = savedDatabases
            self.supportDatabases = savedSupport
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
            if database(for: lastId) != nil {
                self.api.databaseId = lastId
                self.api.suppressToken = false
            } else if publicDatabases.contains(lastId) {
                self.api.databaseId = lastId
                self.api.suppressToken = true
            } else {
                UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
            }
        }

        // Auto-logout when the API returns 401 (expired/invalid token) —
        // except in a support database, whose grant may just have ended.
        self.api.onUnauthorized = { [weak self] databaseId in
            self?.handleUnauthorized(databaseId: databaseId)
        }

        // A 403 in a support database may mean the grant ended.
        self.api.onForbidden = { [weak self] databaseId in
            self?.handleForbidden(databaseId: databaseId)
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

        try applyAuthResponse(response)
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

    // MARK: - Sign-in responses

    /// Exchange a temporary OAuth key for a JWT and database list
    /// (`GET /auth`). `invite` carries an invite JWT (with `db` naming the
    /// same database) so the API attaches the login to the invited entity —
    /// the webapp's `/auth/callback` invite path. `keepSession` is the
    /// self-invite: the login is linked server-side, the current session stays.
    func handleAuthCallback(key: String, databaseId: String?, invite: String? = nil, keepSession: Bool = false) async throws {
        var params: [String: String] = [:]
        if let databaseId { params["db"] = databaseId }
        if let invite { params["invite"] = invite }

        let response: AuthResponse = try await exchange {
            try await api.requestWithToken("auth", params: params, bearerToken: key)
        }

        try applyAuthResponse(response, keepSession: keepSession)
    }

    /// Run a sign-in request (`GET /auth` or a passkey POST), translating
    /// the API's 400 `Invalid or expired invite` into `.inviteInvalid`.
    func exchange(_ request: () async throws -> AuthResponse) async throws -> AuthResponse {
        do {
            return try await request()
        } catch let error as APIError where error.isServerError(400, message: "Invalid or expired invite") {
            throw APIError.inviteInvalid
        }
    }

    /// The single sink for every auth response — OAuth callback, passkey
    /// sign-in and creation, token refresh. Validates before touching any
    /// state, so a rejected response leaves the previous session intact.
    ///
    /// - An invite `conflict` throws `.inviteConflict`: the invite was not
    ///   accepted, so the flow that asked for it failed.
    /// - `keepSession` (self-invite on the user's own entity) stops there:
    ///   the new login is already linked server-side, and the response's
    ///   token and database list are discarded so the session stays as is.
    /// - An empty database list throws `.noAccessibleDatabases` — the app
    ///   has no database creation (`PUT /new` is not ported), so a token
    ///   without databases would strand the user on an empty picker. Support
    ///   databases count: a support-only identity is signed in with databases.
    /// - A different person in the active database runs the sign-out sweep
    ///   minus credentials, so no cached content leaks across identities.
    func applyAuthResponse(_ response: AuthResponse, keepSession: Bool = false) throws {
        if response.conflict == "invite" {
            throw APIError.inviteConflict
        }

        if keepSession { return }

        let newDatabases = response.accounts ?? []
        let newSupport = response.support ?? []

        guard !newDatabases.isEmpty || !newSupport.isEmpty else {
            throw APIError.noAccessibleDatabases
        }

        guard let newToken = response.token else {
            throw APIError.invalidResponse
        }

        // Identity comparison must read pre-exchange state. `currentUserId`
        // (the person entity in the active database) is the stable identity
        // marker — the login identity differs per provider for one person.
        // In a support database `currentUserId` is the database entity for
        // every staff member, so the login identity is compared there too —
        // when both sides are known (`user` is not persisted across launches).
        let hadSession = api.token != nil
        let previousUserId = currentUserId
        let wasSupport = isCurrentDatabaseSupport
        let previousLogin = user?.loginIdentity

        databases = newDatabases
        supportDatabases = newSupport
        storeToken(newToken, expires: response.expires)
        user = response.user

        let newLogin = response.user?.loginIdentity
        let loginChanged = wasSupport && previousLogin != nil && newLogin != nil && previousLogin != newLogin

        if hadSession, api.databaseId != nil, previousUserId != currentUserId || loginChanged {
            if currentUserId == nil {
                // The new identity has no access to the active database —
                // fall back to the database picker.
                api.databaseId = nil
            }
            resetSessionState()
        }
    }

    /// Cache/session sweep for an identity change without a sign-out — the
    /// shared part of `logOut()`, minus credential storage (a fresh token
    /// was just saved). The `logOutToken` bump resets every window's
    /// in-memory state.
    private func resetSessionState() {
        MenuModel.clearCache()
        EntityColorCache.shared.clear()
        EntityDetailModel.clearCache()
        SessionState.clearStored()
        SessionState.bumpEpoch()
        WindowSessionStore.clearStored()
        CommandPaletteModel.clearStored()
        ImageCache.shared.clear()
        FileManager.default.clearTemporaryFiles()
        logOutToken &+= 1
    }

    // MARK: - Support grant end

    /// In-flight grant recheck, so a burst of 403s triggers one refresh.
    private var supportRecheckTask: Task<Void, Never>?

    /// True when `id` is a support database — an own database of the same
    /// id wins, as in `database(for:)`. Expired grants count too.
    private func isSupportDatabase(_ id: String?) -> Bool {
        guard let id else { return false }

        return supportDatabases.contains { $0._id == id } && !databases.contains { $0._id == id }
    }

    /// 401 to the stored session: in a support database the grant ended or
    /// was revoked, so leave that database; anywhere else, sign out.
    private func handleUnauthorized(databaseId: String?) {
        if isSupportDatabase(databaseId) {
            leaveSupportDatabase(databaseId)
        } else {
            logOut()
        }
    }

    /// 403 in the active support database. Support also gets 403 for logins
    /// and its own grant while the grant runs, so the grant is rechecked
    /// with a token refresh — `applyAuthResponse` leaves the database when
    /// the API no longer lists it — instead of leaving on every 403.
    private func handleForbidden(databaseId: String?) {
        guard let databaseId, databaseId == api.databaseId, isSupportDatabase(databaseId),
              supportRecheckTask == nil else { return }

        supportRecheckTask = Task { [weak self] in
            try? await self?.refreshToken()
            self?.leaveEndedSupportDatabase()
            self?.supportRecheckTask = nil
        }
    }

    /// Leaves the active support database once its grant has run out
    /// (`database(for:)` no longer returns it), unless it is also a saved
    /// public database — so its loaded data doesn't stay on screen.
    func leaveEndedSupportDatabase() {
        guard let id = api.databaseId, isSupportDatabase(id),
              database(for: id) == nil, !publicDatabases.contains(id) else { return }

        leaveSupportDatabase(id)
    }

    /// Drops the active database back to the picker and sweeps every cache
    /// and window state — a no-op when `id` is no longer the active one.
    private func leaveSupportDatabase(_ id: String?) {
        guard let id, id == api.databaseId else { return }

        api.databaseId = nil
        UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
        resetSessionState()
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

    /// Bumped on sign-out and cache clear. Every window's `WindowRootView`
    /// observes it and resets its own per-window state — chat conversation,
    /// search, navigation, palette, scene snapshot. Replaces the previous
    /// single-closure hook, which was last-writer-wins once multiple
    /// windows exist.
    private(set) var logOutToken = 0

    /// Reset everything — credentials, caches, temp files, and (via
    /// `logOutToken`) all in-memory session state in every window. Only
    /// app-general settings survive: language, column widths, table page
    /// size. Returns the user to `AuthView`.
    func logOut() {
        KeychainService.deleteToken()
        KeychainService.deleteTokenExpiry()
        KeychainService.deleteDatabases()
        KeychainService.deleteSupportDatabases()
        api.token = nil
        api.suppressToken = false
        api.databaseId = nil
        tokenExpiresAt = nil
        databases = []
        supportDatabases = []
        publicDatabases = []
        user = nil
        UserDefaults.standard.removeObject(forKey: "auth.lastDatabaseId")
        resetSessionState()
    }

    /// ⇧⌘R — drop everything local except credentials: every cache, temp
    /// files, and all `ui.*` settings (column widths, page size, session
    /// snapshots). The in-app language, the Keychain token, database list,
    /// and last database pointer survive, so the user stays signed in and
    /// keeps their language. In-memory session state (chat, search,
    /// navigation, deep links) resets in every window via the same
    /// `logOutToken` bump sign-out uses.
    func clearLocalData() {
        let defaults = UserDefaults.standard
        // The sign-out epoch is a monotonic counter, not a UI preference —
        // keep it across the sweep (like the language) so it stays useful.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("ui.") && key != AppLanguage.storageKey && key != SessionState.epochKey {
            defaults.removeObject(forKey: key)
        }
        SessionState.bumpEpoch()
        MenuModel.clearCache()
        EntityColorCache.shared.clear()
        EntityDetailModel.clearCache()
        ImageCache.shared.clear()
        FileManager.default.clearTemporaryFiles()
        logOutToken &+= 1
    }

    /// Permanently delete the signed-in user's person entity in the active
    /// database. Before deleting the entity, hard-deletes the user's auth
    /// properties (`entu_user`, `entu_api_key`) so a stale passkey or OAuth
    /// provider mapping cannot be matched on a later sign-in.
    /// After success, drops the database from the local list and either
    /// switches to another database or signs out entirely.
    func deleteCurrentAccount() async throws {
        // In a support database the "user" is the database entity itself —
        // never delete it as if it were the user's own person.
        guard !isCurrentDatabaseSupport,
              let activeId = api.databaseId,
              let database = database(for: activeId),
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
        let authPropertyNames = ["entu_user", "entu_api_key"]

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
