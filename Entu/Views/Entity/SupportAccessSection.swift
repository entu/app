// "Entu support access" control on the database entity's detail page —
// the database owner lets Entu support see and change all data for 1, 7 or
// 30 days, or ends a running grant at once. Port of the webapp's
// `components/entity/support-access.vue`: allowing upserts `support_until`
// (replacing the current value by its `_id`), ending deletes every
// `support_until` value. Shown only to the entity's `_owner` and never in a
// support session (`EntityDetailView` decides); the API enforces both.

import SwiftUI

/// Grant / revoke control for Entu support access on a database entity.
struct SupportAccessSection: View {
    @Environment(APIClient.self) private var api

    let entityId: String

    /// The entity's `support_until` values — normally one.
    let values: [PropertyValue]

    /// Called after a successful grant or revoke — the parent reloads the entity.
    let onChanged: () -> Void

    @State private var isUpdating = false
    @State private var errorMessage: String?

    /// Grant lengths offered, in days (webapp parity).
    private let grantDays = [1, 7, 30]

    /// End of the running grant, nil when there is none or it has passed.
    private var grantUntil: Date? {
        values
            .compactMap { $0.datetime.flatMap(ISO8601DateFormatter.parse) }
            .first { $0 > .now }
    }

    var body: some View {
        let until = grantUntil

        VStack(alignment: .leading, spacing: 6) {
            Text("supportAccessTitle")
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            if let until {
                Text("supportAccessActiveUntil \(until, format: .entuDateTime)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("supportAccessDescription")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 8) {
                ForEach(grantDays, id: \.self) { days in
                    Button("supportAllowDays \(days)") {
                        Task { await allow(days: days) }
                    }
                }

                if until != nil {
                    Button("supportRevoke", systemImage: "xmark", role: .destructive) {
                        Task { await revoke() }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isUpdating)
            .padding(.top, 6)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay {
            RoundedRectangle(cornerRadius: CardMetrics.cornerRadius)
                .strokeBorder(until != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.separator), lineWidth: 1)
        }
    }

    // MARK: - Actions

    /// Grants support access for `days` from now, replacing a running grant.
    private func allow(days: Int) async {
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        var change = EntityPropertyChange(type: "support_until")
        change._id = values.first?._id
        change.datetime = ISO8601DateFormatter().string(from: .now.addingTimeInterval(Double(days) * 24 * 60 * 60))

        do {
            let _: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ends support access at once by deleting every grant value.
    private func revoke() async {
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        do {
            for propertyId in values.compactMap(\._id) {
                let _: DeleteResponse = try await api.delete("property/\(propertyId)")
            }
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
            // Some values may already be gone — reload so the shown state is real.
            onChanged()
        }
    }
}
