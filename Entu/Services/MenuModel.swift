// Sidebar menu loading — fetches menu entities, groups and sorts them,
// resolves each menu's addable types, and caches the result per database.

import Foundation

/// Type entity that can be added under a menu (or under another type).
/// Mirrors the webapp's `addFromEntities` items in `stores/menu.js`.
struct AddFromType: Identifiable, Hashable {
    let _id: String
    /// Label in the active in-app language — used for in-app UI.
    let label: String
    /// English label (falls back to `label` when the type has no English
    /// value) — used in the menu bar, which follows the system language.
    let englishLabel: String
    var id: String { _id }
}

/// Cached, language-aware menu payload. Stored as a value type so the static
/// cache holds resolved labels per language without re-fetching from the API.
private struct CachedMenu {
    let groups: [MenuGroup]
    let queryById: [String: String]
    let addFromTypes: [String: [AddFromType]]
    let parentTypesByChild: [String: [String]]
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

    /// Menu (or type) entity ID → list of types that can be added under it.
    /// Drives the toolbar Add button at menu level (`activeMenu.addFrom`)
    /// and per-entity child add (`addChildOptions`) — same data source as
    /// webapp's `addFromEntities` in `stores/menu.js`.
    var addFromTypes: [String: [AddFromType]] = [:]

    /// Inverse of `addFromTypes` — child type ID → list of parent type IDs
    /// that allow it via their `add_from`. Drives the Parents drawer's
    /// candidate filter (mirrors webapp's `parentQuery` narrowing).
    var parentTypesByChild: [String: [String]] = [:]

    private let api: APIClient

    /// Shared across screens — keyed by `"<lang>:<databaseId>"` so menus
    /// resolved in different languages (or for different databases) coexist
    /// and switching back to a previously-seen language is instant.
    private static var cache: [String: CachedMenu] = [:]

    /// Clears the menu cache — call on sign-out so a new user can't see the
    /// previous user's menu while their fetch is in flight.
    static func clearCache() {
        cache = [:]
    }

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Load

    /// Fetch all menu-type entities, then group and sort them for sidebar display.
    /// Hits the language-keyed cache first; only fetches on a miss.
    func load() async {
        let key = Self.cacheKey(databaseId: api.databaseId)

        if let cached = Self.cache[key] {
            groups = cached.groups
            queryById = cached.queryById
            addFromTypes = cached.addFromTypes
            parentTypesByChild = cached.parentTypesByChild
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response: EntityListResponse = try await api.get("entity", params: [
                "_type.string": "menu",
                "props": "ordinal.number,group,name,query.string"
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

            // Fetch all entity-type entities that declare an `add_from`,
            // then group them by which menu/type they can be added under.
            let (addFromMap, parentMap) = await fetchAddFromTypes()

            queryById = newQueryById
            groups = newGroups
            addFromTypes = addFromMap
            parentTypesByChild = parentMap
            Self.cache[key] = CachedMenu(
                groups: newGroups,
                queryById: newQueryById,
                addFromTypes: addFromMap,
                parentTypesByChild: parentMap
            )
        } catch {
            groups = []
            queryById = [:]
            addFromTypes = [:]
            parentTypesByChild = [:]
        }
    }

    // MARK: - add_from types

    /// Look up all entity types that declare `add_from`, then build two
    /// inverse maps from the same response:
    ///   - parent → list of child types that can be added under it (drives
    ///     toolbar Add and Add child).
    ///   - child type → list of parent type IDs that allow it (drives the
    ///     Parents drawer's candidate filter).
    private func fetchAddFromTypes() async -> (addFrom: [String: [AddFromType]], parents: [String: [String]]) {
        let response: EntityListResponse?
        do {
            response = try await api.get("entity", params: [
                "_type.string": "entity",
                "add_from._id.exists": "true",
                "props": "name,label,add_from.reference"
            ])
        } catch {
            return ([:], [:])
        }

        var addFromMap: [String: [AddFromType]] = [:]
        var parentMap: [String: [String]] = [:]
        for type in response?.entities ?? [] {
            let labelValues = type.additionalProperties?["label"]
            let label = PropertyValue.localized(labelValues) ??
                        PropertyValue.localized(type.name) ?? type._id
            // Prefer the English label for the menu bar; fall back to
            // untagged, then to the active-language label.
            let englishLabel = labelValues?.first { $0.language == "en" }?.string
                ?? labelValues?.first { $0.language == nil }?.string
                ?? label
            let entry = AddFromType(_id: type._id, label: label, englishLabel: englishLabel)

            for parent in type.additionalProperties?["add_from"] ?? [] {
                guard let parentId = parent.reference else { continue }
                addFromMap[parentId, default: []].append(entry)
                parentMap[type._id, default: []].append(parentId)
            }
        }

        // Stable alphabetical order per parent — mirrors webapp's sort.
        for key in addFromMap.keys {
            addFromMap[key]?.sort { $0.label.localizedCompare($1.label) == .orderedAscending }
        }
        return (addFromMap, parentMap)
    }

    /// Cache key combining the active in-app language with the database id.
    private static func cacheKey(databaseId: String?) -> String {
        "\(AppLanguage.current.rawValue):\(databaseId ?? "")"
    }
}
