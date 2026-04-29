// A single value within an entity's property array.
//
// In Entu, every property (e.g. "name", "email") holds an array of these values.
// The active field determines the type — only one of string/number/boolean/reference/etc.
// is non-nil per value. Multilingual properties have multiple values with different
// "language" fields (e.g. "en", "et").

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
    let provider: String?
    let email: String?
    let ordinal: Double?

    /// Picks the best localized value from an array of PropertyValues.
    /// Priority: in-app language preference > system preferred language >
    /// no language set > first available.
    static func localized(_ values: [PropertyValue]?, type: String = "string") -> String? {
        let language = AppLanguage.resolvedLanguageCode

        let value = values?.first { $0.language == language }
            ?? values?.first { $0.language == nil }
            ?? values?.first

        switch type {
        case "string": return value?.string
        case "reference": return value?.reference
        case "number": return value?.number.map { String($0) }
        default: return value?.string
        }
    }
}
