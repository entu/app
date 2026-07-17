// Entity detail models — the GET /entity/{id} response wrapper and the
// full entity with its properties as a dynamic name → values dictionary.

import Foundation

/// API response wrapper from GET /entity/{id}.
struct EntityDetailResponse: Codable {
    let entity: EntityDetail?
}

/// Full entity with all properties as a dynamic dictionary.
struct EntityDetail: Codable, Identifiable {
    let _id: String

    /// All properties keyed by name (e.g. `name`, `_type`, `_parent`, `email`).
    /// Each value is an array of `PropertyValue` since properties can be multi-valued.
    let properties: [String: [PropertyValue]]

    var id: String { _id }

    /// Whether the entity has a `photo` file property — used to decide
    /// whether to request a thumbnail. Requires `photo` in the query `props`.
    var hasPhoto: Bool {
        !(properties["photo"]?.isEmpty ?? true)
    }

    // MARK: - Convenience accessors

    var displayName: String {
        PropertyValue.localized(properties["name"]) ?? _id
    }

    var typeId: String? {
        properties["_type"]?.first?.reference
    }

    var typeName: String? {
        properties["_type"]?.first?.string
    }

    var parents: [PropertyValue]? {
        properties["_parent"]
    }

    var sharing: String? {
        properties["_sharing"]?.first?.string
    }

    // MARK: - Custom JSON decoding

    /// `_id` decoded as a plain string; everything else goes into `properties`.
    enum CodingKeys: String, CodingKey {
        case _id
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(String.self, forKey: ._id)

        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        let scalarKeys: Set<String> = ["_id"]
        var props: [String: [PropertyValue]] = [:]

        for key in dynamicContainer.allKeys where !scalarKeys.contains(key.stringValue) {
            if let values = try? dynamicContainer.decode([PropertyValue].self, forKey: key) {
                props[key.stringValue] = values
            }
        }

        properties = props
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_id, forKey: ._id)
    }
}
