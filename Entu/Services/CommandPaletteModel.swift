// Command-palette state (⌘K) — overlay visibility, the query text, and
// the per-database recently-viewed entities shown in the empty state.

import Foundation
import Observation

/// One recently viewed entity — enough to render a palette row and open
/// the entity again without a fetch.
struct RecentEntity: Codable, Identifiable, Equatable {
    let _id: String
    let name: String
    var typeLabel: String? = nil
    var hasPhoto = false

    var id: String { _id }
}

/// Shared command-palette state (⌘K): overlay visibility, query text, and
/// the persisted per-database recents. Non-sensitive UI pointers only
/// (entity ids + display names), stored under the `ui.*` scheme like the
/// session snapshots — wiped by Clear Cache's `ui.*` sweep and explicitly
/// on sign-out via `clearStored()`.
@MainActor @Observable
final class CommandPaletteModel {
    /// True while the palette overlay is shown.
    var isOpen = false

    /// Free text in the palette field (the remainder after any tokens).
    var query = ""

    /// Query-grammar tokens built in the field — collection, filters
    /// (sealed + draft), sort.
    var queryState = PaletteQueryState()

    /// Number of modal sheets currently on screen (see
    /// `blocksCommandPalette()`). While > 0 the ⌘K toggle no-ops — the
    /// palette would otherwise open invisibly behind the sheet.
    var modalDepth = 0

    /// Recents for the active database, most recent first. Refreshed from
    /// the store on `open` — recording is write-through (static), so the
    /// list is always current when the palette appears.
    private(set) var recents: [RecentEntity] = []

    /// Entity types for type-token suggestions — fetched by the palette
    /// view on first use and kept across opens. Invalidated by `open`
    /// when the database or in-app language changes.
    var typeOptions: [PaletteEntityType] = []
    private var typeOptionsContext: String?

    private static let storageKey = "ui.recentEntities"
    private static let maxRecents = 10

    /// Open the palette fresh (empty query, no tokens) for the given database.
    func open(databaseId: String?) {
        guard modalDepth == 0 else { return }

        let context = "\(AppLanguage.resolvedLanguageCode):\(databaseId ?? "")"
        if context != typeOptionsContext {
            typeOptions = []
            typeOptionsContext = context
        }
        query = ""
        queryState = PaletteQueryState()
        recents = Self.load(databaseId: databaseId)
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    /// ⌘K. No-ops while a modal sheet is up (`modalDepth`) — the palette
    /// would otherwise open invisibly behind it.
    func toggle(databaseId: String?) {
        if isOpen {
            close()
        } else {
            open(databaseId: databaseId)
        }
    }

    /// Drop all in-memory state — sign-out hook, alongside `clearStored()`.
    /// Sign-out dismisses every sheet, so zeroing `modalDepth` here is a
    /// safety net against an unbalanced appear/disappear leaving ⌘K dead.
    func reset() {
        isOpen = false
        query = ""
        queryState = PaletteQueryState()
        recents = []
        modalDepth = 0
    }

    // MARK: - Recents store

    /// Record a viewed entity for `databaseId`, newest first, deduplicated
    /// by id, capped at `maxRecents`. Write-through static so the recorder
    /// (`EntityDetailModel.load`) needs no reference to this model.
    static func record(_ entity: RecentEntity, databaseId: String?) {
        guard let databaseId else { return }

        var all = loadAll()
        var list = all[databaseId] ?? []
        list.removeAll { $0._id == entity._id }
        list.insert(entity, at: 0)
        all[databaseId] = Array(list.prefix(maxRecents))
        storeAll(all)
    }

    private static func load(databaseId: String?) -> [RecentEntity] {
        guard let databaseId else { return [] }
        return loadAll()[databaseId] ?? []
    }

    private static func loadAll() -> [String: [RecentEntity]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [RecentEntity]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func storeAll(_ all: [String: [RecentEntity]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Remove all persisted recents. Called on sign-out so a different user
    /// on the same device can't see the previous user's viewing trail
    /// (mirrors `SessionState.clearStored`).
    static func clearStored() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
