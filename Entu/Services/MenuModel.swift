// Fetches menu entities from the API and groups them for the sidebar.
// Menu items define which entity types appear in the navigation
// (e.g. "People", "Documents") and carry query strings to filter the list.
//
// @Observable = SwiftUI views automatically update when "groups" or "isLoading" change.
// @MainActor = runs on the main thread for safe UI updates.

import Foundation

/// Cached, language-aware menu payload. Stored as a value type so the static
/// cache holds resolved labels per language without re-fetching from the API.
private struct CachedMenu {
    let groups: [MenuGroup]
    let queryById: [String: String]
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

            queryById = newQueryById
            groups = newGroups
            Self.cache[key] = CachedMenu(groups: newGroups, queryById: newQueryById)
        } catch {
            groups = []
            queryById = [:]
        }
    }

    /// Cache key combining the active in-app language with the database id.
    private static func cacheKey(databaseId: String?) -> String {
        "\(AppLanguage.current.rawValue):\(databaseId ?? "")"
    }
}
