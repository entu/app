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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let definition: PropertyDefinition

    @Bindable var value: EditableValue

    /// List properties pass `false` for rows after the first so only the
    /// section header carries the label.
    var showsLabel: Bool = true

    /// Drives singular/plural label selection — mirrors webapp's
    /// `labelPlural` logic in `property/list.vue`.
    var valueCount: Int = 1

    /// Fires when the user finishes with this row; parent runs autosave.
    var onCommit: () async -> Void = {}

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

    /// Red when mandatory + empty (mirrors webapp's `text-red-700`).
    private var labelColor: Color {
        if definition.mandatory && isEmpty {
            return .red
        }
        return .primary
    }

    /// Webapp's `<label>`-tap-activates-input behaviour. Boolean / counter /
    /// file rows ignore the tap — those would misfire on an accidental hit.
    private func activate() {
        switch definition.type {
        case "reference":
            showingPicker = true
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
        Group {
            if isCompact {
                compactBody
            } else {
                wideBody
            }
        }
        // Tapping the gap between label and editor (or anywhere not on a
        // child control) routes through `activate()` — same behaviour as
        // tapping the label. Child controls (TextField, Toggle, Picker,
        // DatePicker) consume their own taps first, so this only fires
        // for the inert background area.
        .contentShape(Rectangle())
        .onTapGesture { activate() }
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

    /// True on iPhone (compact horizontal size class) — narrow rows can't
    /// fit a 160pt label column + value column without clipping. Also true
    /// at accessibility Dynamic Type sizes on every platform: the fixed
    /// label column would clip the scaled-up label, so the row stacks.
    private var isCompact: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }

        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// Wide layout (iPad / macOS / regular size class) — fixed-width label
    /// column on the left, editor on the right. Tall types (`text`, `file`)
    /// anchor the label to the first line; single-line controls centre it.
    private var wideBody: some View {
        let isTallContent = definition.type == "text" || definition.type == "file"
        let rowAlignment: VerticalAlignment = isTallContent ? .top : .center
        return HStack(alignment: rowAlignment, spacing: 12) {
            // 160pt left column. For multilingual rows the language picker
            // shares this column with the label so the value column starts
            // at the same leading edge across all rows in the form.
            HStack(spacing: 8) {
                Group {
                    if showsLabel {
                        labelView
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: isTallContent ? .topLeading : .leading)

                if definition.multilingual {
                    languagePicker
                }
            }
            .frame(width: 160, alignment: isTallContent ? .topLeading : .leading)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Compact layout (iPhone) — label on top, editor below, full row width.
    /// Multilingual language picker sits next to the label; for hidden-label
    /// rows in a list, the picker still shows (so EN/ET stays user-changeable).
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel || definition.multilingual {
                HStack(spacing: 8) {
                    if showsLabel { labelView }
                    if definition.multilingual { languagePicker }
                }
            }
            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Per-row EN/ET selector for multilingual properties. Mirrors webapp's
    /// `<n-select v-if="isMultilingual">` in `property/edit.vue`. Changing
    /// the language fires `onCommit` — for saved rows that re-saves with
    /// the new tag; for empty unsaved rows the parent's `manageEmptyFields`
    /// rebalances per-language empty rows.
    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { value.language ?? "en" },
            set: { newLang in
                guard newLang != value.language else { return }
                value.language = newLang
                Task { await onCommit() }
            }
        )) {
            Text(verbatim: "EN").tag("en")
            Text(verbatim: "ET").tag("et")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 60)
    }

    /// Bold property label + info-icon popover when a description exists.
    /// Width is capped by the parent's 160pt label column.
    @ViewBuilder
    private var labelView: some View {
        HStack(spacing: 4) {
            Text(definition.displayLabel(valueCount: valueCount))
                .fontWeight(.bold)
                .foregroundStyle(labelColor)
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
                Spacer(minLength: 0)
                Picker("", selection: $value.stringValue) {
                    Text(verbatim: "").tag("")
                    ForEach(definition.set.sorted(), id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .labelsHidden()
                .onChange(of: value.stringValue) { _, _ in
                    Task { await onCommit() }
                }
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
        }
    }

    private var textEditor: some View {
        // `scrollContentBackground(.hidden)` hides TextEditor's white
        // scroll backdrop on macOS so the Form row colour shows through;
        // no-op on iOS.
        TextEditor(text: $value.stringValue)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused { Task { await onCommit() } }
            }
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
        return TextField("", value: $value.numberValue, format: format)
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
    }

    private var booleanEditor: some View {
        Toggle("", isOn: $value.boolValue)
            .labelsHidden()
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
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
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

    @State private var showingPicker = false

    /// `Button` + `.sheet` — `NavigationLink` would make the whole row
    /// (including the label column) the tap target; the button confines
    /// it to the value column.
    private var referenceEditor: some View {
        Button {
            showingPicker = true
        } label: {
            HStack {
                if let label = value.referenceLabel ?? value.referenceId {
                    Text(verbatim: label)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                ReferencePickerView(query: definition.query, subtitle: definition.label ?? definition.name) { id, label in
                    value.referenceId = id
                    value.referenceLabel = label
                    showingPicker = false
                    Task { await onCommit() }
                }
            }
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
                Spacer(minLength: 0)
                Button {
                    Task { await onCommit() }
                } label: {
                    Label("counter", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
        }
    }
}
