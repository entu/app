// Type-aware editor row for one property value in the edit form — each
// control commits on blur / value change and the parent maps that to the
// right API call.

import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// Type-aware editor row for a single property value in `EntityEditView`.
/// Each control fires `onCommit` when the user finishes with it (blur for
/// text, value-change for toggles/pickers); the parent maps that to the
/// right API call — see `EntityEditView.commit`.
struct PropertyEditor: View {
    @Environment(APIClient.self) var api
    @Environment(\.locale) private var locale

    let definition: PropertyDefinition

    @Bindable var value: EditableValue

    /// List properties pass `false` for rows after the first so only the
    /// section header carries the label.
    var showsLabel: Bool = true

    /// Drives singular/plural label selection — mirrors webapp's
    /// `labelPlural` logic in `property/list.vue`.
    var valueCount: Int = 1

    /// Saved list-row values show a trailing × that fires `onDelete` —
    /// the flat ScrollView form has no swipe actions.
    var showsRowDelete: Bool = false

    /// True for the second and later rows of the same property — they sit
    /// tighter under the first (half the between-properties gap).
    var isContinuationRow: Bool = false

    /// Fires when the user finishes with this row; parent runs autosave.
    var onCommit: () async -> Void = {}

    /// Fires when this row's input gains focus — the parent scrolls the
    /// row into view so tabbing through a long form keeps the active
    /// field visible.
    var onFocused: () -> Void = {}

    /// Fires on every text edit (before commit) — list properties use it
    /// to grow their trailing empty row as soon as the user starts typing.
    var onValueEdited: () -> Void = {}

    /// File-property only — fires after the user picks one or more files.
    /// Parent appends rows / starts uploads. The editor itself never owns
    /// the picker dispatch logic.
    var onFilesPicked: ([PickedFile]) -> Void = { _ in }

    /// File-property only — fires when the trash button on a saved file
    /// is tapped. Parent runs the `DELETE /property/{id}` call.
    var onDelete: () async -> Void = {}

    /// When true, focus the input (text/number/text-area) on first appear.
    /// Used by `EntityEditView` to focus the first text field in the form,
    /// matching webapp's auto-focus-first-input behaviour. No-op for
    /// non-input editors (boolean, date, file, reference, picker, counter
    /// without `_id`) since focus has nothing to land on.
    var autoFocusOnAppear: Bool = false

    @FocusState private var isFocused: Bool
    @State private var showingDescription = false

    /// Local file URL the QuickLook preview displays. Populated lazily
    /// when the user taps a saved file row.
    @State var previewURL: URL?

    /// Drives the confirmation dialog presented when the user taps the
    /// trash button on a saved file row.
    @State var showingDeleteFileConfirm = false

    /// Red when mandatory + empty (mirrors webapp's `text-red-700`);
    /// otherwise the design's muted label tier.
    private var labelStyle: AnyShapeStyle {
        if definition.mandatory && isEmpty {
            return AnyShapeStyle(.red)
        }
        return AnyShapeStyle(.tertiary)
    }

    /// Webapp's `<label>`-tap-activates-input behaviour. Boolean / counter /
    /// file / reference rows ignore the tap — those would misfire on an
    /// accidental hit (reference rows open the picker only from the pill).
    private func activate() {
        switch definition.type {
        case "reference":
            break
        case "date", "datetime":
            if value.dateValue == nil {
                value.dateValue = Date()
                Task { await onCommit() }
            }
        case "boolean", "counter", "file":
            break
        default:
            isFocused = true
        }
    }

    /// Drives the mandatory red-label rule.
    private var isEmpty: Bool {
        switch definition.type {
        case "boolean": return false  // toggle always has a state
        case "number": return value.numberValue == nil
        case "date", "datetime": return value.dateValue == nil
        case "reference": return value.referenceId == nil
        case "file": return value.stringValue.isEmpty
        default: return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        rowBody
        // Tapping the gap between label and editor (or anywhere not on a
        // child control) routes through `activate()` — same behaviour as
        // tapping the label. Child controls (TextField, Toggle, Picker,
        // DatePicker) consume their own taps first, so this only fires
        // for the inert background area.
        .contentShape(Rectangle())
        .onTapGesture { activate() }
        .onChange(of: isFocused) { _, focused in
            if focused { onFocused() }
        }
        .onChange(of: value.stringValue) { onValueEdited() }
        .disabled(definition.readonly || definition.formula != nil)
        .task {
            // Slight delay so the sheet's present animation finishes before
            // the keyboard slides up — without it, iOS sometimes drops the
            // focus mid-animation and the field stays blurred.
            guard autoFocusOnAppear, supportsAutoFocus else { return }
            try? await Task.sleep(for: .milliseconds(300))
            isFocused = true
        }
    }

    /// Editor types whose underlying control accepts focus. Pickers,
    /// toggles, date pickers, file buttons, reference pickers and the
    /// "Generate" counter button have no focusable input to land on.
    private var supportsAutoFocus: Bool {
        switch definition.type {
        case "text", "number":
            return true
        case "string":
            // Set-backed string is a Picker (no text field to focus).
            return definition.set.isEmpty
        case "counter":
            // Generate button until the value exists; once saved it shows
            // a TextField — but auto-focus only runs on first appear, so
            // a freshly-saved counter row won't trip this anyway.
            return value._id != nil
        default:
            return false
        }
    }

    /// Shared row chrome (`LabeledRow`): right-aligned 140pt label column,
    /// editor in the middle, language pills / row × trailing. Tall types
    /// (`text`, `file`) anchor the label to the first line; single-line
    /// controls centre it. On iPhone the label stacks above the value.
    private var rowBody: some View {
        // Reference rows become tall while the inline picker is open — the
        // label must stay on the first line instead of centering against
        // the grown content.
        let isTallContent = definition.type == "text" || definition.type == "file"
            || (definition.type == "reference" && pickerActive)

        return LabeledRow(alignment: isTallContent ? .top : .center) {
            if showsLabel {
                labelView
            } else {
                Color.clear.frame(height: 1)
            }
        } content: {
            // Tighter gap between the value and its trailing accessories
            // (language pills / delete ×) than the label↔value gap.
            HStack(spacing: 8) {
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)

                if definition.multilingual {
                    languagePills
                }

                if showsRowDelete {
                    rowDeleteButton
                }
            }
        }
        .padding(.top, isContinuationRow ? 0 : 7)
        .padding(.bottom, 7)
    }

    /// Trailing × on saved list-row values.
    private var rowDeleteButton: some View {
        Button(role: .destructive) {
            Task { await onDelete() }
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

    /// Per-row EN/ET pills for multilingual properties — the active
    /// language as a raised capsule, per the design. Mirrors webapp's
    /// `<n-select v-if="isMultilingual">` in `property/edit.vue`. Changing
    /// the language fires `onCommit` — for saved rows that re-saves with
    /// the new tag; for empty unsaved rows the parent's `manageEmptyFields`
    /// rebalances per-language empty rows.
    private var languagePills: some View {
        HStack(spacing: 2) {
            ForEach(EntityEditView.multilingualLanguages, id: \.self) { lang in
                let isActive = (value.language ?? "en") == lang

                Button {
                    guard value.language != lang else { return }

                    value.language = lang
                    Task { await onCommit() }
                } label: {
                    Text(verbatim: lang.uppercased())
                        .font(.caption2.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if isActive {
                                Capsule()
                                    .fill(Color("CardBackground"))
                                    .overlay {
                                        Capsule().strokeBorder(Color("CardHairline"), lineWidth: 0.5)
                                    }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.fill.tertiary, in: Capsule())
    }

    /// Bold property label + info-icon popover when a description exists.
    /// Width is capped by the parent's 160pt label column.
    @ViewBuilder
    private var labelView: some View {
        HStack(spacing: 4) {
            Text(definition.displayLabel(valueCount: valueCount))
                .foregroundStyle(labelStyle)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.tail)
                // Webapp's `<label>`-tap-activates-input behaviour. The
                // `activate()` dispatch handles each editor type (text
                // focus, reference picker, date initial-set); see its
                // definition for the per-type rules.
                .contentShape(Rectangle())
                .onTapGesture { activate() }
            if let description = definition.description, !description.isEmpty {
                Button {
                    showingDescription.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingDescription) {
                    // Markdown popover capped at 360pt wide; height grows
                    // with content via `fixedSize(vertical:)`.
                    Text(markdown: description)
                    .textSelection(.enabled)
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    /// Dispatch the value control by `definition.type`.
    @ViewBuilder
    private var editor: some View {
        switch definition.type {
        case "boolean": booleanEditor
        case "number":  numberEditor
        case "text":    textEditor
        case "date":    dateEditor(showsTime: false)
        case "datetime": dateEditor(showsTime: true)
        case "reference": referenceEditor
        case "file":    fileEditor
        case "counter": counterEditor
        default:        stringEditor
        }
    }

    // MARK: - String / text

    @ViewBuilder
    private var stringEditor: some View {
        if !definition.set.isEmpty {
            HStack {
                Picker("", selection: $value.stringValue) {
                    Text(verbatim: "").tag("")
                    ForEach(definition.set.sorted(), id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: value.stringValue) { _, _ in
                    Task { await onCommit() }
                }

                Spacer(minLength: 0)
            }
        } else {
            TextField("", text: $value.stringValue)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused { Task { await onCommit() } }
                }
                .onSubmit { Task { await onCommit() } }
                .editFieldChrome()
        }
    }

    private var textEditor: some View {
        // `scrollContentBackground(.hidden)` hides TextEditor's white
        // scroll backdrop on macOS so the field chrome shows through;
        // no-op on iOS.
        TextEditor(text: $value.stringValue)
            // TextEditor doesn't inherit the row's text style — pin it to
            // body so it matches the single-line fields.
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused { Task { await onCommit() } }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Number / boolean

    /// Number field with locale-aware display and parsing. The format
    /// uses the in-app `\.locale` (so EN groups with `,` and `.`, ET with
    /// thin space and `,`) and pins fraction-length to the type
    /// definition's `decimals` when present. SwiftUI's `TextField(value:
    /// format:)` keeps the typed-text buffer separate from the bound
    /// `Double?`, so partial input ("12.", "-") doesn't fight the parser.
    private var numberEditor: some View {
        // `decimals` defaults to 0 when the type definition omits it.
        // Locale comes from the SwiftUI environment (in-app language /
        // system fallback) — SwiftUI's parser handles digit grouping and
        // decimal separator per that locale, so users type with their
        // own conventions ("," for ET, "." for EN).
        let decimals = definition.decimals ?? 0
        let format: FloatingPointFormatStyle<Double> = .number
            .precision(.fractionLength(decimals))
            .locale(locale)
        return HStack(spacing: 8) {
            TextField("", value: $value.numberValue, format: format)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                #if os(iOS)
                // Whole-number fields hide the `.`/`,` key so users can't enter
                // a decimal separator that the formatter would just strip.
                .keyboardType(decimals == 0 ? .numberPad : .decimalPad)
                #endif
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused { Task { await onCommit() } }
                }
                .onSubmit { Task { await onCommit() } }
                .editFieldChrome()
                .frame(width: 100)

            // −/+ next to the field, per the design. Commits when the
            // press interaction ends, not per step.
            Stepper("", value: Binding(
                get: { value.numberValue ?? 0 },
                set: { value.numberValue = $0 }
            ), step: 1) { editing in
                if !editing { Task { await onCommit() } }
            }
            .labelsHidden()

            Spacer(minLength: 0)
        }
    }

    private var booleanEditor: some View {
        Toggle("", isOn: $value.boolValue)
            .labelsHidden()
            .tint(.green)
            .onChange(of: value.boolValue) { _, _ in
                Task { await onCommit() }
            }
    }

    // MARK: - Date / datetime

    /// `DatePicker` only binds non-nil `Date`, so empty values render as a
    /// placeholder pill that fills in `Date()` on tap. Once set, an X button
    /// clears it back to nil → `DELETE /property` via the empty-value branch.
    @ViewBuilder
    private func dateEditor(showsTime: Bool) -> some View {
        if value.dateValue != nil {
            HStack(spacing: 8) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { value.dateValue ?? Date() },
                        set: { value.dateValue = $0 }
                    ),
                    displayedComponents: showsTime ? [.date, .hourAndMinute] : .date
                )
                .labelsHidden()
                .onChange(of: value.dateValue) { _, _ in
                    Task { await onCommit() }
                }

                Spacer(minLength: 0)

                Button {
                    value.dateValue = nil
                    Task { await onCommit() }
                } label: {
                    // Same × as the list rows' trailing delete.
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
                value.dateValue = Date()
                Task { await onCommit() }
            } label: {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "calendar")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Reference

    @State private var pickerActive = false

    /// Saved value → accent chip (tap to replace, × clears / deletes);
    /// empty → dashed "+ Add" chip. Either opens the inline reference
    /// picker in place, per the design.
    @ViewBuilder
    private var referenceEditor: some View {
        if pickerActive {
            InlineReferencePicker(
                query: definition.query,
                onSelect: { id, label in
                    value.referenceId = id
                    value.referenceLabel = label
                    Task { await onCommit() }
                },
                onDismiss: { pickerActive = false }
            )
        } else if let referenceId = value.referenceId {
            ReferenceChip(
                entityId: referenceId,
                name: value.referenceLabel,
                action: { pickerActive = true },
                onDelete: {
                    // Clearing a saved value routes through the commit's
                    // empty-value branch → DELETE /property/{id}.
                    value.referenceId = nil
                    value.referenceLabel = nil
                    Task { await onCommit() }
                }
            )
        } else {
            Button {
                pickerActive = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.medium))
                    Text("selectReference")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
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

    // MARK: - File state

    @State var showingFileImporter = false
    #if os(iOS)
    @State var photosPickerItems: [PhotosPickerItem] = []
    @State var showingPickerChoice = false
    #endif

    // MARK: - Counter

    /// New counter row (no `_id`) shows a Generate button — commit sends
    /// `counter: 1` and the server resolves the next sequence value.
    /// Saved rows (with `_id`) show an editable TextField so the user can
    /// override the generated value; blur commits the new string. Mirrors
    /// webapp's `property/edit.vue` two-state counter handling.
    @ViewBuilder
    private var counterEditor: some View {
        if value._id == nil {
            HStack(spacing: 12) {
                Button {
                    Task { await onCommit() }
                } label: {
                    Label("counter", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)
            }
        } else {
            TextField("", text: $value.stringValue)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused { Task { await onCommit() } }
                }
                .onSubmit { Task { await onCommit() } }
                .editFieldChrome()
        }
    }
}

/// The design's quiet filled input — plain field on a faint rounded fill.
private struct EditFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
}

extension View {
    func editFieldChrome() -> some View {
        modifier(EditFieldChrome())
    }
}
