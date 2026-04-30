// Metadata for a single property within an entity type definition.
// Describes how to display, label, group, and sort a property.
// Converted from raw API EntitySummary at the service layer.

import Foundation

/// Property metadata — label, type, group, ordinal, display rules. Converted from API.
struct PropertyDefinition: Identifiable {
    let _id: String
    let name: String
    let type: String
    let label: String?
    let labelPlural: String?
    let group: String?
    let ordinal: Double
    let mandatory: Bool
    let hidden: Bool
    let markdown: Bool
    let decimals: Int?
    let readonly: Bool
    let multilingual: Bool
    let description: String?

    /// True when the property accepts multiple values (Phase 6 editor adds "+" rows).
    let list: Bool

    /// Set when the value is computed by the server — skipped in the editor.
    let formula: String?

    /// Default value used when creating a new entity. Format depends on `type`.
    let `default`: String?

    /// Reference filter — API query string scoping which entities are
    /// valid targets when `type == "reference"`. Set on the property
    /// definition entity as `reference_query` (mirrors webapp's
    /// `entity-type.js` `referenceQuery: getValue(p.reference_query)`).
    let query: String?

    /// Predefined option values for `string` / `number` properties.
    /// When non-empty, the editor renders a `Picker` instead of a free
    /// text input. Mirrors webapp's `:set="property.set?.map(x => x.string)"`.
    let set: [String]

    var id: String { _id }

    /// Returns the best display label — plural when `valueCount > 1`, falling back to the property name.
    func displayLabel(valueCount: Int = 1) -> String {
        if valueCount > 1, let labelPlural {
            return labelPlural
        }
        return label ?? name
    }

    // MARK: - Convert from API response

    /// Build from an EntitySummary returned by the property definitions query.
    init(from entity: EntitySummary) {
        _id = entity._id
        name = PropertyValue.localized(entity.name) ?? entity._id
        type = PropertyValue.localized(entity.additionalProperties?["type"]) ?? "string"
        label = PropertyValue.localized(entity.additionalProperties?["label"])
        labelPlural = PropertyValue.localized(entity.additionalProperties?["label_plural"])
        group = PropertyValue.localized(entity.additionalProperties?["group"])
        ordinal = entity.additionalProperties?["ordinal"]?.first?.number ?? 0
        mandatory = entity.additionalProperties?["mandatory"]?.first?.boolean ?? false
        hidden = entity.additionalProperties?["hidden"]?.first?.boolean ?? false
        markdown = entity.additionalProperties?["markdown"]?.first?.boolean ?? false
        readonly = entity.additionalProperties?["readonly"]?.first?.boolean ?? false
        multilingual = entity.additionalProperties?["multilingual"]?.first?.boolean ?? false
        description = PropertyValue.localized(entity.additionalProperties?["description"])
        decimals = entity.additionalProperties?["decimals"]?.first?.number.map { Int($0) }
        list = entity.additionalProperties?["list"]?.first?.boolean ?? false
        formula = PropertyValue.localized(entity.additionalProperties?["formula"])
        `default` = PropertyValue.localized(entity.additionalProperties?["default"])
        query = PropertyValue.localized(entity.additionalProperties?["reference_query"])
        set = (entity.additionalProperties?["set"] ?? []).compactMap { $0.string }
    }

    // MARK: - Fallback for untyped properties

    /// Create a minimal definition for properties without type metadata, inferring type from the first value.
    init(name: String, values: [PropertyValue]) {
        self._id = name
        self.name = name
        self.label = nil
        self.labelPlural = nil
        self.group = nil
        self.ordinal = 999
        self.mandatory = false
        self.hidden = false
        self.markdown = false
        self.decimals = nil
        self.readonly = false
        self.multilingual = false
        self.description = nil
        self.list = false
        self.formula = nil
        self.default = nil
        self.query = nil
        self.set = []

        if let first = values.first {
            if first.reference != nil { self.type = "reference" }
            else if first.number != nil { self.type = "number" }
            else if first.boolean != nil { self.type = "boolean" }
            else if first.date != nil { self.type = "date" }
            else if first.datetime != nil { self.type = "datetime" }
            else if first.filename != nil { self.type = "file" }
            else { self.type = "string" }
        } else {
            self.type = "string"
        }
    }
}
