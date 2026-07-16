// Renders a proposal attached to an assistant message as one white card:
// each queued operation gets a kicker title ("NEW · BOOK"-style), a
// full-width hairline, and its property rows; a final hairline separates
// the Cancel / content-aware confirm buttons. Mirrors the webapp's
// `components/chat/proposal.vue` semantics with the 19b card design.

import SwiftUI

/// Proposal review card — operation sections plus review actions.
struct ChatProposalView: View {
    @Environment(APIClient.self) private var api

    let operations: [ProposalOperation]
    let results: ExecutionResults?
    let isPending: Bool
    let isExecuting: Bool
    let declined: Bool

    let onApply: () -> Void
    let onCancel: () -> Void
    /// Open a created entity in the main layout (dismisses the chat sheet).
    let onOpenEntity: (String) -> Void

    /// Localized label of the single create's type — drives "Create <label>".
    @State private var buttonTypeLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(operations.enumerated()), id: \.offset) { index, operation in
                    if index > 0 {
                        Divider()
                    }

                    OperationSection(
                        operation: operation,
                        status: OperationStatus.resolve(index: index, results: results),
                        errorMessage: errorMessage(for: index),
                        createdEntityId: createdEntityId(for: index),
                        onOpenEntity: onOpenEntity
                    )
                }

                if declined {
                    Divider()

                    Text("aiProposalDeclined")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                } else if isPending {
                    Divider()

                    HStack(spacing: 6) {
                        Button(role: .cancel, action: onCancel) {
                            Text("cancel")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(isExecuting)

                        Button(action: onApply) {
                            applyLabel
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(isExecuting)

                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                }
            }
            .cardSurface()

            if isPending && !declined {
                Text("aiNothingSaved")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            if operations.count == 1, operations[0].op.lowercased() == "create_entity",
               let type = operations[0].entityTypeParam {
                buttonTypeLabel = await AIProposalLabels.typeLabel(api: api, typeName: type)
            }
        }
    }

    /// Content-aware confirm label: "Create <type label>" for a single
    /// create, count-based for several, save/delete wording for homogeneous
    /// update/delete proposals, generic Apply otherwise.
    private var applyLabel: Text {
        let ops = operations.map { $0.op.lowercased() }

        if ops.allSatisfy({ $0 == "create_entity" }) {
            if operations.count == 1, let type = buttonTypeLabel ?? operations[0].entityTypeParam {
                return Text("aiCreateType \(type)")
            }
            return Text("aiCreateCount \(operations.count)")
        }
        if ops.allSatisfy({ $0 == "update_entity" }) {
            return Text("aiSaveChanges")
        }
        if ops.allSatisfy({ $0.contains("delete") }) {
            return Text("aiDeleteConfirm")
        }
        if ops.allSatisfy({ $0 == "create_entity_type" }) {
            return Text("aiCreateTypeConfirm")
        }
        if ops.allSatisfy({ $0 == "add_property_definition" }) {
            return Text("aiAddPropertyConfirm")
        }

        return Text("aiConfirmChanges")
    }

    /// Error text for the operation that failed (only on `error.index`).
    private func errorMessage(for index: Int) -> String? {
        guard let error = results?.error, error.index == index else { return nil }
        return error.statusMessage
    }

    /// The created entity id for an applied operation, when the API returned one.
    private func createdEntityId(for index: Int) -> String? {
        guard OperationStatus.resolve(index: index, results: results) == .applied,
              let results = results?.results, index < results.count else {
            return nil
        }
        return results[index]._id
    }
}

// MARK: - Operation section

/// One operation inside the card: kicker title row, full-width hairline,
/// then the property rows (or the raw-params disclosure for operations
/// without a preview, e.g. deletes).
private struct OperationSection: View {
    @Environment(APIClient.self) private var api

    let operation: ProposalOperation
    let status: OperationStatus?
    let errorMessage: String?
    let createdEntityId: String?
    let onOpenEntity: (String) -> Void

    @State private var showDetails = false

    /// Resolved localized label for the kicker — the create's type label,
    /// or the affected entity's name for updates/deletes.
    @State private var resolvedLabel: String?

    /// Previous values of replaced properties, keyed by value id — an
    /// update that replaces a value renders as "old → new".
    @State private var oldValues: [String: String] = [:]

    var body: some View {
        // One uniform rhythm: the gap between the title row and the rows
        // equals the section's top/bottom padding.
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                kicker
                    .textCase(.uppercase)
                    .font(.caption2.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)

                Spacer()

                statusBadge
            }

            VStack(alignment: .leading, spacing: 6) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let rows = propertyRows {
                    // Design-style property rows: right-aligned quiet labels,
                    // references as accent chips, replaced values as
                    // "old → new".
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(verbatim: row.label)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 88, alignment: .trailing)

                                if let valueId = row.valueId, let old = oldValues[valueId] {
                                    Text(verbatim: old)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }

                                if row.isReference {
                                    Text(verbatim: row.value)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.tint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                                } else {
                                    Text(verbatim: row.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else if let detailText = operation.detailText {
                    DisclosureGroup(isExpanded: $showDetails) {
                        Text(detailText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("aiDetails")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let createdEntityId {
                    Button {
                        onOpenEntity(createdEntityId)
                    } label: {
                        Label("aiOpenCreated", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .task {
            switch operation.op.lowercased() {
            case "create_entity":
                if let type = operation.entityTypeParam {
                    resolvedLabel = await AIProposalLabels.typeLabel(api: api, typeName: type)
                }
            case "update_entity", "delete_entity":
                if let id = operation.entityIdParam {
                    resolvedLabel = await AIProposalLabels.entityName(api: api, entityId: id)
                }
            default:
                break
            }

            // Fetch the current values of properties this operation replaces.
            for row in propertyRows ?? [] {
                guard let valueId = row.valueId, oldValues[valueId] == nil else { continue }

                if let old = await AIProposalLabels.propertyValue(api: api, propertyId: valueId) {
                    oldValues[valueId] = old
                }
            }
        }
    }

    /// Kicker title by operation kind — "NEW · BOOK" style for creates,
    /// the affected entity's name for updates/deletes.
    private var kicker: Text {
        switch operation.op.lowercased() {
        case "create_entity":
            if let type = resolvedLabel ?? operation.entityTypeParam {
                return Text("aiOpCreate \(type)")
            }
            return Text("aiOpCreateBare")
        case "update_entity":
            if let name = resolvedLabel {
                return Text("aiOpUpdateNamed \(name)")
            }
            return Text("aiOpUpdate")
        case "delete_entity":
            if let name = resolvedLabel {
                return Text("aiOpDeleteNamed \(name)")
            }
            return Text("aiOpDeleteEntity")
        case "delete_property":
            return Text("aiOpDeleteProperty")
        case "create_entity_type":
            return Text("aiOpCreateType")
        case "add_property_definition":
            return Text("aiOpAddPropertyDefinition")
        default:
            return Text(verbatim: operation.op)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .applied:
            Label("aiApplied", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .accessibilityLabel("aiApplied")
        case .failed:
            Label("aiFailed", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .accessibilityLabel("aiFailed")
        case .skipped:
            Text("aiSkipped")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    /// One row per property record in the operation's preview. The API's
    /// `aiPreviewOperationProperties` always returns an array of
    /// `{type, string|number|boolean|reference|date|datetime, language?}`
    /// records — anything else (delete ops have no preview) falls back to
    /// the raw-params disclosure.
    private struct PropertyRowItem: Identifiable {
        let id: Int
        let label: String
        let value: String
        let isReference: Bool
        /// Id of the value this record replaces (update operations) — the
        /// old value is fetched and shown as "old → new".
        let valueId: String?
    }

    private var propertyRows: [PropertyRowItem]? {
        guard case .array(let records)? = operation.properties, !records.isEmpty else { return nil }

        let rows = records.enumerated().compactMap { index, record -> PropertyRowItem? in
            guard case .object(let dict) = record,
                  case .string(let name)? = dict["type"] else { return nil }

            let value = dict["string"]
                ?? dict["number"]
                ?? dict["boolean"]
                ?? dict["reference"]
                ?? dict["date"]
                ?? dict["datetime"]
            guard let text = value?.displayString else { return nil }

            // Humanize the property name: "_parent" → "Parent", "label_plural"
            // → "Label plural"; multilingual values carry their language tag.
            var label = name.hasPrefix("_") ? String(name.dropFirst()) : name
            label = label.replacingOccurrences(of: "_", with: " ")
            label = label.prefix(1).uppercased() + label.dropFirst()
            if case .string(let language)? = dict["language"] {
                label += " · \(language)"
            }

            var valueId: String?
            if case .string(let id)? = dict["_id"] {
                valueId = id
            }

            return PropertyRowItem(
                id: index,
                label: label,
                value: text,
                isReference: dict["reference"] != nil,
                valueId: valueId
            )
        }

        return rows.isEmpty ? nil : rows
    }
}

// MARK: - Operation params helpers

extension ProposalOperation {
    /// The `type` param of a create_entity operation — the (unresolved)
    /// entity type name, e.g. "book". Used by the kicker and the confirm
    /// button label until the localized label resolves.
    var entityTypeParam: String? {
        guard case .object(let dict)? = params,
              case .string(let type)? = dict["type"] else { return nil }
        return type
    }

    /// The `_id` param of an update/delete operation — the affected entity.
    var entityIdParam: String? {
        guard case .object(let dict)? = params,
              case .string(let id)? = dict["_id"] else { return nil }
        return id
    }
}

// MARK: - Label resolution

/// Resolves and session-caches the localized labels shown on proposal
/// kickers and the confirm button: a type name → the type entity's `label`,
/// an entity id → its display name. Keys carry database + language so
/// switches never serve stale values.
@MainActor
private enum AIProposalLabels {
    static var cache: [String: String] = [:]

    static func typeLabel(api: APIClient, typeName: String) async -> String? {
        let key = "type:\(api.databaseId ?? ""):\(AppLanguage.current.rawValue):\(typeName)"
        if let cached = cache[key] { return cached }

        guard let response: EntityListResponse = try? await api.get("entity", params: [
            "_type.string": "entity",
            "name.string": typeName,
            "props": "label,name",
            "limit": "1"
        ]), let entity = response.entities.first else { return nil }

        let label = PropertyValue.localized(entity.additionalProperties?["label"])
            ?? PropertyValue.localized(entity.name)
        if let label { cache[key] = label }

        return label
    }

    static func entityName(api: APIClient, entityId: String) async -> String? {
        let key = "entity:\(api.databaseId ?? ""):\(AppLanguage.current.rawValue):\(entityId)"
        if let cached = cache[key] { return cached }

        guard let response: EntityDetailResponse = try? await api.get(
            "entity/\(entityId)",
            params: ["props": "name"]
        ), let name = PropertyValue.localized(response.entity?.properties["name"]) else { return nil }

        cache[key] = name

        return name
    }

    /// Current display value of a property record (`GET /property/{id}`) —
    /// the "old" side of an update's "old → new" row. Reference values
    /// resolve to the referenced entity's name.
    static func propertyValue(api: APIClient, propertyId: String) async -> String? {
        let key = "property:\(api.databaseId ?? ""):\(AppLanguage.current.rawValue):\(propertyId)"
        if let cached = cache[key] { return cached }

        guard let record: JSONValue = try? await api.get("property/\(propertyId)"),
              case .object(let dict) = record else { return nil }

        var text: String?
        if case .string(let reference)? = dict["reference"] {
            text = await entityName(api: api, entityId: reference) ?? reference
        } else {
            text = (dict["string"] ?? dict["number"] ?? dict["boolean"] ?? dict["date"] ?? dict["datetime"])?.displayString
        }

        if let text { cache[key] = text }

        return text
    }
}
