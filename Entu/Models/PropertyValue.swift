import Foundation

/// A single value within an entity property array.
struct PropertyValue: Codable {
    let _id: String?
    let string: String?
    let number: Double?
    let boolean: Bool?
    let reference: String?
    /// ISO 8601 date string, e.g. `"2026-04-29T00:00:00.000Z"`. The API
    /// returns date / datetime in ISO form (after `new Date(...)` round-trip
    /// in `insertProperties`); writes are sent in the same shape.
    let date: String?
    let datetime: String?
    let filename: String?
    let filesize: Int?
    let language: String?
    /// Auth metadata on login-linked values (mirrors the webapp): the OAuth
    /// provider and email behind a person's authentication property.
    let provider: String?
    let email: String?
    let ordinal: Double?

    /// Set on rights values (`_owner`, `_editor`, …) copied down from a
    /// parent entity by the aggregation. Such values carry the *parent's*
    /// property id — they can't be edited or deleted on this entity.
    let inherited: Bool?

    /// Picks the best `PropertyValue` from a multilingual array. Priority:
    /// matching the in-app language > no language set > first available.
    /// Returns the whole value so callers can read fields beyond `string`
    /// (e.g. `reference`, `number`) when the property type warrants it.
    static func best(_ values: [PropertyValue]?) -> PropertyValue? {
        guard let values else { return nil }
        let language = AppLanguage.resolvedLanguageCode
        return values.first { $0.language == language }
            ?? values.first { $0.language == nil }
            ?? values.first
    }

    /// Convenience: pick the best value (see `best(_:)`) and extract a
    /// printable string by property `type`.
    static func localized(_ values: [PropertyValue]?, type: String = "string") -> String? {
        let value = best(values)
        switch type {
        case "string": return value?.string
        case "reference": return value?.reference
        case "number": return value?.number.map { String($0) }
        default: return value?.string
        }
    }
}
