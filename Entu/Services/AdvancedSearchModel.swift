// Form model for the advanced-search sheet. Mirrors the script section of
// webapp's `components/entity/search-modal.vue` — same option loading,
// operator lists, query building, and applied-query parsing.
//
// Deviation from webapp: `search-modal.vue:57` reads `_type.string` while
// parsing the `_type.string.in` param (webapp bug — yields undefined). The
// intent is to split the `_type.string.in` value, so we do that.

import Foundation

/// One property-filter row (webapp: `searchForm.properties` entry).
struct SearchFilter: Identifiable {
    let id = UUID()
    var field = ""
    /// "" (equals), "exists", "ne", "lt", "lte", "gt", "gte", "in" or "regex".
    var op = ""
    var value: FilterValue = .none
}

/// Typed filter value — the webapp holds a loose JS value, Swift needs a sum type.
enum FilterValue: Equatable {
    case none
    case bool(Bool)
    case number(Double?)
    /// Used for both date and datetime fields.
    case date(Date?)
    case text(String)
}

/// Detected search-field type (webapp `getPropertyType`) — the last
/// dot-segment of the field value when recognized, otherwise string.
enum SearchFieldType: String {
    case string, boolean, date, datetime, filesize, number, reference
}

/// A value/label pair for the entity-type and property pickers.
struct SearchSelectOption: Identifiable, Equatable {
    var value: String
    var label: String
    var id: String { value }
}

/// Advanced-search form state and option loading.
@MainActor @Observable
final class AdvancedSearchModel {
    /// Free-text search (`q` param).
    var q = ""
    /// Selected entity type names (webapp `searchForm.types`).
    var types: [String] = []
    /// "" (ID), "_created.datetime", "_changed.datetime" or "name.string".
    var sortField = ""
    /// "" = ascending, "-" = descending.
    var sortDirection = ""
    /// Property filter rows — always at least one.
    var filters: [SearchFilter] = [SearchFilter()]

    var entityTypeOptions: [SearchSelectOption] = []
    var propertyOptions: [SearchSelectOption] = []
    var isLoadingProperties = false

    /// Sort options with common fields (webapp `sortOptions`).
    static let sortOptions: [(value: String, labelKey: String)] = [
        ("", "id"),
        ("_created.datetime", "created"),
        ("_changed.datetime", "changed"),
        ("name.string", "name")
    ]

    /// Tracks the latest property load so a slow response for a previous
    /// type selection can't overwrite the options (webapp `requestId`).
    private var propertyRequestId = 0

    private let api: APIClient

    /// Builds the form from the currently-applied query — the equivalent of
    /// the webapp's immediate route-query watch.
    init(api: APIClient, currentQuery: [(String, String)], currentText: String) {
        self.api = api
        populate(from: currentQuery, text: currentText)
    }

    // MARK: - Type helpers

    /// Webapp `getPropertyType` — last dot-segment when recognized, else string.
    static func fieldType(of field: String) -> SearchFieldType {
        let parts = field.split(separator: ".").map(String.init)
        guard parts.count > 1, let last = parts.last,
              let type = SearchFieldType(rawValue: last) else {
            return .string
        }

        return type
    }

    /// Webapp `getPropertySearchField` — the value sub-field a property type
    /// is searched on.
    static func searchField(for propertyType: String) -> String {
        switch propertyType {
        case "file": return "filename"
        case "reference": return "string"
        default: return propertyType
        }
    }

    /// Webapp `getOperatorOptions` — boolean and reference fields support
    /// only exists/equals/not-equal; everything else gets the full list.
    static func operatorOptions(for field: String) -> [(value: String, labelKey: String)] {
        let type = fieldType(of: field)

        if type == .boolean || type == .reference {
            return [
                ("exists", "exists"),
                ("", "equals"),
                ("ne", "notEqual")
            ]
        }

        return [
            ("exists", "exists"),
            ("", "equals"),
            ("ne", "notEqual"),
            ("lt", "lessThan"),
            ("lte", "lessThanOrEqual"),
            ("gt", "greaterThan"),
            ("gte", "greaterThanOrEqual"),
            ("in", "in"),
            ("regex", "regex")
        ]
    }

    // MARK: - Form mutations

    func addFilter() {
        filters.append(SearchFilter())
    }

    func removeFilter(at index: Int) {
        guard filters.indices.contains(index) else { return }

        filters.remove(at: index)
    }

    func reset() {
        q = ""
        types = []
        sortField = ""
        sortDirection = ""
        filters = [SearchFilter()]
    }

    // MARK: - Option loading

    /// Load entity-type options (webapp `onMounted`).
    func loadEntityTypes() async {
        let params: [String: String] = [
            "_type.string": "entity",
            "props": "name,label",
            "limit": "1000"
        ]
        guard let response: EntityListResponse = try? await api.get("entity", params: params) else { return }

        entityTypeOptions = response.entities.compactMap { entity in
            guard let name = PropertyValue.localized(entity.name), !name.isEmpty else { return nil }
            let label = PropertyValue.localized(entity.additionalProperties?["label"])
            return SearchSelectOption(value: name, label: label?.isEmpty == false ? label! : name)
        }
        .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }

    /// Load property options for the selected types (webapp `types` watch).
    func loadProperties() async {
        guard !types.isEmpty else {
            propertyOptions = []
            return
        }

        isLoadingProperties = true
        propertyRequestId += 1
        let currentRequest = propertyRequestId

        let params: [String: String] = [
            "_type.string": "property",
            "_parent.string.in": types.joined(separator: ","),
            "props": "_parent,name,label,type",
            "limit": "1000"
        ]
        let response: EntityListResponse? = try? await api.get("entity", params: params)
        guard currentRequest == propertyRequestId else { return }

        /// Intermediate option carrying parent/name for label disambiguation.
        struct PropOption {
            var value: String
            var label: String
            let parent: String
            let name: String
        }

        let mapped: [PropOption] = (response?.entities ?? []).compactMap { entity in
            guard let name = PropertyValue.localized(entity.name)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty,
                  let type = PropertyValue.localized(entity.additionalProperties?["type"])?
                      .trimmingCharacters(in: .whitespaces) else { return nil }
            let label = PropertyValue.localized(entity.additionalProperties?["label"])?
                .trimmingCharacters(in: .whitespaces)
            let parent = PropertyValue.localized(entity.additionalProperties?["_parent"])?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return PropOption(
                value: "\(name).\(Self.searchField(for: type))",
                label: label?.isEmpty == false ? label! : name,
                parent: parent,
                name: name
            )
        }

        // Webapp dedup reduce: same value+label → skip; same value, different
        // label → merge labels; same label, different value → disambiguate
        // both as "label (parent.name)".
        var options: [PropOption] = []
        for entry in mapped {
            var curr = entry
            let existingValueIndex = options.firstIndex { $0.value == curr.value }
            let existingLabelIndex = options.firstIndex { $0.label == curr.label }

            if existingValueIndex != nil && existingLabelIndex != nil {
                // Same value and label already present — nothing to merge.
            } else if let valueIndex = existingValueIndex {
                let merged = Set(options[valueIndex].label.components(separatedBy: ", ") + [curr.label])
                options[valueIndex].label = merged.sorted().joined(separator: ", ")
            } else if let labelIndex = existingLabelIndex {
                let existing = options[labelIndex]
                options[labelIndex].label = "\(existing.label) (\(existing.parent).\(existing.name))"
                curr.label = "\(curr.label) (\(curr.parent).\(curr.name))"
                options.append(curr)
            } else {
                options.append(curr)
            }
        }

        options.sort { $0.label.localizedCompare($1.label) == .orderedAscending }

        propertyOptions = [
            SearchSelectOption(value: "_id", label: "_id"),
            SearchSelectOption(value: "_created", label: "_created.at.datetime")
        ] + options.map { SearchSelectOption(value: $0.value, label: $0.label) }

        isLoadingProperties = false
    }

    // MARK: - Query building

    /// Build the ordered query pairs to apply (webapp `handleSearch`).
    func buildQuery() -> [(String, String)] {
        var query: [(String, String)] = []

        if !q.isEmpty {
            query.append(("q", q))
        }

        if types.count == 1 {
            query.append(("_type.string", types[0]))
        } else if types.count > 1 {
            query.append(("_type.string.in", types.joined(separator: ",")))
        }

        for filter in filters {
            if filter.field.isEmpty { continue }
            guard let encoded = Self.encode(filter.value, fieldType: Self.fieldType(of: filter.field)) else { continue }

            let key = [filter.field, filter.op].filter { !$0.isEmpty }.joined(separator: ".")
            query.append((key, encoded))
        }

        if !sortField.isEmpty {
            query.append(("sort", sortDirection + sortField))
        }

        return query
    }

    /// Encode a filter value for the query string. Nil means the filter is
    /// skipped — webapp skips undefined/null/'' (but sends `false`).
    private static func encode(_ value: FilterValue, fieldType: SearchFieldType) -> String? {
        switch value {
        case .none:
            return nil
        case .bool(let bool):
            return bool ? "true" : "false"
        case .number(let number):
            guard let number else { return nil }
            // JS prints whole numbers without a decimal point ("5", not "5.0").
            if number == number.rounded(), let integer = Int(exactly: number.rounded()) {
                return String(integer)
            }
            return String(number)
        case .date(let date):
            guard let date else { return nil }
            // NDatePicker emits millisecond timestamps — date-only values at
            // local midnight, datetime values at the exact instant.
            let instant = fieldType == .date ? Calendar.current.startOfDay(for: date) : date
            return String(Int(instant.timeIntervalSince1970 * 1000))
        case .text(let text):
            return text.isEmpty ? nil : text
        }
    }

    // MARK: - Query parsing

    /// Parse the applied query back into the form (webapp route-query watch).
    private func populate(from query: [(String, String)], text: String) {
        q = text.isEmpty ? (query.first { $0.0 == "q" }?.1 ?? "") : text
        types = []
        filters = []

        let sortParam = query.first { $0.0 == "sort" }?.1 ?? ""
        if sortParam.hasPrefix("-") {
            sortField = String(sortParam.dropFirst())
            sortDirection = "-"
        } else {
            sortField = sortParam
            sortDirection = ""
        }

        if let single = query.first(where: { $0.0 == "_type.string" })?.1 {
            types = [single]
        }
        if let multiple = query.first(where: { $0.0 == "_type.string.in" })?.1 {
            types = multiple.split(separator: ",").map(String.init)
        }

        for (key, raw) in query {
            if ["q", "_type.string", "_type.string.in", "sort", "limit", "skip"].contains(key) { continue }

            var fieldArray = key.split(separator: ".").map(String.init)
            var op = fieldArray.last ?? ""

            // `in` is intentionally absent — webapp parity: a `.in` key
            // round-trips as part of the field with an empty operator.
            if ["exists", "gt", "gte", "lt", "lte", "ne", "regex"].contains(op) {
                fieldArray.removeLast()
            } else {
                op = ""
            }

            let field = fieldArray.joined(separator: ".")
            let fieldType = Self.fieldType(of: field)

            let value: FilterValue
            if op == "exists" {
                value = .bool(raw.lowercased() == "true")
            } else if fieldType == .boolean {
                value = .bool(raw.lowercased() == "true")
            } else if fieldType == .number || fieldType == .filesize {
                value = .number(Double(raw))
            } else if fieldType == .date || fieldType == .datetime {
                value = .date(Double(raw).map { Date(timeIntervalSince1970: $0 / 1000) })
            } else {
                value = .text(raw)
            }

            filters.append(SearchFilter(field: field, op: op, value: value))
        }

        if filters.isEmpty {
            filters = [SearchFilter()]
        }
    }
}
