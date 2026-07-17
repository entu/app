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

    /// Raw text of the count field — lets an emptied field fall back to 1
    /// on focus loss instead of silently keeping the previous value.
    @State private var countText = "1"
    @FocusState private var countFocused: Bool
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
            SheetHeader(title: headerTitle, subtitle: headerSubtitle)
            #endif
            Group {
                if isLoading {
                    FormPlaceholder()
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                } else {
                    formBody
                }
            }
        }
        .sheetNavigationTitle(headerTitle, subtitle: headerSubtitle)
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

    private var headerTitle: String {
        String(localized: "duplicate", bundle: .currentLocalized)
    }

    /// Subtitle: the entity's name, nil when it has none.
    private var headerSubtitle: String? {
        let name = PropertyValue.localized(entity?.properties["name"])
        return (name?.isEmpty == false) ? name : nil
    }

    private var submitTitle: LocalizedStringKey {
        count == 1 ? "createDuplicate" : "createDuplicates \(count)"
    }

    // MARK: - Form

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Count row — label column + editable count + native stepper.
                LabeledRow {
                    Text("numberOfCopies")
                } content: {
                    countEditor
                }
                .padding(.vertical, 7)
                .disabled(isUpdating)

                // 37 + the count row's 7pt padding = the canonical 44pt
                // section gap; 3 + 7 = the 10pt kicker→row.
                Text("propertiesToInclude")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 37)
                    .padding(.bottom, 3)

                ForEach(Array(availableProperties.enumerated()), id: \.element.name) { index, property in
                    propertyRow(property)

                    if index < availableProperties.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color("WindowBackground"))
    }

    /// Editable count + native stepper.
    private var countEditor: some View {
        HStack(spacing: 8) {
            TextField("", text: $countText)
                .textFieldStyle(.plain)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .focused($countFocused)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .frame(width: 48)
                .padding(.vertical, 5)
                .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
                }
                .onChange(of: countText) {
                    // Digits only; valid input updates the count live.
                    let digits = countText.filter(\.isNumber)
                    if digits != countText { countText = digits }
                    if let value = Int(digits), value >= 1 {
                        count = min(value, Self.maxCount)
                        if count != value { countText = "\(count)" }
                    }
                }
                .onChange(of: countFocused) {
                    // Leaving the field empty (or invalid) means 1.
                    guard !countFocused else { return }
                    if (Int(countText) ?? 0) < 1 { count = 1 }
                    countText = "\(count)"
                }

            Stepper("", value: $count, in: 1...Self.maxCount)
                .labelsHidden()
                .onChange(of: count) { countText = "\(count)" }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func propertyRow(_ property: AvailableProperty) -> some View {
        let isIgnored = ignored.contains(property.name)
        // Don't let the user uncheck the last remaining property — the
        // server requires at least one property to differentiate the copy.
        let lockedOn = !isIgnored && (availableProperties.count - ignored.count) == 1

        LabeledRow {
            Text(verbatim: property.label)
        } content: {
            HStack(alignment: .center, spacing: 16) {
                // Value preview — reference values as accent chips, others
                // as plain text, per the design.
                Group {
                    if property.isReference {
                        FlowLayout(spacing: 5) {
                            ForEach(Array(property.previews.enumerated()), id: \.offset) { _, preview in
                                Text(verbatim: preview)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }

                            if property.extraCount > 0 {
                                Text("more \(property.extraCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(verbatim: property.previews.joined(separator: " · ")
                            + (property.extraCount > 0 ? " …" : ""))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                propertyToggle(property, isIgnored: isIgnored, lockedOn: lockedOn)
            }
        }
        .padding(.vertical, 7)
        // Off rows dim, toggle included (still tappable).
        .opacity(isIgnored ? 0.45 : 1)
    }

    private func propertyToggle(_ property: AvailableProperty, isIgnored: Bool, lockedOn: Bool) -> some View {
        Toggle("", isOn: Binding(
                get: { !isIgnored },
                set: { include in
                    if include { ignored.remove(property.name) }
                    else { ignored.insert(property.name) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
            .controlSize(.small)
            .disabled(isUpdating || lockedOn)
            .accessibilityLabel(Text(verbatim: property.label))
    }

    // MARK: - Property catalog

    /// One property row in the duplicate-options list.
    private struct AvailableProperty {
        let name: String
        let label: String
        let ordinal: Double
        let previews: [String]   // up to 3 short previews
        let extraCount: Int      // values beyond the first 3
        let isReference: Bool    // reference previews render as accent chips
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
                extraCount: extra,
                isReference: def?.type == "reference"
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
