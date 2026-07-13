// Per-entity duplicate drawer. Mirrors webapp's
// `components/entity/drawer/duplicate.vue` — pick how many copies to make
// (1-100) and which properties to include.
//
// Excluded from the list: `_`-prefixed system properties (carried over by
// the server automatically), empty values, formula properties (the server
// will recompute them), file properties (the server copies file refs
// itself), and the reserved `entu_api_key` / `entu_user` (sensitive).
//
// Owner-only sheet — visibility is gated by the parent EntityToolbar.

import SwiftUI

/// Duplicate-with-property-selection sheet for a single entity.
struct DuplicateSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let entityId: String
    var onDuplicated: (() -> Void)?

    @State private var entity: EntityDetail?
    @State private var definitions: [PropertyDefinition] = []
    @State private var count: Int = 1
    @State private var ignored: Set<String> = []
    @State private var isLoading = true
    @State private var isUpdating = false
    @State private var loadError: String?
    @State private var commitError: String?

    /// Server caps at 100; webapp caps its UI input at 50. Match webapp.
    private static let maxCount: Int = 50

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            sheetHeader
            #endif
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                } else {
                    formBody
                }
            }
        }
        #if os(iOS)
        .navigationTitle(Text("duplicate"))
        .navigationSubtitle(headerSubtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton(isDisabled: isUpdating) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await duplicate() }
                } label: {
                    Text(submitTitle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUpdating || availableProperties.isEmpty)
            }
        }
        .alert(
            "duplicate",
            isPresented: Binding(
                get: { commitError != nil },
                set: { if !$0 { commitError = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            if let commitError { Text(commitError) }
        }
        .task { await load() }
        .appLanguageScoped()
    }

    /// Subtitle: entity name, fall back to type label.
    private var headerSubtitle: String? {
        if let name = PropertyValue.localized(entity?.properties["name"]), !name.isEmpty {
            return name
        }
        return entity?.typeName
    }

    #if os(macOS)
    /// In-content title bar for macOS sheets. See EntityEditView.swift —
    /// macOS sheets don't render the toolbar's principal slot.
    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("duplicate")
                .font(.headline)
            if let headerSubtitle, !headerSubtitle.isEmpty {
                Text(verbatim: headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    #endif

    private var submitTitle: LocalizedStringKey {
        count == 1 ? "createDuplicate" : "createDuplicates \(count)"
    }

    // MARK: - Form

    private var formBody: some View {
        Form {
            Section("numberOfCopies") {
                // Manual HStack — `Stepper`'s label slot rendered the count
                // text in its own baseline-shifted frame which left more
                // bottom padding than top inside the form row.
                HStack {
                    Text("\(count)")
                        .monospacedDigit()
                    Spacer()
                    Stepper("", value: $count, in: 1...Self.maxCount)
                        .labelsHidden()
                }
                .disabled(isUpdating)
            }

            Section("propertiesToInclude") {
                ForEach(availableProperties, id: \.name) { property in
                    propertyRow(property)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func propertyRow(_ property: AvailableProperty) -> some View {
        let isIgnored = ignored.contains(property.name)
        // Don't let the user uncheck the last remaining property — the
        // server requires at least one property to differentiate the copy.
        let lockedOn = !isIgnored && (availableProperties.count - ignored.count) == 1

        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { !isIgnored },
                set: { include in
                    if include { ignored.remove(property.name) }
                    else { ignored.insert(property.name) }
                }
            )) {
                Text(verbatim: property.label)
            }
            .disabled(isUpdating || lockedOn)

            if !property.previews.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(property.previews.enumerated()), id: \.offset) { _, preview in
                        Text(verbatim: preview)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if property.extraCount > 0 {
                        Text("more \(property.extraCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(isIgnored ? 0.5 : 1)
            }
        }
    }

    // MARK: - Property catalog

    /// One property row in the duplicate-options list.
    private struct AvailableProperty {
        let name: String
        let label: String
        let ordinal: Double
        let previews: [String]   // up to 3 short previews
        let extraCount: Int      // values beyond the first 3
    }

    /// Properties the user can choose to include in the copy. Skips
    /// system / formula / file / sensitive properties — same filter
    /// as webapp's `availableProperties`.
    private var availableProperties: [AvailableProperty] {
        guard let entity else { return [] }
        let defByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })

        var rows: [AvailableProperty] = []
        for (name, values) in entity.properties {
            if name.hasPrefix("_") { continue }
            if values.isEmpty { continue }
            if name == "entu_api_key" || name == "entu_user" { continue }

            let def = defByName[name]
            if def?.formula != nil { continue }
            if def?.type == "file" { continue }

            let label = def?.label ?? name
            let ordinal = def?.ordinal ?? 0
            let previews = values.prefix(3).compactMap { previewString(for: $0) }
            let extra = max(values.count - 3, 0)
            rows.append(AvailableProperty(
                name: name,
                label: label,
                ordinal: ordinal,
                previews: previews,
                extraCount: extra
            ))
        }
        return rows.sorted { lhs, rhs in
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            return lhs.label.localizedCompare(rhs.label) == .orderedAscending
        }
    }

    /// Short text preview for a value chip — first non-nil typed field.
    private func previewString(for value: PropertyValue) -> String? {
        if let s = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        if let n = value.number { return "\(n)" }
        if let d = value.date { return d }
        if let dt = value.datetime { return dt }
        if let b = value.boolean { return b ? "✓" : "✗" }
        if let f = value.filename { return f }
        return nil
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let response: EntityDetailResponse = try await api.get("entity/\(entityId)")
            entity = response.entity
            if let typeId = entity?.typeId {
                definitions = await fetchDefinitions(typeId: typeId)
            }
            ignored = []
        } catch {
            loadError = String(localized: "networkError", bundle: .currentLocalized)
        }
        isLoading = false
    }

    /// Same definitions query as `EntityEditView` — uses just enough
    /// properties to filter formula / file / labels.
    private func fetchDefinitions(typeId: String) async -> [PropertyDefinition] {
        let params: [String: String] = [
            "_parent.reference": typeId,
            "props": "name,label,type,formula,ordinal"
        ]
        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }
        return response.entities.map { PropertyDefinition(from: $0) }
    }

    // MARK: - Mutation

    private func duplicate() async {
        guard count >= 1 else { return }
        isUpdating = true
        do {
            let _: [DuplicateResponseEntity] = try await api.post(
                "entity/\(entityId)/duplicate",
                body: DuplicateRequest(count: count, ignoredProperties: Array(ignored))
            )
            // Mark success first so the host's `onDismiss` knows to fire the
            // refresh callback, then dismiss — the parent reloads the
            // current entity (and its children list re-runs its own task
            // when the user navigates back into a list view).
            onDuplicated?()
            isUpdating = false
            dismiss()
        } catch {
            isUpdating = false
            commitError = error.localizedDescription
        }
    }
}

// MARK: - Wire types

private struct DuplicateRequest: Encodable {
    let count: Int
    let ignoredProperties: [String]
}

/// Server returns an array of `{ _id, properties: { ... } }` — we only
/// need to know the request succeeded, so a minimal decoder.
private struct DuplicateResponseEntity: Decodable {
    let _id: String?
}
