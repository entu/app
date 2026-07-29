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

/// Type-aware table cell shared by the child/reference tables
/// (`EntityTable`) and the main-list table (`MainEntityTable`) — formats
/// one property value by column type. Numbers right-align, booleans +
/// dates centre, everything else leads.
struct EntityTableCell: View {
    @Environment(\.locale) private var locale

    let entity: EntitySummary
    let column: EntityTableColumn

    var body: some View {
        let values = column.name == "name" ? entity.name : entity.additionalProperties?[column.name]
        let value = PropertyValue.best(values)

        // ZStack, not Group: an empty cell (no value) resolves to
        // EmptyView, which a transparent Group drops from layout entirely
        // — the surrounding `.frame` would vanish with it and the row's
        // remaining cells would shift. ZStack materializes the frame.
        ZStack {
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
            // "file" is the declared property type (child tables);
            // "filename"/"filesize" are the value-detected types the main
            // table's webapp-parity auto-detection produces.
            case "file", "filename":
                if let filename = value?.filename {
                    HStack(spacing: 6) {
                        Text(filename)
                        if let size = value?.filesize {
                            Text(size.fileSizeString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case "filesize":
                if let size = value?.filesize {
                    Text(size.fileSizeString)
                }
            case "reference":
                Text(value?.string ?? value?.reference ?? "")
            default:
                Text(value?.string ?? (column.name == "name" ? entity._id : ""))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: Self.alignment(for: column.type))
    }

    /// Cell-content alignment by property type — numbers trailing,
    /// booleans + dates centre, everything else leading.
    static func alignment(for type: String) -> Alignment {
        switch type {
        case "number": return .trailing
        case "boolean", "date", "datetime": return .center
        default: return .leading
        }
    }
}

/// Sort-header label — column text plus the direction chevron when the
/// column is the active sort. Shared by the child tables' `Grid` header
/// and the main table's iPad header.
struct SortColumnHeaderLabel: View {
    let text: String
    let isActive: Bool
    let ascending: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: text)
                .lineLimit(1)
            if isActive {
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
        }
    }
}

/// Sortable table for one child/referencing entity group. Paging state is
/// owned by `ChildEntitiesSection` (the pager sits on its segment row);
/// the table reloads on page/pageSize changes and reports the row count
/// back via `onTotalCount`.
struct EntityTable: View {
    @Environment(APIClient.self) private var api
    @Environment(\.locale) private var locale

    let entityId: String
    let typeId: String
    let referenceField: String
    @Binding var page: Int
    var pageSize: Int = 25
    var onNavigate: ((String) -> Void)?
    var onTotalCount: ((Int) -> Void)?

    @State private var columns: [EntityTableColumn] = []
    @State private var entities: [EntitySummary] = []
    @State private var totalCount = 0
    @State private var sortColumn = "name"
    @State private var sortAscending = true
    @State private var isLoading = false

    private var totalPages: Int { max(1, Int(ceil(Double(totalCount) / Double(pageSize)))) }

    /// Touch platforms get taller rows (≈44pt targets); macOS stays compact.
    private var rowVerticalPadding: CGFloat {
        #if os(macOS)
        8
        #else
        12
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && entities.isEmpty {
                EntityRowsPlaceholder(count: 5, avatarSize: 18)
            } else {
                grid
            }
        }
        .onChange(of: page) {
            Task { await loadEntities() }
        }
        .onChange(of: pageSize) {
            Task { await loadEntities() }
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
            ForEach(entities) { entity in
                GridRow {
                    EntityAvatar(name: entity.displayName, entityId: entity._id, hasPhoto: entity.hasPhoto, size: 18)
                    ForEach(columns) { column in
                        EntityTableCell(entity: entity, column: column)
                    }
                }
                .padding(.vertical, rowVerticalPadding)
                .contentShape(Rectangle())
                .onTapGesture { onNavigate?(entity._id) }
                // Same entity-actions context menu as the list rows —
                // navigates to the child, then runs the action once its
                // detail is loaded (rights-gated there).
                .entityRowContextMenu(entityId: entity._id) {
                    onNavigate?(entity._id)
                }

                // Hairline between rows, none after the last.
                if entity.id != entities.last?.id {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
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
                    // Writing page triggers the reload via onChange; when
                    // already on page 1 reload directly.
                    if page == 1 {
                        Task { await loadEntities() }
                    } else {
                        page = 1
                    }
                } label: {
                    SortColumnHeaderLabel(
                        text: column.label.isEmpty ? column.name : column.label,
                        isActive: sortColumn == column.name,
                        ascending: sortAscending
                    )
                    .frame(maxWidth: .infinity, alignment: EntityTableCell.alignment(for: column.type))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
            "props": "photo,_sharing,name,\(propNames)",
            "sort": "\(sortPrefix)\(sortColumn).\(sortFieldType)",
            "limit": String(pageSize),
            "skip": String(pageSize * (page - 1))
        ]

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            entities = response.entities
            totalCount = response.count ?? 0
            onTotalCount?(totalCount)
        }
        isLoading = false
    }
}
