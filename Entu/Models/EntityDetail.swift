// Full entity returned by GET /{db}/entity/{_id}.
// Unlike EntitySummary (used in lists), this contains ALL properties.
//
// The API response has mixed types: _id and _thumbnail are plain strings,
// but every other key is an array of PropertyValue objects. The custom
// decoder handles this by separating known scalar fields from dynamic ones.

import Foundation

/// API response wrapper from GET /entity/{id}.
struct EntityDetailResponse: Codable {
    let entity: EntityDetail?
}

/// Full entity with all properties as a dynamic dictionary.
struct EntityDetail: Codable, Identifiable {
    let _id: String
    let _thumbnail: String?

    // All properties keyed by name (e.g. "name", "_type", "_parent", "email").
    // Each value is an array of PropertyValue since properties can be multi-valued.
    let properties: [String: [PropertyValue]]

    var id: String { _id }

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

    // Decodes _id and _thumbnail as plain strings, collects everything else
    // as [String: [PropertyValue]] into the properties dictionary.

    enum CodingKeys: String, CodingKey {
        case _id, _thumbnail
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
        _thumbnail = try container.decodeIfPresent(String.self, forKey: ._thumbnail)

        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        let scalarKeys: Set<String> = ["_id", "_thumbnail"]
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
        try container.encodeIfPresent(_thumbnail, forKey: ._thumbnail)
    }
}
