// Wire payload for `POST /{db}/entity` and `POST /{db}/entity/{id}` write requests.
//
// The API expects an array of property dicts. Each value carries `type` (the
// property name) plus exactly one typed field (`string`, `number`, `boolean`,
// `reference`, `date`, or `datetime`). Multilingual values include `language`.
// Presence of `_id` updates an existing value; absence creates a new one.
//
// Custom encoder skips nil keys so the server doesn't see e.g. `"number": null`
// alongside a `string` value, which would confuse type-discriminated routing.

import Foundation

/// Single property change in a write request.
///
/// `date` and `datetime` are encoded as **ISO 8601 strings** (e.g.
/// `"2026-04-29T15:30:45Z"`) so the API's `new Date(property.date)` in
/// `insertProperties` parses cleanly and the values round-trip in the
/// same shape they're returned in. Webapp serialises `Date` instances
/// the same way via `JSON.stringify`.
struct EntityPropertyChange: Encodable {
    var _id: String?
    let type: String
    var string: String?
    var number: Double?
    var boolean: Bool?
    var reference: String?
    var date: String?
    var datetime: String?
    var language: String?
    /// Increment hint for counter-type properties — server resolves to
    /// the next sequence value. Webapp sends `counter: 1` on Generate.
    var counter: Int?
    /// File metadata for upload pre-flight. The server replies with a
    /// presigned S3 PUT in the response's `upload` block; the bytes go
    /// up in a follow-up request. Mirrors webapp `uploadFile`.
    var filename: String?
    var filesize: Int?
    var filetype: String?

    private enum CodingKeys: String, CodingKey {
        case _id, type, string, number, boolean, reference, date, datetime, language, counter, filename, filesize, filetype
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(_id, forKey: ._id)
        try container.encodeIfPresent(string, forKey: .string)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(boolean, forKey: .boolean)
        try container.encodeIfPresent(reference, forKey: .reference)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(datetime, forKey: .datetime)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(counter, forKey: .counter)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(filesize, forKey: .filesize)
        try container.encodeIfPresent(filetype, forKey: .filetype)
    }
}

/// Presigned S3 PUT block returned alongside a newly-inserted file property.
/// The client streams the file bytes to `url` using `method` + `headers`.
struct UploadIntent: Decodable {
    let method: String
    let url: String
    let headers: [String: String]?
}

/// Response shape from `POST /{db}/entity` and `POST /{db}/entity/{id}`.
/// `_id` is the entity id (new for create, echoed for update) and
/// `properties` is the array of property objects the server actually
/// stored — each carrying its server-assigned `_id`. This lets the
/// client populate row `_id`s without a separate GET refetch.
struct EntityUpsertResponse: Decodable {
    let _id: String?
    let properties: [UpsertedProperty]?
}

/// Lightweight projection of one property from an upsert response.
/// We bind only by `_id`, `type`, and `language` — the value fields
/// (`string`, `number`, `date`, …) are deliberately not decoded
/// because the server returns them in shapes that don't always match
/// the wire types we send (e.g. dates come back as ISO 8601 strings
/// after `new Date(...)` conversion in `insertProperties`). Decoding
/// only what we read keeps the call resilient to those mismatches.
struct UpsertedProperty: Decodable {
    let _id: String?
    let type: String?
    let language: String?
    /// Set on file-property responses — carries the presigned PUT info.
    let upload: UploadIntent?
}
