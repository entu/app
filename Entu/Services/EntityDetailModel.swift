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

    /// Localized label of the entity's type (the type entity's `label`),
    /// shown on the detail header's type chip. Nil until resolved — the
    /// chip falls back to the raw type name.
    var typeLabel: String?

    private let api: APIClient
    private var definitions: [PropertyDefinition] = []

    /// Everything type-scoped the detail needs: the property definitions
    /// (the type's child entities) and the type's own display label. Two
    /// API requests — the list query can't include its parent — fetched in
    /// parallel and cached as one unit.
    private struct TypeMetadata {
        let definitions: [PropertyDefinition]
        let label: String?
    }

    /// Shared across navigations — avoids refetching type metadata for
    /// the same entity type. Keyed by `"<lang>:<typeId>"` so entries for
    /// different languages coexist; switching language hits the other
    /// language's cache without a refetch.
    private static var typeCache: [String: TypeMetadata] = [:]

    /// Clears the type metadata cache — call on database change.
    static func clearCache() {
        typeCache = [:]
    }

    /// Cache key combining the active in-app language with the type id.
    private static func cacheKey(typeId: String) -> String {
        "\(AppLanguage.current.rawValue):\(typeId)"
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

            // 2. Resolve type definitions + type label (cached per language + typeId)
            typeLabel = nil
            if let typeId = fetchedEntity.typeId {
                let key = Self.cacheKey(typeId: typeId)
                if let cached = Self.typeCache[key] {
                    definitions = cached.definitions
                    typeLabel = cached.label
                } else {
                    async let defs = fetchTypeDefinitions(typeId: typeId)
                    async let label = fetchTypeLabel(typeId: typeId)
                    let metadata = TypeMetadata(definitions: await defs, label: await label)
                    Self.typeCache[key] = metadata
                    definitions = metadata.definitions
                    typeLabel = metadata.label
                }
            }
        } catch APIError.serverError(_, let body) {
            // Nitro/h3 errors are JSON with a `message` field. Surface only that.
            errorMessage = parseMessage(from: body)
        } catch {
            // URLErrors, decode errors, cancellation — show a generic network message.
            errorMessage = String(localized: "networkError", bundle: .currentLocalized)
        }

        isLoading = false
    }

    /// Fetch the localized singular label from the type entity, name as
    /// fallback.
    private func fetchTypeLabel(typeId: String) async -> String? {
        guard let response: EntityDetailResponse = try? await api.get(
            "entity/\(typeId)",
            params: ["props": "label,name"]
        ) else { return nil }

        let props = response.entity?.properties
        return PropertyValue.localized(props?["label"])
            ?? PropertyValue.localized(props?["name"])
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
            "props": "decimals,default,description,formula,group,hidden,label_plural,label,list,mandatory,markdown,multilingual,name,ordinal,readonly,reference_query,set,type"
        ]

        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }

        return response.entities.map { PropertyDefinition(from: $0) }
    }
}

