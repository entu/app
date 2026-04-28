// Collapsible sections showing child and referencing entities grouped by type.
// Each section header shows the type label and count (e.g. "Books — 3 childs").
// Expanding a section loads the EntityTable with columns from the type definition.
//
// Children are fetched via _parent.reference, references via _reference.reference.
// Groups are sorted with children before references, then alphabetically by label.

import SwiftUI

/// Collapsible sections showing child and referencing entities grouped by type.
struct ChildEntitiesSection: View {
    @Environment(APIClient.self) private var api

    let entityId: String

    // Called when user taps a child entity — navigates to that entity.
    var onNavigate: ((String) -> Void)?

    @State private var groups: [ChildGroup] = []
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group.id, isFirst: index == 0)) {
                        EntityTable(
                            entityId: entityId,
                            typeId: group.typeId,
                            referenceField: group.referenceField,
                            onNavigate: onNavigate
                        )
                    } label: {
                        HStack {
                            Text(verbatim: group.label)
                                .font(.headline)
                            Spacer()
                            group.countLabel
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .task(id: entityId) { await loadGroups() }
    }

    // First group expanded by default, rest collapsed. Each can be toggled independently.
    private func expansionBinding(for groupId: String, isFirst: Bool) -> Binding<Bool> {
        Binding(
            get: { expandedGroups[groupId] ?? isFirst },
            set: { expandedGroups[groupId] = $0 }
        )
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

// Represents one type group in the child/reference list (e.g. "Books — 3 childs").
private struct ChildGroup: Identifiable {
    let typeId: String
    let label: String
    let count: Int
    let type: String          // "child" or "reference"
    let referenceField: String

    var id: String { "\(referenceField)-\(typeId)" }

    // Count label matching webapp: "1 child" / "n childs" or "1 referrer" / "n referrers".
    // Returned as `Text` so the `LocalizedStringKey` interpolation observes the env locale.
    var countLabel: Text {
        if type == "child" {
            return count == 1 ? Text("childCount1") : Text("childCountN \(count)")
        } else {
            return count == 1 ? Text("referrerCount1") : Text("referrerCountN \(count)")
        }
    }
}
