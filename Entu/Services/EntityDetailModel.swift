// Fetches a single entity and its type definition, then provides
// properties organized by group for display in the detail view.
//
// Type definitions are cached by typeId so browsing entities of the
// same type doesn't re-fetch property metadata on every navigation.

import Foundation

/// A group of properties sharing the same group label, sorted by ordinal.
struct PropertyGroup: Identifiable {
    let name: String?
    let properties: [(definition: PropertyDefinition, values: [PropertyValue])]
    var ordinal: Double?

    var id: String { name ?? "_ungrouped" }
}

/// Fetches a single entity and its type definition, provides grouped properties for display.
@MainActor @Observable
final class EntityDetailModel {
    /// The currently loaded entity, or nil while loading or on error.
    var entity: EntityDetail?

    /// True while a fetch is in flight.
    var isLoading = false

    /// Human-readable message from the last failed load, or nil on success.
    var errorMessage: String?

    private let api: APIClient
    private var definitions: [PropertyDefinition] = []

    // Shared across navigations — avoids refetching type metadata for the same entity type.
    private static var typeCache: [String: [PropertyDefinition]] = [:]

    /// Clears the type definition cache — call on database change.
    static func clearCache() {
        typeCache = [:]
    }

    init(api: APIClient) {
        self.api = api
    }

    /// Fetch entity and its type's property definitions.
    func load(entityId: String) async {
        isLoading = true
        errorMessage = nil
        entity = nil
        definitions = []

        do {
            // 1. Fetch the entity
            let response: EntityDetailResponse = try await api.get("entity/\(entityId)")

            guard let fetchedEntity = response.entity else {
                errorMessage = "Entity not found"
                isLoading = false
                return
            }

            entity = fetchedEntity

            // 2. Resolve type definitions (cached per typeId)
            if let typeId = fetchedEntity.typeId {
                if let cached = Self.typeCache[typeId] {
                    definitions = cached
                } else {
                    let defs = await fetchTypeDefinitions(typeId: typeId)
                    Self.typeCache[typeId] = defs
                    definitions = defs
                }
            }
        } catch APIError.serverError(_, let body) {
            // Nitro/h3 errors are JSON with a `message` field. Surface only that.
            errorMessage = parseMessage(from: body)
        } catch {
            errorMessage = nil
        }

        isLoading = false
    }

    /// Extracts `message` from a Nitro/h3 JSON error body, or nil if the body
    /// isn't JSON or doesn't carry that field.
    private func parseMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["message"] as? String
    }

    /// Properties matched to their definitions, filtered, grouped, and sorted for display.
    var groupedProperties: [PropertyGroup] {
        guard let entity else { return [] }

        // Build a lookup from definition name to definition
        let defsByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })

        // Collect all displayable properties
        var items: [(definition: PropertyDefinition, values: [PropertyValue])] = []

        for (key, values) in entity.properties {
            // Skip internal fields without a custom label defined in the type
            if key == "name" { continue }

            if let def = defsByName[key] {
                if def.hidden { continue }
                // Show if mandatory or has values
                if !def.mandatory && values.isEmpty { continue }
                items.append((definition: def, values: values))
            } else {
                // No definition — skip system properties, show custom ones with key as label
                if key.hasPrefix("_") { continue }
                if values.isEmpty { continue }
                let fallback = PropertyDefinition(name: key, values: values)
                items.append((definition: fallback, values: values))
            }
        }

        // Also add mandatory properties that have no values in the entity
        for def in definitions {
            if def.mandatory && !def.hidden && def.name != "name" {
                if !items.contains(where: { $0.definition.name == def.name }) {
                    items.append((definition: def, values: []))
                }
            }
        }

        // Group by group name
        var groupMap: [String: [(definition: PropertyDefinition, values: [PropertyValue])]] = [:]
        for item in items {
            let key = item.definition.group ?? ""
            groupMap[key, default: []].append(item)
        }

        // Sort matching the webapp's propsSorter logic
        return groupMap.map { key, items in
            let sorted = items.sorted {
                let aOrd = $0.definition.ordinal == 0 ? nil : Optional($0.definition.ordinal)
                let bOrd = $1.definition.ordinal == 0 ? nil : Optional($1.definition.ordinal)
                return entuSort(aOrd, $0.definition.displayLabel(), bOrd, $1.definition.displayLabel())
            }
            // Unnamed group always gets ordinal 0 (sorts first).
            // Named groups use average ordinal of their children.
            let groupOrd: Double?
            if key.isEmpty {
                groupOrd = 0
            } else {
                let ordinals = sorted.compactMap { $0.definition.ordinal == 0 ? nil : $0.definition.ordinal }
                groupOrd = ordinals.isEmpty ? nil : ordinals.reduce(0.0, +) / Double(sorted.count)
            }
            return PropertyGroup(
                name: key.isEmpty ? nil : key,
                properties: sorted,
                ordinal: groupOrd
            )
        }.sorted { entuSort($0.ordinal, $0.name, $1.ordinal, $1.name) }
    }

    // MARK: - Private

    // Fetch property definitions for a type — these are child entities of the type entity
    // where _type.string == "property".
    private func fetchTypeDefinitions(typeId: String) async -> [PropertyDefinition] {
        let params: [String: String] = [
            "_parent.reference": typeId,
            "props": "decimals,default,description,formula,group,hidden,label_plural,label,list,mandatory,markdown,multilingual,name,ordinal,readonly,type"
        ]

        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }

        return response.entities.map { PropertyDefinition(from: $0) }
    }
}

