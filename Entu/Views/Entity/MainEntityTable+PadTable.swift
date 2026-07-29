// The iPadOS rendering of `MainEntityTable` — split out per the codebase's
// +Extension convention. A hand-rolled single two-axis ScrollView with a
// pinned header: the native `Table` lays its rows out around a ZERO-SIZED
// collection view on iPadOS 26 (rows paint unclipped, nothing scrolls),
// and nesting a vertical scroller inside a horizontal one applies the top
// safe area as a content inset on BOTH, opening blank bands — see the
// "Table is macOS-only in this app" note in CLAUDE-APP.md. The pad-only
// stored state (`padColumnWidths`, `padDragBaseWidth`) lives in the main
// file (extensions can't hold @State).

#if !os(macOS)
import SwiftUI

extension MainEntityTable {
    static let padNameWidth: CGFloat = 200
    static let padColumnWidth: CGFloat = 160
    static let padMinColumnWidth: CGFloat = 60
    static let padHandleWidth: CGFloat = 12
    static let padAvatarCellWidth: CGFloat = 30

    func padWidth(of column: MainTableColumn) -> CGFloat {
        padColumnWidths[column.name] ?? (column.name == "name" ? Self.padNameWidth : Self.padColumnWidth)
    }

    /// A single two-axis ScrollView with the header as a pinned section
    /// header — it pins vertically and pans horizontally with the cells.
    var padTable: some View {
        let columns = columns

        return GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(entities) { entity in
                            padRow(entity, columns: columns)

                            if entity.id != entities.last?.id {
                                Divider()
                            }
                        }

                        if isLoadingMore {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.vertical, 8)
                        }
                    } header: {
                        padHeaderRow(columns: columns)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: proxy.size.width, alignment: .topLeading)
            }
            // The app's window background behind the rows — a bare white
            // sheet reads as a gap against the floating sidebar.
            .background(Color("WindowBackground"))
        }
    }

    /// Sort header — tapping toggles direction or switches the column; the
    /// drag handle after each column resizes it.
    private func padHeaderRow(columns: [MainTableColumn]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.padAvatarCellWidth, height: 1)
            ForEach(columns) { column in
                Button {
                    let ascending = sortColumn == column.name ? !sortAscending : true
                    applySort(column: column, ascending: ascending)
                } label: {
                    SortColumnHeaderLabel(
                        text: columnLabels[column.name] ?? column.name,
                        isActive: sortColumn == column.name,
                        ascending: sortAscending
                    )
                    .frame(maxWidth: .infinity, alignment: EntityTableCell.alignment(for: column.type))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: padWidth(of: column))

                padResizeHandle(for: column)
            }
        }
        .padding(.vertical, 8)
        // Same full-width stretch as the rows — the bar material band
        // shouldn't stop at the last column either.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Drag zone between column headers — a hairline tick marks it; drag
    /// adjusts the column's width against its start-of-drag value.
    private func padResizeHandle(for column: MainTableColumn) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.padHandleWidth)
            .overlay {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if padDragBaseWidth == nil { padDragBaseWidth = padWidth(of: column) }
                        padColumnWidths[column.name] = max(Self.padMinColumnWidth, (padDragBaseWidth ?? 0) + value.translation.width)
                    }
                    .onEnded { _ in padDragBaseWidth = nil }
            )
    }

    /// Row — plain SwiftUI hierarchy, so the shared row context menu keeps
    /// its environment. Tap selects (arming the entity actions); a
    /// hardware-keyboard ⌘-tap opens the entity window instead, same as the list
    /// rows' interception.
    private func padRow(_ entity: EntitySummary, columns: [MainTableColumn]) -> some View {
        HStack(spacing: 0) {
            EntityAvatar(name: entity.displayName, entityId: entity._id, hasPhoto: entity.hasPhoto, size: 18)
                .frame(width: Self.padAvatarCellWidth, alignment: .leading)
            ForEach(columns) { column in
                EntityTableCell(entity: entity, column: column.asTableColumn)
                    .frame(width: padWidth(of: column), alignment: EntityTableCell.alignment(for: column.type))
                    // Keeps cells aligned under their headers — the header
                    // carries the resize handle in this slot.
                    .padding(.trailing, Self.padHandleWidth)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        // Stretch to the stack's full width (≥ viewport via `minWidth`)
        // so the selection background runs to the table's edge instead
        // of stopping at the last column's data.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selection == entity._id ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        // Double-tap before single: SwiftUI then waits to disambiguate,
        // so a double never also toggles selection. Double-tap opens a
        // new window — the table never opens the entity in place (same
        // as the macOS table's double-click).
        .onTapGesture(count: 2) {
            openEntityInNewWindow?.invoke(entity._id)
        }
        .onTapGesture {
            if ModifierState.isCommandHeld {
                openEntityInNewWindow?.invoke(entity._id)
                return
            }

            selection = selection == entity._id ? nil : entity._id
        }
        .entityRowContextMenu(entityId: entity._id) {
            selection = entity._id
        }
        .onAppear {
            if entity.id == entities.last?.id && hasMore && !isLoadingMore {
                Task { await loadMore() }
            }
        }
    }
}
#endif
