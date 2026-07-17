// Advanced-search sheet. Mirrors webapp's `components/entity/search-modal.vue` —
// free-text search, entity-type multi-select, sort selection, and property
// filter rows with operators.
//
// Localization key deviations from the webapp (flat catalog vs
// component-scoped keys): webapp `title` → `searchTitle`; webapp `search`
// (submit button) → `searchAction` (`search` is the toolbar field prompt).
// HIG deviations: the type multi-select is chips + the inline reference
// picker instead of the design's segmented pills (real databases have too
// many types for a segment track); filter rows delete via a trailing ×;
// `fieldNamePlaceholderText` is shortened to "Property name" (webapp:
// "Input property name and field") to fit the single-line macOS filter row.

import SwiftUI

/// Advanced-search form sheet — builds a query and hands it to `onSearch`.
struct AdvancedSearchSheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Currently-applied query pairs (advanced or menu query), used to
    /// pre-populate the form — webapp's route-query watch equivalent.
    let currentQuery: [(String, String)]

    /// Current toolbar search text — seeds the `q` field.
    let currentText: String

    /// Called with the built query pairs when the user taps Search.
    let onSearch: ([(String, String)]) -> Void

    @State private var model: AdvancedSearchModel?

    /// True while the add-type chip is swapped for the inline picker.
    @State private var typesPickerActive = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SheetHeader(title: headerKicker, subtitle: headerTitle)
            #endif
            Group {
                if let model {
                    formBody(model)
                } else {
                    FormPlaceholder()
                }
            }
        }
        .sheetNavigationTitle(headerKicker, subtitle: headerTitle)
        .toolbar {
            // Reset stays apart from the primary Search action — mirrors
            // the webapp's footer-left placement. On iOS the trailing
            // corner would visually merge it into one capsule with Search,
            // so it sits leading, next to Close.
            #if os(macOS)
            ToolbarItem(placement: .destructiveAction) {
                Button("reset") { model?.reset() }
                    .disabled(model == nil)
            }
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { dismiss() }
            }
            #else
            // Same placement for both so declaration order holds —
            // cancellationAction and topBarLeading would sort Reset
            // before the Close.
            ToolbarItem(placement: .topBarLeading) {
                CloseButton { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("reset") { model?.reset() }
                    .disabled(model == nil)
            }
            #endif
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

    private var headerKicker: String {
        String(localized: "searchAction", bundle: .currentLocalized)
    }

    private var headerTitle: String {
        String(localized: "searchTitle", bundle: .currentLocalized)
    }

    // MARK: - Form

    private func formBody(_ model: AdvancedSearchModel) -> some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LabeledRow(labelWidth: Self.labelWidth) {
                    Text("searchQuery")
                } content: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        TextField("", text: $model.q, prompt: Text("searchQueryPlaceholder"))
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
                .padding(.vertical, 7)

                LabeledRow(labelWidth: Self.labelWidth, alignment: .top) {
                    Text("entityTypes")
                        .padding(.top, 4)
                } content: {
                    typesEditor(model)
                }
                .padding(.vertical, 7)

                LabeledRow(labelWidth: Self.labelWidth) {
                    Text("sortBy")
                } content: {
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
                .padding(.vertical, 7)

                // 37 + the previous row's 7pt padding = the canonical 44pt
                // section gap; 3 + row padding = the 10pt kicker→row.
                Text("propertyFilters")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 37)
                    .padding(.bottom, 3)

                ForEach($model.filters) { $filter in
                    // Capture the id up front — reading `filter.id` inside the
                    // removeAll predicate would read `model.filters` through
                    // the binding while removeAll holds exclusive access.
                    SearchFilterRow(filter: $filter, model: model) { [id = filter.id] in
                        model.filters.removeAll { $0.id == id }
                    }
                    .padding(.vertical, filterRowPadding)
                }

                addFilterChip(model)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color("WindowBackground"))
        .onChange(of: model.types) {
            Task { await model.loadProperties() }
        }
    }

    /// Selected types as accent chips with ×; the dashed add chip flows on
    /// the same line and swaps to the inline reference picker (one pick
    /// per open).
    private func typesEditor(_ model: AdvancedSearchModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(model.types, id: \.self) { name in
                    typeChip(name, model: model)
                }

                if !typesPickerActive {
                    Button {
                        typesPickerActive = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(Self.typePillIconFont)
                            Text("entityTypesPlaceholder")
                        }
                        .font(Self.typePillFont)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .frame(minHeight: Self.typePillHeight)
                        .overlay {
                            Capsule().strokeBorder(
                                .quaternary,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if typesPickerActive {
                InlineReferencePicker(
                    query: "_type.string=entity",
                    labelProperty: "label",
                    excludeNames: model.types,
                    onSelect: { _, name in
                        if !model.types.contains(name) {
                            model.types.append(name)
                        }
                    },
                    onDismiss: { typesPickerActive = false }
                )
            }
        }
    }

    /// One selected type as an accent chip with a remove ×.
    private func typeChip(_ name: String, model: AdvancedSearchModel) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: model.entityTypeOptions.first { $0.value == name }?.label ?? name)
                .lineLimit(1)

            Button {
                model.types.removeAll { $0 == name }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.6)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("removeValue")
        }
        .font(Self.typePillFont)
        .fontWeight(.medium)
        .foregroundStyle(.tint)
        .frame(height: ValueChipMetrics.contentHeight)
        .padding(2)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(minHeight: Self.typePillHeight)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
    }

    /// On touch platforms the type pills match the chromed value fields'
    /// height (22pt body line + 2 × 6pt `editFieldChrome` padding) so the
    /// row lines up with the inputs around it. macOS keeps the compact
    /// chips (nil = hug content).
    private static var typePillHeight: CGFloat? {
        #if os(iOS)
        34
        #else
        nil
        #endif
    }

    /// Pill text at the value inputs' body size on touch platforms; the
    /// compact chip font on macOS.
    private static var typePillFont: Font {
        #if os(iOS)
        .body
        #else
        ValueChipMetrics.font
        #endif
    }

    private static var typePillIconFont: Font {
        #if os(iOS)
        .footnote.weight(.medium)
        #else
        .caption2.weight(.medium)
        #endif
    }

    /// Label column width — the design's 11a uses a narrower column than
    /// the property sheets.
    private static let labelWidth: CGFloat = 110

    /// Vertical padding per filter row — matches the edit form's 7pt
    /// property-row padding (`PropertyEditor`); iPhone's stacked rows need
    /// more separation than the single-line rows on macOS/iPad.
    private var filterRowPadding: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 12 : 7
        #else
        7
        #endif
    }

    /// Dashed "+ Add filter" chip.
    private func addFilterChip(_ model: AdvancedSearchModel) -> some View {
        Button {
            model.addFilter()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.caption.weight(.medium))
                Text("addFilter")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .overlay {
                Capsule().strokeBorder(
                    .quaternary,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPhone stacks the controls; macOS and iPad keep one aligned line.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    fieldControl
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    removeButton
                }

                operatorPicker

                valueControl
            }
        } else {
            // One aligned line per filter — field / operator / value /
            // delete, same column order as the webapp's filter row. Field and
            // operator hug their content; only the value input stretches.
            HStack(spacing: 10) {
                fieldControl
                    .labelsHidden()
                    .fixedSize()

                operatorPicker
                    .labelsHidden()
                    .fixedSize()

                valueControl
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

                removeButton
            }
        }
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
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                #endif
                .editFieldChrome()
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
                #endif
                .editFieldChrome()
        } else if fieldType == .date {
            dateControl(showsTime: false)
        } else if fieldType == .datetime {
            dateControl(showsTime: true)
        } else {
            TextField("value", text: textBinding, prompt: Text("valuePlaceholder"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .editFieldChrome()
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
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
