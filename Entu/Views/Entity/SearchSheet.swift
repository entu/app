// Advanced-search sheet. Mirrors webapp's `components/entity/search-modal.vue` —
// free-text search, entity-type multi-select, sort selection, and property
// filter rows with operators.
//
// Localization key deviations from the webapp (flat catalog vs
// component-scoped keys): webapp `title` → `searchTitle`; webapp `search`
// (submit button) → `searchAction` (`search` is the toolbar field prompt).
// HIG deviations: the type multi-select reuses `ReferencePickerView` in
// multi-select mode (nested sheet) instead of an inline tag select; filter
// rows delete via a trailing trash button; `fieldNamePlaceholderText` is
// shortened to "Property name" (webapp: "Input property name and field")
// to fit the single-line macOS filter row.

import SwiftUI

/// Advanced-search form sheet — builds a query and hands it to `onSearch`.
struct SearchSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    /// Currently-applied query pairs (advanced or menu query), used to
    /// pre-populate the form — webapp's route-query watch equivalent.
    let currentQuery: [(String, String)]

    /// Current toolbar search text — seeds the `q` field.
    let currentText: String

    /// Called with the built query pairs when the user taps Search.
    let onSearch: ([(String, String)]) -> Void

    @State private var model: AdvancedSearchModel?
    @State private var showTypesPicker = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            sheetHeader
            #endif
            Group {
                if let model {
                    formBody(model)
                } else {
                    FormPlaceholder()
                }
            }
        }
        #if os(iOS)
        .navigationTitle(Text("searchTitle"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            // Reset bottom-left — mirrors the webapp's footer-left placement.
            ToolbarItem(placement: .destructiveAction) {
                Button("reset") { model?.reset() }
                    .disabled(model == nil)
            }
            #endif
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if let model { onSearch(model.buildQuery()) }
                    dismiss()
                } label: {
                    Text("searchAction")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model == nil)
            }
        }
        .task {
            let formModel = AdvancedSearchModel(
                api: api,
                currentQuery: currentQuery,
                currentText: currentText
            )
            model = formModel
            async let typesLoad: Void = formModel.loadEntityTypes()
            async let propertiesLoad: Void = formModel.loadProperties()
            _ = await (typesLoad, propertiesLoad)
        }
        .appLanguageScoped()
    }

    #if os(macOS)
    /// In-content title bar for macOS sheets. See EntityEditView.swift —
    /// macOS sheets don't render the toolbar's principal slot.
    private var sheetHeader: some View {
        Text("searchTitle")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
    #endif

    // MARK: - Form

    private func formBody(_ model: AdvancedSearchModel) -> some View {
        @Bindable var model = model

        return Form {
            Section {
                TextField("searchQuery", text: $model.q, prompt: Text("searchQueryPlaceholder"))

                Button {
                    showTypesPicker = true
                } label: {
                    LabeledContent("entityTypes") {
                        HStack(spacing: 6) {
                            Text(verbatim: selectedTypesLabel(model))
                                .lineLimit(1)
                                .foregroundStyle(model.types.isEmpty ? .secondary : .primary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                LabeledContent("sortBy") {
                    HStack(spacing: 8) {
                        Picker("sortBy", selection: $model.sortField) {
                            ForEach(AdvancedSearchModel.sortOptions, id: \.value) { option in
                                Text(LocalizedStringKey(option.labelKey)).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        Picker("sortBy", selection: $model.sortDirection) {
                            Image(systemName: "arrow.down")
                                .accessibilityLabel("ascending")
                                .tag("")
                            Image(systemName: "arrow.up")
                                .accessibilityLabel("descending")
                                .tag("-")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Section("propertyFilters") {
                ForEach($model.filters) { $filter in
                    // Capture the id up front — reading `filter.id` inside the
                    // removeAll predicate would read `model.filters` through
                    // the binding while removeAll holds exclusive access.
                    SearchFilterRow(filter: $filter, model: model) { [id = filter.id] in
                        model.filters.removeAll { $0.id == id }
                    }
                }

                Button {
                    model.addFilter()
                } label: {
                    Label("addFilter", systemImage: "plus")
                }
            }

            #if os(iOS)
            Section {
                Button("reset") { model.reset() }
            }
            #endif
        }
        .formStyle(.grouped)
        .onChange(of: model.types) {
            Task { await model.loadProperties() }
        }
        .sheet(isPresented: $showTypesPicker) {
            NavigationStack {
                ReferencePickerView(
                    query: "_type.string=entity",
                    titleKey: "entityTypes",
                    labelProperty: "label",
                    showsTypeBadge: false,
                    multiSelect: true,
                    isSelected: { _, name in model.types.contains(name) },
                    onSelect: { _, name in
                        if let index = model.types.firstIndex(of: name) {
                            model.types.remove(at: index)
                        } else {
                            model.types.append(name)
                        }
                    }
                )
            }
        }
    }

    /// Joined labels of the selected types, or the placeholder.
    private func selectedTypesLabel(_ model: AdvancedSearchModel) -> String {
        if model.types.isEmpty {
            return String(localized: "entityTypesPlaceholder", bundle: .currentLocalized)
        }

        return model.types
            .map { value in model.entityTypeOptions.first { $0.value == value }?.label ?? value }
            .joined(separator: ", ")
    }
}

// MARK: - Filter row

/// One property-filter row: field, operator, and a value input whose control
/// switches on the detected field type — same logic as the webapp template.
private struct SearchFilterRow: View {
    @Binding var filter: SearchFilter
    let model: AdvancedSearchModel
    let onRemove: () -> Void

    private var fieldType: SearchFieldType {
        AdvancedSearchModel.fieldType(of: filter.field)
    }

    var body: some View {
        #if os(macOS)
        // One aligned line per filter — field / operator / value / delete,
        // same column order as the webapp's filter row.
        HStack(spacing: 10) {
            fieldControl
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

            operatorPicker
                .labelsHidden()
                .fixedSize()

            valueControl
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

            removeButton
        }
        #else
        VStack(spacing: 8) {
            HStack {
                fieldControl
                Spacer(minLength: 8)
                removeButton
            }

            operatorPicker

            valueControl
        }
        #endif
    }

    private var operatorPicker: some View {
        Picker("operator", selection: operatorBinding) {
            ForEach(AdvancedSearchModel.operatorOptions(for: filter.field), id: \.value) { option in
                Text(LocalizedStringKey(option.labelKey)).tag(option.value)
            }
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("delete")
    }

    /// Webapp field watch — reset the value when the detected type changes.
    private var fieldBinding: Binding<String> {
        Binding(
            get: { filter.field },
            set: { newField in
                let oldField = filter.field
                filter.field = newField
                if !oldField.isEmpty, !newField.isEmpty,
                   AdvancedSearchModel.fieldType(of: oldField) != AdvancedSearchModel.fieldType(of: newField) {
                    filter.value = .none
                }
            }
        )
    }

    /// Webapp operator watch — newly-selected "exists" defaults to true.
    private var operatorBinding: Binding<String> {
        Binding(
            get: { filter.op },
            set: { newOp in
                let oldOp = filter.op
                filter.op = newOp
                if oldOp != newOp, newOp == "exists" {
                    filter.value = .bool(true)
                }
            }
        )
    }

    /// Free-text field input when no types are selected (any property name
    /// can be searched), picker over loaded properties otherwise.
    @ViewBuilder
    private var fieldControl: some View {
        if model.types.isEmpty {
            TextField("fieldName", text: fieldBinding, prompt: Text("fieldNamePlaceholderText"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #else
                .textFieldStyle(.roundedBorder)
                #endif
        } else if model.isLoadingProperties {
            ProgressView()
        } else {
            Picker("fieldName", selection: fieldBinding) {
                Text("fieldNamePlaceholder").tag("")
                if !filter.field.isEmpty,
                   !model.propertyOptions.contains(where: { $0.value == filter.field }) {
                    Text(verbatim: filter.field).tag(filter.field)
                }
                ForEach(model.propertyOptions) { option in
                    Text(verbatim: option.label).tag(option.value)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var valueControl: some View {
        if filter.op == "exists" || fieldType == .boolean {
            Toggle("value", isOn: boolBinding)
        } else if fieldType == .number || fieldType == .filesize {
            TextField("value", value: numberBinding, format: .number, prompt: Text("valuePlaceholder"))
                #if os(iOS)
                .keyboardType(.decimalPad)
                #else
                .textFieldStyle(.roundedBorder)
                #endif
        } else if fieldType == .date {
            dateControl(showsTime: false)
        } else if fieldType == .datetime {
            dateControl(showsTime: true)
        } else {
            TextField("value", text: textBinding, prompt: Text("valuePlaceholder"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #else
                .textFieldStyle(.roundedBorder)
                #endif
        }
    }

    /// `DatePicker` only binds non-nil `Date`, so empty values render as a
    /// placeholder button that fills in `Date()` on tap. Once set, an X
    /// button clears back to nil → the filter is skipped (same as the
    /// webapp's clearable date picker). Pattern from PropertyEditor.swift.
    @ViewBuilder
    private func dateControl(showsTime: Bool) -> some View {
        if dateValue != nil {
            HStack(spacing: 8) {
                DatePicker(
                    "value",
                    selection: Binding(
                        get: { dateValue ?? Date() },
                        set: { filter.value = .date($0) }
                    ),
                    displayedComponents: showsTime ? [.date, .hourAndMinute] : .date
                )
                .labelsHidden()

                Spacer(minLength: 0)

                Button {
                    filter.value = .date(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("removeValue")
            }
        } else {
            Button {
                filter.value = .date(Date())
            } label: {
                Label("valuePlaceholder", systemImage: "calendar")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Typed value bindings

    private var dateValue: Date? {
        if case .date(let date) = filter.value { return date }
        return nil
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                if case .bool(let bool) = filter.value { return bool }
                return false
            },
            set: { filter.value = .bool($0) }
        )
    }

    private var numberBinding: Binding<Double?> {
        Binding(
            get: {
                if case .number(let number) = filter.value { return number }
                return nil
            },
            set: { filter.value = .number($0) }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if case .text(let text) = filter.value { return text }
                return ""
            },
            set: { filter.value = .text($0) }
        )
    }
}
