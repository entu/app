// Paginated, sortable table for displaying a list of entities.
// Used inside ChildEntitiesSection for both child and referencing entity groups.
//
// Fetches column definitions from the entity type (properties with "table" flag set),
// then loads entities with those properties. Falls back to showing just the name column
// if no table columns are defined for the type.

import SwiftUI

/// Column definition for the entity table.
struct EntityTableColumn: Identifiable {
    let name: String
    let label: String
    let type: String
    let decimals: Int?

    var id: String { name }
}

/// Paginated, sortable table for child/referencing entity lists.
struct EntityTable: View {
    @Environment(APIClient.self) private var api

    let entityId: String
    let typeId: String
    let referenceField: String
    var onNavigate: ((String) -> Void)?

    @State private var columns: [EntityTableColumn] = []
    @State private var entities: [EntitySummary] = []
    @State private var totalCount = 0
    @State private var page = 1
    @AppStorage("ui.tablePageSize") private var pageSize = 25
    @State private var sortColumn = "name"
    @State private var sortAscending = true
    @State private var isLoading = false

    private var totalPages: Int { max(1, Int(ceil(Double(totalCount) / Double(pageSize)))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && entities.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                tableHeader
                Divider()
                tableRows
                pagination
            }
        }
        .task {
            await loadColumns()
            await loadEntities()
        }
    }

    // MARK: - Table header

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 36)

            ForEach(columns) { column in
                Button {
                    if sortColumn == column.name {
                        sortAscending.toggle()
                    } else {
                        sortColumn = column.name
                        sortAscending = true
                    }
                    page = 1
                    Task { await loadEntities() }
                } label: {
                    HStack(spacing: 4) {
                        Text(column.label.isEmpty ? column.name : column.label)

                        if sortColumn == column.name {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: columnAlignment(column))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .fontWeight(.bold)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    // MARK: - Table rows

    private var tableRows: some View {
        ForEach(entities) { entity in
            Button {
                onNavigate?(entity._id)
            } label: {
                HStack(spacing: 0) {
                    EntityAvatar(name: entity.displayName, thumbnail: entity._thumbnail)
                        .frame(width: 36)

                    ForEach(columns) { column in
                        cellContent(entity: entity, column: column)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }

    // MARK: - Cell content (type-specific rendering)

    /// Renders a single table cell, formatting the value based on the column's declared type.
    @ViewBuilder
    private func cellContent(entity: EntitySummary, column: EntityTableColumn) -> some View {
        let values = column.name == "name" ? entity.name : entity.additionalProperties?[column.name]
        let value = localizedValue(values)

        Group {
            switch column.type {
            case "number":
                if let num = value?.number {
                    if let decimals = column.decimals {
                        Text(num, format: .number.precision(.fractionLength(decimals))).monospacedDigit()
                    } else {
                        Text(num, format: .number).monospacedDigit()
                    }
                }
            case "boolean":
                if value?.boolean == true {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            case "date", "datetime":
                if let str = value?.string { Text(str) }
            case "file":
                if let filename = value?.filename { Text(filename) }
            case "reference":
                Text(value?.string ?? value?.reference ?? "")
            default:
                Text(value?.string ?? (column.name == "name" ? entity._id : ""))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: columnAlignment(column))
        .padding(.horizontal, 8)
    }

    // MARK: - Pagination

    @ViewBuilder
    private var pagination: some View {
        if totalCount > pageSize {
            HStack {
                Spacer()

                Button {
                    if page > 1 { page -= 1; Task { await loadEntities() } }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(page <= 1)
                .accessibilityLabel("previousPage")

                Text("\(page) / \(totalPages)")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 8)

                Button {
                    if page < totalPages { page += 1; Task { await loadEntities() } }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(page >= totalPages)
                .accessibilityLabel("nextPage")

                Picker("", selection: $pageSize) {
                    Text("10").tag(10)
                    Text("25").tag(25)
                    Text("100").tag(100)
                }
                .frame(width: 70)
                .accessibilityLabel("pageSize")
                .onChange(of: pageSize) {
                    page = 1
                    Task { await loadEntities() }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func localizedValue(_ values: [PropertyValue]?) -> PropertyValue? {
        guard let values, !values.isEmpty else { return nil }
        let locale = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"

        return values.first { $0.language == locale }
            ?? values.first { $0.language == nil }
            ?? values.first
    }

    private func columnAlignment(_ column: EntityTableColumn) -> Alignment {
        switch column.type {
        case "number": return .trailing
        case "boolean": return .center
        default: return .leading
        }
    }

    // MARK: - Data loading

    /// Fetch column definitions — properties with "table" flag set, sorted by ordinal.
    /// Falls back to a single "name" column when the type defines none.
    private func loadColumns() async {
        let tableParams: [String: String] = [
            "_parent.reference": typeId,
            "table._id.exists": "true",
            "props": "name,label,type,decimals",
            "sort": "ordinal.number"
        ]

        if let response: EntityListResponse = try? await api.get("entity", params: tableParams),
           !response.entities.isEmpty {
            columns = response.entities.map { entity in
                EntityTableColumn(
                    name: PropertyValue.localized(entity.name) ?? entity._id,
                    label: PropertyValue.localized(entity.additionalProperties?["label"]) ?? "",
                    type: PropertyValue.localized(entity.additionalProperties?["type"]) ?? "string",
                    decimals: entity.additionalProperties?["decimals"]?.first?.number.map { Int($0) }
                )
            }
            return
        }

        columns = [EntityTableColumn(name: "name", label: "", type: "string", decimals: nil)]
    }

    /// Fetch entities for the current page with the current sort applied.
    private func loadEntities() async {
        isLoading = true

        var sortFieldType = columns.first(where: { $0.name == sortColumn })?.type ?? "string"
        if ["text", "reference"].contains(sortFieldType) { sortFieldType = "string" }

        let sortPrefix = sortAscending ? "" : "-"
        let propNames = columns.map { $0.name }.joined(separator: ",")

        let params: [String: String] = [
            referenceField: entityId,
            "_type.reference": typeId,
            "props": "_thumbnail,_sharing,name,\(propNames)",
            "sort": "\(sortPrefix)\(sortColumn).\(sortFieldType)",
            "limit": String(pageSize),
            "skip": String(pageSize * (page - 1))
        ]

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            entities = response.entities
            totalCount = response.count ?? 0
        }
        isLoading = false
    }
}
