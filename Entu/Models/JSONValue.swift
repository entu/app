// Type-erased JSON value — round-trips AI proposal payloads verbatim
// between /ai/chat and /ai/execute without dropping unknown fields.

import Foundation

/// A type-erased JSON value used to round-trip AI proposal operation
/// payloads (`params`, `properties`) verbatim. The `/ai/chat` endpoint
/// returns operation objects whose inner shape is schema-dependent, and
/// the `/ai/execute` endpoint expects them back unchanged — decoding into
/// typed structs would silently drop unknown fields, so the raw JSON is
/// preserved instead.
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Short single-line rendering for proposal property rows — scalars
    /// verbatim, arrays joined with "·", property-value objects reduced to
    /// their display field. Nil when there's nothing row-friendly (the raw
    /// JSON disclosure handles those).
    var displayString: String? {
        switch self {
        case .null:
            return nil
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value):
            return value.isEmpty ? nil : value
        case .array(let values):
            let parts = values.compactMap { $0.displayString }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .object(let dict):
            // Entity property payloads: {"string": …} / {"reference": …, "string": …} etc.
            return dict["string"]?.displayString
                ?? dict["number"]?.displayString
                ?? dict["boolean"]?.displayString
                ?? dict["date"]?.displayString
                ?? dict["datetime"]?.displayString
                ?? dict["reference"]?.displayString
        }
    }

    /// True when the value carries an entity reference — rendered as an
    /// accent chip in the proposal card.
    var isReference: Bool {
        switch self {
        case .object(let dict):
            return dict["reference"] != nil
        case .array(let values):
            return values.contains { $0.isReference }
        default:
            return false
        }
    }

    /// Pretty-printed JSON for the proposal detail preview — sorted keys so
    /// the same operation always renders identically.
    var prettyText: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
