// Sidebar menu loading — fetches menu entities, groups and sorts them,
// resolves each menu's creatable types (`add_entity`) and parents
// (`add_parent`), the `add_from` child types, and caches the result per database.

import Foundation

/// Entity type that can be created — from a menu (`add_entity`) or under
/// another entity (`add_from`). Mirrors the webapp's `{ value, label }`
/// options in `stores/menu.js`.
struct AddFromType: Identifiable, Hashable {
    let _id: String
    /// Label in the active in-app language — used for in-app UI.
    let label: String
    /// English label (falls back to `label` when the type has no English
    /// value) — used in the menu bar, which follows the system language.
    let englishLabel: String
    var id: String { _id }

    /// Build from a type entity's `label` / `name` values: the localized
    /// label, else the name, else the id.
    init(_id: String, labelValues: [PropertyValue]?, nameValues: [PropertyValue]?) {
        let label = PropertyValue.localized(labelValues) ?? PropertyValue.localized(nameValues) ?? _id
        self._id = _id
        self.label = label
        // Prefer the English label for the menu bar; fall back to
        // untagged, then to the active-language label.
        self.englishLabel = labelValues?.first { $0.language == "en" }?.string
            ?? labelValues?.first { $0.language == nil }?.string
            ?? label
    }
}

/// Cached, language-aware menu payload. Stored as a value type so the static
/// cache holds resolved labels per language without re-fetching from the API.
private struct CachedMenu {
    let groups: [MenuGroup]
    let queryById: [String: String]
    let menuAddEntities: [String: [AddFromType]]
    let menuAddParents: [String: [String]]
    let addFromTypes: [String: [AddFromType]]
    let parentTypesByChild: [String: [String]]
}

/// Result of the `add_from` lookup — both inverse maps plus every type the
/// response carried, so `add_entity` labels can reuse them.
private struct AddFromResult {
    var addFrom: [String: [AddFromType]] = [:]
    var parents: [String: [String]] = [:]
    var typesById: [String: AddFromType] = [:]
}

/// Fetches menu entities from the API, groups and sorts them for the sidebar.
@MainActor @Observable
final class MenuModel {
    /// Menu item groups for sidebar display.
    var groups: [MenuGroup] = []

    /// True while the menu is being fetched.
    var isLoading = false

    /// Menu entity ID → query string lookup. Used to resolve NavigationLink selection.
    var queryById: [String: String] = [:]

    /// The menu item with `menuId`, from any group. The single lookup behind
    /// the list title, the window/tab title, and the palette's menu rows.
    func item(for menuId: String) -> MenuEntity? {
        groups.lazy.flatMap(\.items).first { $0._id == menuId }
    }

    /// Menu entity ID → types its `add_entity` lists, sorted by label.
    /// Drives the menu-level New button and palette rows — webapp's
    /// `activeMenu.addEntities` in `stores/menu.js`.
    var menuAddEntities: [String: [AddFromType]] = [:]

    /// Menu entity ID → its `add_parent` ids, sent as one `_parent` each on
    /// every entity created from that menu (webapp's `activeMenu.addParents`).
    var menuAddParents: [String: [String]] = [:]

    /// Entity (or type) ID → list of types that can be added under it via
    /// their `add_from`. Drives per-entity child add (`addChildOptions`) —
    /// same data source as webapp's `addFromEntities` in `stores/menu.js`.
    var addFromTypes: [String: [AddFromType]] = [:]

    /// Inverse of `addFromTypes` — child type ID → list of parent type IDs
    /// that allow it via their `add_from`. Drives the Parents drawer's
    /// candidate filter (mirrors webapp's `parentQuery` narrowing).
    var parentTypesByChild: [String: [String]] = [:]

    private let api: APIClient

    /// Shared across screens and windows — memoizes the fetch *task* (not
    /// just its result), keyed by `"<lang>:<databaseId>"`, so concurrent
    /// loaders (e.g. several restored windows at launch) await ONE shared
    /// request instead of each firing their own. Menus resolved in
    /// different languages (or for different databases) coexist and
    /// switching back to a previously-seen language is instant. A failed
    /// fetch removes its task in `load()` so the next call retries.
    private static var cache: [String: Task<CachedMenu?, Never>] = [:]

    /// Completed results by the same key — the synchronous fast path, so a
    /// cache hit (e.g. switching back to a previously-seen language) applies
    /// without even a task-await suspension.
    private static var completed: [String: CachedMenu] = [:]

    /// Clears the menu cache — call on sign-out so a new user can't see the
    /// previous user's menu. Dropping the tasks also orphans any in-flight
    /// fetch: its result stays unreachable for later loaders.
    static func clearCache() {
        cache = [:]
        completed = [:]
    }

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Load

    /// Fetch all menu-type entities, then group and sort them for sidebar display.
    /// Joins the shared per-language/database fetch task; only a miss fetches.
    func load() async {
        let key = Self.cacheKey(databaseId: api.databaseId)

        if let cached = Self.completed[key] {
            apply(cached)
            return
        }

        let task = Self.cache[key] ?? {
            let task = Task { [api] in await Self.fetch(api: api) }
            Self.cache[key] = task
            return task
        }()

        isLoading = true
        defer { isLoading = false }

        guard let cached = await task.value else {
            // Failed — drop the shared task (unless a retry already
            // replaced it) so the next load fetches again.
            if Self.cache[key] == task { Self.cache[key] = nil }
            groups = []
            queryById = [:]
            menuAddEntities = [:]
            menuAddParents = [:]
            addFromTypes = [:]
            parentTypesByChild = [:]
            return
        }

        Self.completed[key] = cached
        apply(cached)
    }

    private func apply(_ cached: CachedMenu) {
        groups = cached.groups
        queryById = cached.queryById
        menuAddEntities = cached.menuAddEntities
        menuAddParents = cached.menuAddParents
        addFromTypes = cached.addFromTypes
        parentTypesByChild = cached.parentTypesByChild
    }

    /// The actual fetch behind the shared cache task — menu entities and
    /// `add_from` types are independent requests, run concurrently; then any
    /// `add_entity` type the `add_from` response didn't carry is fetched for
    /// its label. Returns nil on failure (the menu fetch is the load-bearing
    /// one; `add_from` and labels degrade to empty on their own errors).
    private static func fetch(api: APIClient) async -> CachedMenu? {
        async let addFrom = fetchAddFromTypes(api: api)

        do {
            let response: EntityListResponse = try await api.get("entity", params: [
                "_type.string": "menu",
                "props": "ordinal.number,group,name,query.string,add_entity.reference,add_parent.reference"
            ])

            // Convert raw API entities to MenuEntity models, resolving localized values.
            // Skip entities without a query string.
            let menuEntities = response.entities.compactMap { entity -> MenuEntity? in
                guard let query = PropertyValue.localized(entity.additionalProperties?["query"]) else { return nil }

                return MenuEntity(
                    _id: entity._id,
                    name: PropertyValue.localized(entity.name) ?? entity._id,
                    query: query,
                    group: PropertyValue.localized(entity.additionalProperties?["group"]),
                    ordinal: entity.additionalProperties?["ordinal"]?.first?.number
                )
            }

            // Build ID → query lookup
            var newQueryById: [String: String] = [:]
            for entity in menuEntities {
                newQueryById[entity._id] = entity.query
            }

            // Group by group label (case-insensitive)
            var groupMap: [String: [MenuEntity]] = [:]
            for entity in menuEntities {
                let groupKey = entity.group?.lowercased() ?? ""
                groupMap[groupKey, default: []].append(entity)
            }

            // Sort matching the webapp's menuSorter
            let newGroups = groupMap.map { _, items in
                MenuGroup(
                    name: items.first?.group,
                    items: items.sorted { entuSort($0.ordinal, $0.name, $1.ordinal, $1.name) }
                )
            }.sorted { entuSort($0.ordinal, $0.name, $1.ordinal, $1.name) }

            // Menu ID → add_entity type ids / add_parent ids (deduped, in order).
            var addEntityIds: [String: [String]] = [:]
            var addParents: [String: [String]] = [:]
            for entity in response.entities {
                let typeIds = uniqueReferences(entity.additionalProperties?["add_entity"])
                let parentIds = uniqueReferences(entity.additionalProperties?["add_parent"])
                if !typeIds.isEmpty { addEntityIds[entity._id] = typeIds }
                if !parentIds.isEmpty { addParents[entity._id] = parentIds }
            }

            let addFromResult = await addFrom
            var typesById = addFromResult.typesById
            let missing = Set(addEntityIds.values.joined()).subtracting(typesById.keys)
            for (id, type) in await fetchTypes(api: api, ids: missing) {
                typesById[id] = type
            }

            // Types whose label couldn't be fetched (e.g. no read right) are dropped.
            let addEntities = addEntityIds.mapValues { ids in
                ids.compactMap { typesById[$0] }.sorted(by: labelOrder)
            }.filter { !$0.value.isEmpty }

            return CachedMenu(
                groups: newGroups,
                queryById: newQueryById,
                menuAddEntities: addEntities,
                menuAddParents: addParents,
                addFromTypes: addFromResult.addFrom,
                parentTypesByChild: addFromResult.parents
            )
        } catch {
            _ = await addFrom
            return nil
        }
    }

    // MARK: - add_entity types

    /// Reference ids of `values`, deduped in their original order.
    nonisolated private static func uniqueReferences(_ values: [PropertyValue]?) -> [String] {
        var seen = Set<String>()
        return (values ?? []).compactMap(\.reference).filter { seen.insert($0).inserted }
    }

    /// Fetch the `name` / `label` of each type id concurrently — for
    /// `add_entity` targets the `add_from` response didn't include (webapp's
    /// one-type-by-id fetch). Failed fetches are left out.
    private static func fetchTypes(api: APIClient, ids: Set<String>) async -> [String: AddFromType] {
        await withTaskGroup(of: AddFromType?.self) { group in
            for id in ids {
                group.addTask {
                    let response: EntityDetailResponse? = try? await api.get(
                        "entity/\(id)",
                        params: ["props": "name,label"]
                    )
                    guard let entity = response?.entity else { return nil }
                    return AddFromType(
                        _id: entity._id,
                        labelValues: entity.properties["label"],
                        nameValues: entity.properties["name"]
                    )
                }
            }
            var map: [String: AddFromType] = [:]
            for await type in group {
                if let type { map[type._id] = type }
            }
            return map
        }
    }

    /// Stable alphabetical order by label — mirrors webapp's sort.
    nonisolated private static func labelOrder(_ lhs: AddFromType, _ rhs: AddFromType) -> Bool {
        lhs.label.localizedCompare(rhs.label) == .orderedAscending
    }

    // MARK: - add_from types

    /// Look up all entity types that declare `add_from`, then build two
    /// inverse maps from the same response:
    ///   - parent → list of child types that can be added under it (drives
    ///     Add child).
    ///   - child type → list of parent type IDs that allow it (drives the
    ///     Parents drawer's candidate filter).
    private static func fetchAddFromTypes(api: APIClient) async -> AddFromResult {
        let response: EntityListResponse?
        do {
            response = try await api.get("entity", params: [
                "_type.string": "entity",
                "add_from._id.exists": "true",
                "props": "name,label,add_from.reference"
            ])
        } catch {
            return AddFromResult()
        }

        var result = AddFromResult()
        for type in response?.entities ?? [] {
            let entry = AddFromType(
                _id: type._id,
                labelValues: type.additionalProperties?["label"],
                nameValues: type.name
            )
            result.typesById[type._id] = entry

            for parent in type.additionalProperties?["add_from"] ?? [] {
                guard let parentId = parent.reference else { continue }
                result.addFrom[parentId, default: []].append(entry)
                result.parents[type._id, default: []].append(parentId)
            }
        }

        for key in result.addFrom.keys {
            result.addFrom[key]?.sort(by: labelOrder)
        }
        return result
    }

    /// Cache key combining the active in-app language with the database id.
    private static func cacheKey(databaseId: String?) -> String {
        "\(AppLanguage.current.rawValue):\(databaseId ?? "")"
    }
}
