// Child and referencing entities grouped by type, presented as ONE card:
// a segmented control (type label + count per segment) selects the visible
// group, a pager on the same row pages the selected group's table, and the
// table itself sits in a card below.
//
// Children are fetched via _parent.reference, references via _reference.reference.
// Groups are sorted with children before references, then alphabetically by label.

import SwiftUI

/// Segmented child/reference tables — one visible group at a time in a card.
struct ChildEntitiesSection: View {
    @Environment(APIClient.self) private var api

    let entityId: String

    /// Called when user taps a child entity — navigates to that entity.
    var onNavigate: ((String) -> Void)?

    @State private var groups: [ChildGroup] = []
    @State private var selectedGroupId: String?
    @State private var isLoading = false
    @Namespace private var segmentNamespace

    /// Segment frames in the control's coordinate space — lets a drag
    /// across the pill track slide the selection (not just taps).
    @State private var segmentFrames: [String: CGRect] = [:]

    /// Paging state for the selected group's table — lives here so the
    /// pager can sit on the segment row, outside the table card.
    @State private var page = 1
    @State private var totalCount = 0
    @AppStorage("ui.tablePageSize") private var pageSize = 25

    /// Smallest selectable page size — the pager stays visible whenever the
    /// rows exceed it, so a large page size can't hide the size selector.
    private let minPageSize = 10

    private var totalPages: Int {
        max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    }

    private var selectedGroup: ChildGroup? {
        groups.first { $0.id == selectedGroupId } ?? groups.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                childSkeleton
            } else if !groups.isEmpty {
                HStack {
                    segmentedControl
                    Spacer()
                    if totalCount > minPageSize {
                        pager
                    }
                }
                .padding(.bottom, 12)

                if let group = selectedGroup {
                    EntityTable(
                        entityId: entityId,
                        typeId: group.typeId,
                        referenceField: group.referenceField,
                        page: $page,
                        pageSize: pageSize,
                        onNavigate: onNavigate,
                        onTotalCount: { totalCount = $0 }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .cardSurface()
                    // Fresh table state (columns, sort) per group.
                    .id(group.id)
                    // Horizontal swipe pages the table (touch counterpart
                    // of the ‹ › pager). Fires once on release; the
                    // dominant-axis check keeps vertical scrolling free.
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > 50, abs(dx) > abs(dy) * 1.5 else { return }

                                withAnimation(.snappy(duration: 0.25)) {
                                    if dx < 0, page < totalPages {
                                        page += 1
                                    } else if dx > 0, page > 1 {
                                        page -= 1
                                    }
                                }
                            }
                    )
                }
            }
        }
        .onChange(of: selectedGroupId) {
            page = 1
            totalCount = 0
        }
        .onChange(of: pageSize) {
            page = 1
        }
        .task(id: entityId) { await loadGroups() }
    }

    /// One segment per child/reference group — pill track with a quiet
    /// fill; the selected segment is a card-colored capsule with hairline
    /// and a soft shadow that slides between segments on selection.
    private var segmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(groups) { group in
                let isSelected = group.id == selectedGroup?.id

                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedGroupId = group.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: group.label)
                            .fontWeight(isSelected ? .semibold : .medium)
                            .lineLimit(1)
                        Text(verbatim: "\(group.count)")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color("CardBackground"))
                                .overlay {
                                    Capsule().strokeBorder(Color("CardHairline"), lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                // Slides the pill between segments.
                                .matchedGeometryEffect(id: "selectedSegment", in: segmentNamespace)
                        }
                    }
                    .contentShape(Capsule())
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("childSegments"))
                    } action: { segmentFrames[group.id] = $0 }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.fill.quaternary, in: Capsule())
        .coordinateSpace(name: "childSegments")
        // Sliding a finger (or dragging the pointer) across the track moves
        // the selection like a native segmented control; taps still work
        // through the buttons.
        .simultaneousGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("childSegments"))
                .onChanged { value in
                    guard let hit = segmentFrames.first(where: {
                        $0.value.minX <= value.location.x && value.location.x <= $0.value.maxX
                    })?.key, hit != selectedGroupId else { return }

                    withAnimation(.snappy(duration: 0.25)) {
                        selectedGroupId = hit
                    }
                }
        )
    }

    /// ‹ page / total › plus the page-size picker, on the segment row.
    private var pager: some View {
        HStack(spacing: 8) {
            Button {
                if page > 1 { page -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(page <= 1)
            .accessibilityLabel("previousPage")

            Text(verbatim: "\(page) / \(totalPages)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                if page < totalPages { page += 1 }
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
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// Placeholder shown while the child/reference groups load. Their count
    /// and labels aren't known yet, so it's a single pulsing bar rather than
    /// fabricated segments.
    private var childSkeleton: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.fill.secondary)
            .frame(width: 160, height: 22)
            .padding(.vertical, 12)
            .pulsePlaceholder()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Load

    /// Load child and reference groups, merge and sort them for display.
    private func loadGroups() async {
        isLoading = true

        var allGroups = await fetchGrouped(referenceField: "_parent.reference", type: "child")
        allGroups.append(contentsOf: await fetchGrouped(referenceField: "_reference.reference", type: "reference"))

        // Sort: children before references, then alphabetically by label
        allGroups.sort { "\($0.type) - \($0.label)".localizedCompare("\($1.type) - \($1.label)") == .orderedAscending }

        groups = allGroups
        if selectedGroup == nil || !allGroups.contains(where: { $0.id == selectedGroupId }) {
            selectedGroupId = allGroups.first?.id
        }
        isLoading = false
    }

    // MARK: - Fetch

    /// Fetch entities grouped by type for the given reference field ("child" or "reference").
    private func fetchGrouped(referenceField: String, type: String) async -> [ChildGroup] {
        var params: [String: String] = [
            referenceField: entityId,
            "group": "_type.reference",
            "props": "_type"
        ]

        if type == "reference" {
            params["_reference.property_type.ne"] = "_parent"
        }

        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }

        var groups: [ChildGroup] = []
        for entity in response.entities {
            let typeId = entity.additionalProperties?["_type"]?.first?.reference ?? entity._id
            let count = entity._count ?? 0
            let label = await fetchTypeLabel(typeId: typeId)

            groups.append(ChildGroup(
                typeId: typeId,
                label: label ?? typeId,
                count: count,
                type: type,
                referenceField: referenceField
            ))
        }

        return groups
    }

    /// Fetch the localized plural/singular label for a type entity, with name as fallback.
    private func fetchTypeLabel(typeId: String) async -> String? {
        let params = ["props": "label_plural,label,name"]
        guard let response: EntityDetailResponse = try? await api.get("entity/\(typeId)", params: params) else {
            return nil
        }
        let props = response.entity?.properties
        return PropertyValue.localized(props?["label_plural"])
            ?? PropertyValue.localized(props?["label"])
            ?? PropertyValue.localized(props?["name"])
    }
}

// MARK: - Child group data

// Represents one type group in the child/reference segments (e.g. "Books 3").
private struct ChildGroup: Identifiable {
    let typeId: String
    let label: String
    let count: Int
    let type: String          // "child" or "reference"
    let referenceField: String

    var id: String { "\(referenceField)-\(typeId)" }
}
