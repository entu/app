// Restorable navigation state — selected menu, open entity, history, and
// pinned entity, snapshotted per database and restored on relaunch.

import Foundation
import Observation

/// The single source of truth for restorable navigation state — "where the
/// user left off." Holds the selected menu, open entity, back/forward
/// history, and pinned entity (previously loose `@State` in `MainView`), and
/// persists a snapshot (including the search and chat-open state) per
/// database so each remembers its place and it's restored on relaunch.
///
/// Non-sensitive UI pointers only (menu/entity ids for the *current*
/// database), stored under the `ui.*` scheme like the other UI preferences.
@MainActor @Observable
final class SessionState {
    var selectedMenuId: String?
    var selectedEntityId: String?
    var entityHistory: [String] = []
    var pinnedEntityId: String?

    /// True while a saved snapshot is being applied (launch or database
    /// switch). MainView's side-effect `onChange` handlers — which reset the
    /// history when the selection changes, or clear the pinned entity when
    /// search becomes non-empty — check this so they don't clobber the
    /// state being restored. Also gates `persist`.
    private(set) var isRestoring = false

    private static let storageKey = "ui.session"

    /// A restorable snapshot of everything that makes up "where I left off".
    struct Snapshot: Codable {
        var menuId: String?
        var entityId: String?
        var history: [String] = []
        var pinnedId: String?
        var searchText: String = ""
        var advancedQuery: String?
        var chatOpen: Bool = false
    }

    // MARK: - Persist

    /// Save the current session for `databaseId`. No-op while restoring (so a
    /// half-applied restore never writes back over the store).
    func persist(databaseId: String?, searchText: String, advancedQuery: String?, chatOpen: Bool) {
        guard !isRestoring, let databaseId else { return }

        var all = Self.loadAll()
        all[databaseId] = Snapshot(
            menuId: selectedMenuId,
            entityId: selectedEntityId,
            history: entityHistory,
            pinnedId: pinnedEntityId,
            searchText: searchText,
            advancedQuery: advancedQuery,
            chatOpen: chatOpen
        )
        Self.storeAll(all)
    }

    /// The saved snapshot for `databaseId`, if any.
    func snapshot(databaseId: String?) -> Snapshot? {
        guard let databaseId else { return nil }
        return Self.loadAll()[databaseId]
    }

    // MARK: - Restore

    /// Apply a snapshot's navigation fields to this model.
    func applyNavigation(_ snapshot: Snapshot) {
        selectedMenuId = snapshot.menuId
        selectedEntityId = snapshot.entityId
        entityHistory = snapshot.history
        pinnedEntityId = snapshot.pinnedId
    }

    /// Reset navigation to the empty (dashboard) state.
    func clearNavigation() {
        selectedMenuId = nil
        selectedEntityId = nil
        entityHistory = []
        pinnedEntityId = nil
    }

    /// Run `body` with persistence and MainView's side-effect handlers
    /// suppressed, then re-enable them a beat later — long enough for
    /// SwiftUI to process the state changes the restore triggered.
    func withRestoring(_ body: () -> Void) {
        isRestoring = true
        body()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            isRestoring = false
        }
    }

    // MARK: - Store

    private static func loadAll() -> [String: Snapshot] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Snapshot].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func storeAll(_ all: [String: Snapshot]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Remove all persisted snapshots. Called on sign-out so a different user
    /// on the same device can't see the previous user's last-open entities or
    /// search text (mirrors the JWT / database-list / cache cleanup).
    static func clearStored() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
