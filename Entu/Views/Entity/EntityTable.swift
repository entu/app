// Paginated, sortable list of entities for a single child/reference type.
// Used inside ChildEntitiesSection — fetches column definitions from the
// entity type (properties with the `table` flag) and loads entities with
// those properties projected.
//
// Layout uses SwiftUI's `Grid` because it composes cleanly with the
// surrounding ScrollView and reports an honest intrinsic height (one
// row's worth per row, no estimation). SwiftUI's `Table` would nest a
// scroll view inside the parent's ScrollView and gives no API for either
// per-row height control or intrinsic sizing — Apple's recommendation
// for table-like content inside scroll views is `Grid`/`LazyVGrid`.

import SwiftUI

/// Column definition for the entity table.
struct EntityTableColumn: Identifiable {
    let name: String
    let label: String
    let type: String
    let decimals: Int?

    var id: String { name }
}

/// Paginated, sortable list for child/referencing entity groups.
struct EntityTable: View {
    @Environment(APIClient.self) private var api
    @Environment(\.locale) private var locale

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
                grid
                pagination
            }
        }
        .task {
            await loadColumns()
            await loadEntities()
        }
    }

    // MARK: - Grid

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            headerRow
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(entities) { entity in
                GridRow {
                    EntityAvatar(name: entity.displayName, thumbnail: entity._thumbnail, size: 18)
                    ForEach(columns) { column in
                        cellContent(entity: entity, column: column)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { onNavigate?(entity._id) }

                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }

    /// Header row — empty cell aligned to the avatar column, then a sort
    /// button per data column. Tapping a column toggles direction or
    /// switches the active column; the change refetches server-side.
    private var headerRow: some View {
        GridRow {
            Color.clear.frame(width: 18, height: 1)
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
                    .frame(maxWidth: .infinity, alignment: cellAlignment(for: column.type))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Cell content (type-specific rendering)

    /// Render a single grid cell, formatting by the column's declared type.
    /// Numbers right-align, booleans + dates centre, everything else leads.
    @ViewBuilder
    private func cellContent(entity: EntitySummary, column: EntityTableColumn) -> some View {
        let values = column.name == "name" ? entity.name : entity.additionalProperties?[column.name]
        let value = PropertyValue.best(values)

        Group {
            switch column.type {
            case "number":
                if let num = value?.number {
                    let format: FloatingPointFormatStyle<Double> = .number
                        .precision(.fractionLength(column.decimals ?? 0))
                        .locale(locale)
                    Text(num, format: format)
                }
            case "boolean":
                if value?.boolean == true {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            case "date":
                if let iso = value?.date, let date = ISO8601DateFormatter.parse(iso) {
                    Text(date, format: Date.FormatStyle(date: .numeric, time: .omitted, locale: locale))
                } else if let str = value?.string {
                    Text(str)
                }
            case "datetime":
                if let iso = value?.datetime, let date = ISO8601DateFormatter.parse(iso) {
                    Text(date, format: Date.FormatStyle(date: .numeric, time: .shortened, locale: locale))
                } else if let str = value?.string {
                    Text(str)
                }
            case "file":
                if let filename = value?.filename {
                    HStack(spacing: 6) {
                        Text(filename)
                        if let size = value?.filesize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case "reference":
                Text(value?.string ?? value?.reference ?? "")
            default:
                Text(value?.string ?? (column.name == "name" ? entity._id : ""))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: cellAlignment(for: column.type))
    }

    /// Cell-content alignment by property type — numbers trailing,
    /// booleans + dates centre, everything else leading.
    private func cellAlignment(for type: String) -> Alignment {
        switch type {
        case "number": return .trailing
        case "boolean", "date", "datetime": return .center
        default: return .leading
        }
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

    // MARK: - Data loading

    /// Fetch column definitions — properties with `table` flag set, sorted by ordinal.
    /// Falls back to a single `name` column when the type defines none.
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
