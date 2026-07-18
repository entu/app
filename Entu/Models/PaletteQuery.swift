// Command-palette query grammar — the token state (entity type, filters,
// sort) built in the ⌘K field, and its mapping to Entu API query params.
// The operator grammar mirrors the webapp's advanced search:
// `{property}.{searchField}[.{operator}]={value}`.

import Foundation

/// The type token — scopes the palette query to one entity type.
struct PaletteEntityType: Equatable {
    /// The type entity's `_id` — parent of its property definitions.
    let typeId: String
    /// The type's machine name, matched against `_type.string`.
    let typeName: String
    /// Localized display label (falls back to `typeName`).
    let label: String
    /// Pre-folded match keys — computed once at load so per-keystroke
    /// ranking is plain `hasPrefix`/`contains` (see `paletteFold`).
    let foldedLabel: String
    let foldedName: String

    init(typeId: String, typeName: String, label: String) {
        self.typeId = typeId
        self.typeName = typeName
        self.label = label
        self.foldedLabel = paletteFold(label)
        self.foldedName = paletteFold(typeName)
    }
}

/// Case- and diacritic-insensitive normalization used for all palette
/// matching — fold once, compare many.
func paletteFold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

/// A property usable in filter and sort tokens.
struct PaletteProperty: Equatable {
    let name: String
    /// Datatype from the property definition: string, text, number,
    /// boolean, reference, date, datetime, file, counter, formula.
    let type: String
    let label: String
    /// Pre-folded match keys (see `paletteFold`).
    let foldedLabel: String
    let foldedName: String

    init(name: String, type: String, label: String) {
        self.name = name
        self.type = type
        self.label = label
        self.foldedLabel = paletteFold(label)
        self.foldedName = paletteFold(name)
    }

    /// The datatype segment of the Mongo path — shared with the advanced
    /// search (webapp `getPropertySearchField`).
    var searchField: String {
        AdvancedSearchModel.searchField(for: type)
    }

    /// Ordered datatypes cycle is / before / after; everything else
    /// cycles is / is not / contains.
    var isOrdered: Bool {
        ["number", "counter", "date", "datetime"].contains(type)
    }

    var conditions: [PaletteCondition] {
        isOrdered ? [.is, .before, .after] : [.is, .isNot, .contains]
    }
}

/// Filter-token condition — cycled with ⌥ or by clicking the chip's
/// condition word.
enum PaletteCondition: Equatable {
    case `is`, isNot, contains, before, after

    /// API operator suffix appended to the filter key ("" = exact match).
    var operatorSuffix: String {
        switch self {
        case .is: ""
        case .isNot: "ne"
        case .contains: "regex"
        case .before: "lt"
        case .after: "gt"
        }
    }

    /// Localized word rendered inside the chip ("Author *is* Tolkien").
    var label: String {
        let key: String.LocalizationValue = switch self {
        case .is: "paletteCondIs"
        case .isNot: "paletteCondIsNot"
        case .contains: "paletteCondContains"
        case .before: "paletteCondBefore"
        case .after: "paletteCondAfter"
        }
        return String(localized: key, bundle: .currentLocalized)
    }
}

/// A sealed filter token.
struct PaletteFilter: Equatable, Identifiable {
    /// Stable chip identity for ForEach — survives removal of siblings.
    let id = UUID()

    var property: PaletteProperty
    var condition: PaletteCondition
    /// Raw value sent to the API.
    var value: String
    /// Value as shown in the chip.
    var valueLabel: String
    /// Field text at the moment the property was accepted — restored when
    /// Backspace unwinds past this token.
    var typedText = ""
    /// Field text at the moment the value was committed — restored when
    /// Backspace re-opens this token.
    var valueTypedText = ""
}

/// A filter being edited — property accepted, awaiting its value.
struct PaletteFilterDraft: Equatable {
    var property: PaletteProperty
    var condition: PaletteCondition = .is
    /// Field text at the moment the property was accepted (see above).
    var typedText = ""
}

/// The sort token.
struct PaletteSort: Equatable {
    var property: PaletteProperty
    var descending = false
    /// Field text at the moment the sort was accepted (see above).
    var typedText = ""
}

/// The whole token row of the palette field.
struct PaletteQueryState: Equatable {
    var entityType: PaletteEntityType?
    /// Field text at the moment the type was accepted (see above).
    var entityTypeTypedText = ""
    var filters: [PaletteFilter] = []
    var draft: PaletteFilterDraft?
    var sort: PaletteSort?

    var isEmpty: Bool {
        entityType == nil && filters.isEmpty && draft == nil && sort == nil
    }

    /// Ordered query pairs (without `q`) — the same shape the advanced
    /// search applies to the main list, so a palette query can be handed
    /// over via `MainView.applyAdvancedSearch`.
    func queryPairs() -> [(String, String)] {
        var pairs: [(String, String)] = []
        if let entityType {
            pairs.append(("_type.string", entityType.typeName))
        }
        for filter in filters {
            var key = "\(filter.property.name).\(filter.property.searchField)"
            if !filter.condition.operatorSuffix.isEmpty {
                key += ".\(filter.condition.operatorSuffix)"
            }
            let value = filter.condition == .contains
                ? "/\(Self.regexEscape(filter.value))/i"
                : filter.value
            pairs.append((key, value))
        }
        if let sort {
            pairs.append(("sort", "\(sort.descending ? "-" : "")\(sort.property.name).\(sort.property.searchField)"))
        }
        return pairs
    }

    /// Query pairs as request params. Keys are unique by construction —
    /// `commitValue` replaces a filter with the same property+condition —
    /// so the collapse to a dictionary is lossless.
    func queryParams() -> [String: String] {
        Dictionary(queryPairs(), uniquingKeysWith: { first, _ in first })
    }

    /// Escape regex metacharacters so a contains filter matches the value
    /// literally. `/` becomes `.` (match-any-single-char) instead of `\/` —
    /// the API splits the `/pattern/flags` form naively, so an escaped
    /// slash still truncates the pattern and 400s; `.` matches the literal
    /// slash (at worst also any other single char there).
    static func regexEscape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "/" {
                escaped.append(".")
                continue
            }
            if #"\^$.|?*+()[]{}"#.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
