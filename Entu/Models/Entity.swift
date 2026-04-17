// Entity list API response and the summary model used in list views.
//
// The API returns entities with dynamic property keys — known fields (_id, _thumbnail, name)
// are typed directly, while all other properties go into a flexible dictionary.
// This allows the same model to handle any entity type (person, document, etc.)
// without knowing the schema at compile time.

import Foundation

/// API response from GET /entity — list of entities with total count.
struct EntityListResponse: Codable {
    let entities: [EntitySummary]
    let count: Int?
}

/// Raw API entity with dynamic property keys for list views and table rows.
struct EntitySummary: Codable, Identifiable {
    let _id: String
    let _thumbnail: String?
    let name: [PropertyValue]?

    // Returned by grouped queries (e.g. group=_type.reference) — count of entities in this group.
    let _count: Int?

    // Extra properties beyond the known keys above.
    // Keys are property names (e.g. "query", "ordinal"), values are property arrays.
    let additionalProperties: [String: [PropertyValue]]?

    var id: String { _id }

    // Returns the display name in the user's preferred language.
    var displayName: String {
        PropertyValue.localized(name) ?? _id
    }

    // MARK: - Custom JSON decoding

    // Known keys are decoded by name; everything else is collected into additionalProperties.
    // This is needed because the API returns dynamic keys that vary by entity type.

    enum CodingKeys: String, CodingKey {
        case _id, _thumbnail, name, _count
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Grouped responses may not have _id — use empty string as fallback.
        _id = (try? container.decode(String.self, forKey: ._id)) ?? ""
        _thumbnail = try container.decodeIfPresent(String.self, forKey: ._thumbnail)
        name = try container.decodeIfPresent([PropertyValue].self, forKey: .name)
        _count = try container.decodeIfPresent(Int.self, forKey: ._count)

        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        let knownKeys: Set<String> = ["_id", "_thumbnail", "name", "_count"]
        var extras: [String: [PropertyValue]] = [:]

        for key in dynamicContainer.allKeys where !knownKeys.contains(key.stringValue) {
            if let values = try? dynamicContainer.decode([PropertyValue].self, forKey: key) {
                extras[key.stringValue] = values
            }
        }

        additionalProperties = extras.isEmpty ? nil : extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_id, forKey: ._id)
        try container.encodeIfPresent(_thumbnail, forKey: ._thumbnail)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(_count, forKey: ._count)
    }
}
