// Loading + initial-state seeding for `EntityEditView`. Split out of
// `EntityEditSheet.swift` to keep the view file focused on rendering and
// the commit machinery (`EntityEditSheetCommit.swift`) on writes.
//
// Sequence on present:
//   load() → fetch entity (edit) or take type from mode (create)
//          → fetch type definitions + type description
//          → seedValues() → manageEmptyFields() per definition
// All idempotent — re-running `load` from the outside (after edit sheet
// closes elsewhere, language switch, etc.) produces the same end state.

import Foundation

extension EntityEditView {
    /// Languages supported for multilingual properties. Keep in sync with
    /// the webapp's `languageOptions` in `components/property/edit.vue`.
    static var multilingualLanguages: [String] { ["en", "et"] }

    func load() async {
        isLoading = true
        loadError = nil

        let typeId: String?
        switch mode {
        case .edit(let entityId):
            do {
                let response: EntityDetailResponse = try await api.get("entity/\(entityId)")
                entity = response.entity
                typeId = response.entity?.typeId
                currentEntityId = entityId
            } catch {
                loadError = String(localized: "networkError", bundle: .currentLocalized)
                isLoading = false
                return
            }
        case .create(_, let id, _):
            entity = nil
            typeId = id
            currentEntityId = nil
        }
        currentTypeId = typeId

        if let typeId {
            definitions = await fetchDefinitions(typeId: typeId)
            typeDescription = await fetchTypeDescription(typeId: typeId)
        }

        seedValues()
        isLoading = false
    }

    /// Fetch the type entity's `description` property and localize it.
    /// Returns nil when the type has no description.
    func fetchTypeDescription(typeId: String) async -> String? {
        let params = ["props": "description"]
        guard let response: EntityDetailResponse = try? await api.get("entity/\(typeId)", params: params),
              let descriptions = response.entity?.properties["description"] else {
            return nil
        }
        let text = PropertyValue.localized(descriptions)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Fetch property definitions for the entity type — same query as
    /// `EntityDetailModel.fetchTypeDefinitions`.
    func fetchDefinitions(typeId: String) async -> [PropertyDefinition] {
        let params: [String: String] = [
            "_parent.reference": typeId,
            "props": "decimals,default,description,formula,group,hidden,label_plural,label,list,mandatory,markdown,multilingual,name,ordinal,readonly,reference_query,set,type"
        ]
        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }
        return response.entities.map { PropertyDefinition(from: $0) }
    }

    /// Build initial `values` from the loaded entity (edit) or definitions
    /// (create). Mirrors webapp's empty-field logic — see manageEmptyFields.
    func seedValues() {
        var seeded: [String: [EditableValue]] = [:]
        for def in definitions where !def.hidden && def.formula == nil && !def.readonly {
            if case .edit = mode, let existing = entity?.properties[def.name], !existing.isEmpty {
                seeded[def.name] = existing
                    .sorted(by: propertyValueOrder)
                    .map { rowFromExisting($0, definition: def) }
            } else if def.multilingual {
                // Multilingual: leave empty so `manageEmptyFields` adds one
                // empty row per language (with the language pre-tagged).
                seeded[def.name] = []
            } else {
                seeded[def.name] = [defaultRow(for: def)]
            }
        }
        values = seeded
        for def in definitions {
            manageEmptyFields(for: def)
        }
    }

    /// Stable per-property value order — mirrors webapp's
    /// `propertyValuesSorter` (utils/api.js): language ascending (untagged
    /// first), then ordinal ascending (no-ordinal first), then `_id`
    /// ascending (no-id first).
    func propertyValueOrder(_ a: PropertyValue, _ b: PropertyValue) -> Bool {
        if a.language != b.language {
            switch (a.language, b.language) {
            case (nil, _): return true
            case (_, nil): return false
            case (let l?, let r?): return l < r
            default: return false
            }
        }
        if a.ordinal != b.ordinal {
            switch (a.ordinal, b.ordinal) {
            case (nil, _): return true
            case (_, nil): return false
            case (let l?, let r?): return l < r
            default: return false
            }
        }
        switch (a._id, b._id) {
        case (nil, _): return true
        case (_, nil): return false
        case (let l?, let r?): return l < r
        default: return false
        }
    }

    func rowFromExisting(_ existing: PropertyValue, definition: PropertyDefinition) -> EditableValue {
        let row = EditableValue(_id: existing._id, language: existing.language)
        switch definition.type {
        case "boolean": row.boolValue = existing.boolean ?? false
        case "number":  row.numberValue = existing.number
        case "date", "datetime":
            if let iso = existing.date ?? existing.datetime {
                row.dateValue = ISO8601DateFormatter.parse(iso)
            }
        case "reference":
            row.referenceId = existing.reference
            row.referenceLabel = existing.string
        case "file":
            // Files carry their display name in `filename`. Fall back to
            // `string` so rows with both still render something useful.
            row.stringValue = existing.filename ?? existing.string ?? ""
            row.filesize = existing.filesize
        default:
            row.stringValue = existing.string ?? ""
        }
        return row
    }

    func defaultRow(for definition: PropertyDefinition, language: String? = nil) -> EditableValue {
        let row = EditableValue(language: language)
        if let raw = definition.default, !raw.isEmpty {
            switch definition.type {
            case "boolean": row.boolValue = raw == "true" || raw == "1"
            case "number":  row.numberValue = Double(raw)
            default:        row.stringValue = raw
            }
        }
        return row
    }
}
