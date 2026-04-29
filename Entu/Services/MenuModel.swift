// Fetches menu entities from the API and groups them for the sidebar.
// Menu items define which entity types appear in the navigation
// (e.g. "People", "Documents") and carry query strings to filter the list.
//
// @Observable = SwiftUI views automatically update when "groups" or "isLoading" change.
// @MainActor = runs on the main thread for safe UI updates.

import Foundation

/// Type entity that can be added under a menu (or under another type).
/// Mirrors the webapp's `addFromEntities` items in `stores/menu.js`.
struct AddFromType: Identifiable, Hashable {
    let _id: String
    let label: String
    var id: String { _id }
}

/// Cached, language-aware menu payload. Stored as a value type so the static
/// cache holds resolved labels per language without re-fetching from the API.
private struct CachedMenu {
    let groups: [MenuGroup]
    let queryById: [String: String]
    let addFromTypes: [String: [AddFromType]]
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

    /// Fetch all menu-type entities, then group and sort them for sidebar display.
    /// Hits the language-keyed cache first; only fetches on a miss.
    func load() async {
        let key = Self.cacheKey(databaseId: api.databaseId)

        if let cached = Self.cache[key] {
            groups = cached.groups
            queryById = cached.queryById
            addFromTypes = cached.addFromTypes
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
            let addFromMap = await fetchAddFromTypes()

            queryById = newQueryById
            groups = newGroups
            addFromTypes = addFromMap
            Self.cache[key] = CachedMenu(groups: newGroups, queryById: newQueryById, addFromTypes: addFromMap)
        } catch {
            groups = []
            queryById = [:]
            addFromTypes = [:]
        }
    }

    /// Look up all entity types that declare `add_from`, then build a map
    /// from each `add_from` reference (a menu id or type id) to the list
    /// of types that can be created under it.
    private func fetchAddFromTypes() async -> [String: [AddFromType]] {
        let response: EntityListResponse?
        do {
            response = try await api.get("entity", params: [
                "_type.string": "entity",
                "add_from._id.exists": "true",
                "props": "name,label,add_from.reference"
            ])
        } catch {
            return [:]
        }

        var map: [String: [AddFromType]] = [:]
        for type in response?.entities ?? [] {
            let label = PropertyValue.localized(type.additionalProperties?["label"]) ??
                        PropertyValue.localized(type.name) ?? type._id
            let entry = AddFromType(_id: type._id, label: label)

            for parent in type.additionalProperties?["add_from"] ?? [] {
                guard let parentId = parent.reference else { continue }
                map[parentId, default: []].append(entry)
            }
        }

        // Stable alphabetical order per parent — matches webapp's sort.
        for key in map.keys {
            map[key]?.sort { $0.label.localizedCompare($1.label) == .orderedAscending }
        }
        return map
    }

    /// Cache key combining the active in-app language with the database id.
    private static func cacheKey(databaseId: String?) -> String {
        "\(AppLanguage.current.rawValue):\(databaseId ?? "")"
    }
}
