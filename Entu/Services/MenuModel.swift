// Fetches menu entities from the API and groups them for the sidebar.
// Menu items define which entity types appear in the navigation
// (e.g. "People", "Documents") and carry query strings to filter the list.
//
// @Observable = SwiftUI views automatically update when "groups" or "isLoading" change.
// @MainActor = runs on the main thread for safe UI updates.

import Foundation

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

    init(api: APIClient) {
        self.api = api
    }

    /// Fetch all menu-type entities, then group and sort them for sidebar display.
    func load() async {
        isLoading = true

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
            queryById = [:]
            for entity in menuEntities {
                queryById[entity._id] = entity.query
            }

            // Group by group label (case-insensitive)
            var groupMap: [String: [MenuEntity]] = [:]
            for entity in menuEntities {
                let key = entity.group?.lowercased() ?? ""
                groupMap[key, default: []].append(entity)
            }

            // Sort matching the webapp's menuSorter
            groups = groupMap.map { _, items in
                MenuGroup(
                    name: items.first?.group,
                    items: items.sorted { entuSort($0.ordinal, $0.name, $1.ordinal, $1.name) }
                )
            }.sorted { entuSort($0.ordinal, $0.name, $1.ordinal, $1.name) }
        } catch {
            groups = []
        }

        isLoading = false
    }
}
