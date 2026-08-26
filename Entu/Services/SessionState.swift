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

    /// Main results as table instead of list+detail — per-window (each tab
    /// picks its own view), persisted in the snapshot like the rest.
    var showTable = false

    /// Ids of expanded sidebar groups; nil = never seeded (SidebarView seeds
    /// the first group), while an empty set is a valid all-collapsed choice.
    var expandedGroupIds: Set<String>?

    /// True while a saved snapshot is being applied (launch or database
    /// switch). MainView's side-effect `onChange` handlers — which reset the
    /// history when the selection changes, or clear the pinned entity when
    /// search becomes non-empty — check this so they don't clobber the
    /// state being restored. Also gates `persist`.
    private(set) var isRestoring = false

    private static let storageKey = "ui.session"

    /// A restorable snapshot of everything that makes up "where I left off".
    /// Every field defaults to the empty/dashboard state so seed snapshots
    /// (`Snapshot(pinnedId:)`, `Snapshot(menuId:)`) read cleanly.
    struct Snapshot: Codable {
        var menuId: String? = nil
        var entityId: String? = nil
        var history: [String] = []
        var pinnedId: String? = nil
        var searchText: String = ""
        var advancedQuery: String? = nil
        var chatOpen: Bool = false
        /// Optional so snapshots persisted before the field existed still
        /// decode (synthesized Codable uses `decodeIfPresent` for optionals).
        var showTable: Bool? = nil
        /// Optional for the same back-compat reason; nil also means "never
        /// seeded" so SidebarView knows to expand the first group.
        var expandedGroupIds: Set<String>? = nil
    }

    /// A per-window snapshot for `WindowSessionStore` — the snapshot plus the
    /// database it belongs to and the sign-out epoch it was written under, so
    /// a snapshot is ignored on restore when the app-global database has
    /// changed or a different user has since signed in (see `currentEpoch`).
    struct SceneSnapshot: Codable {
        var databaseId: String
        var epoch: Int
        var snapshot: Snapshot
    }

    // MARK: - Sign-out epoch

    /// Bumped on every sign-out. Stamped into each `SceneSnapshot`; a
    /// snapshot whose epoch differs from the current one is discarded on
    /// restore. A *disconnected* iPad scene (routine with multi-window) keeps
    /// its entry in `WindowSessionStore`'s in-memory map after sign-out and
    /// can get re-persisted by another window, so this epoch is what stops a
    /// different user on the same device from restoring the previous user's
    /// search text and navigation from that dormant scene.
    static let epochKey = "ui.sessionEpoch"

    static var currentEpoch: Int {
        UserDefaults.standard.integer(forKey: epochKey)
    }

    /// Invalidate every persisted scene snapshot (see `currentEpoch`).
    static func bumpEpoch() {
        UserDefaults.standard.set(currentEpoch + 1, forKey: epochKey)
    }

    // MARK: - Persist

    /// The current navigation state plus the given view-side fields as a
    /// snapshot — shared by the per-database store and the scene storage.
    func currentSnapshot(searchText: String, advancedQuery: String?, chatOpen: Bool) -> Snapshot {
        Snapshot(
            menuId: selectedMenuId,
            entityId: selectedEntityId,
            history: entityHistory,
            pinnedId: pinnedEntityId,
            searchText: searchText,
            advancedQuery: advancedQuery,
            chatOpen: chatOpen,
            showTable: showTable,
            expandedGroupIds: expandedGroupIds
        )
    }

    /// Save the current session for `databaseId`. No-op while restoring (so a
    /// half-applied restore never writes back over the store). With several
    /// windows open, each one writes on its own changes — last writer wins,
    /// which is acceptable for these tiny UI pointers.
    func persist(databaseId: String?, searchText: String, advancedQuery: String?, chatOpen: Bool) {
        guard !isRestoring, let databaseId else { return }

        var all = Self.loadAll()
        all[databaseId] = currentSnapshot(searchText: searchText, advancedQuery: advancedQuery, chatOpen: chatOpen)
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
        showTable = snapshot.showTable ?? false
        expandedGroupIds = snapshot.expandedGroupIds
    }

    /// Reset navigation to the empty (dashboard) state.
    func clearNavigation() {
        selectedMenuId = nil
        selectedEntityId = nil
        entityHistory = []
        pinnedEntityId = nil
        showTable = false
        expandedGroupIds = nil
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
        UserDefaults.standard.codable([String: Snapshot].self, forKey: storageKey) ?? [:]
    }

    private static func storeAll(_ all: [String: Snapshot]) {
        UserDefaults.standard.setCodable(all, forKey: storageKey)
    }

    /// Remove all persisted snapshots. Called on sign-out so a different user
    /// on the same device can't see the previous user's last-open entities or
    /// search text (mirrors the JWT / database-list / cache cleanup).
    static func clearStored() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
