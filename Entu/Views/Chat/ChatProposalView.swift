// Renders a proposal attached to an assistant message: one row per queued
// operation (icon + description + expandable details), a per-operation
// status once executed, and Apply / Cancel actions while pending. Mirrors
// the webapp's `components/chat/proposal.vue`.

import SwiftUI

/// Proposal review card — operation list plus review actions.
struct ChatProposalView: View {
    let operations: [ProposalOperation]
    let results: ExecutionResults?
    let isPending: Bool
    let isExecuting: Bool
    let declined: Bool

    let onApply: () -> Void
    let onCancel: () -> Void
    /// Open a created entity in the main layout (dismisses the chat sheet).
    let onOpenEntity: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(operations.enumerated()), id: \.offset) { index, operation in
                OperationRow(
                    operation: operation,
                    status: OperationStatus.resolve(index: index, results: results),
                    errorMessage: errorMessage(for: index),
                    createdEntityId: createdEntityId(for: index),
                    onOpenEntity: onOpenEntity
                )
            }

            if declined {
                Text("aiProposalDeclined")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isPending {
                HStack {
                    Button("cancel", role: .cancel, action: onCancel)
                        .disabled(isExecuting)

                    Button("apply", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .disabled(isExecuting)

                    if isExecuting {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
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

// MARK: - Operation row

private struct OperationRow: View {
    let operation: ProposalOperation
    let status: OperationStatus?
    let errorMessage: String?
    let createdEntityId: String?
    let onOpenEntity: (String) -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.description ?? operation.op)
                        .font(.subheadline)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 4)

                statusBadge
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
                .padding(.leading, 26)
            }

            if let detailText = operation.detailText {
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
                .padding(.leading, 26)
            }
        }
    }

    /// SF Symbol matching the operation kind — add / edit / delete / other.
    private var icon: String {
        let name = operation.op.lowercased()

        if name.contains("delete") { return "trash" }
        if name.contains("create") || name.contains("add") { return "plus.circle" }
        if name.contains("update") || name.contains("edit") || name.contains("set") { return "pencil" }

        return "doc.text"
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
}
