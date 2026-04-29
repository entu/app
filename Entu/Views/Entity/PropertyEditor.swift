// Type-aware property editor used inside `EntityEditView`.
//
// Each editor calls back to its parent's `onCommit` when the user is
// "done" with this row — TextField on focus loss, Toggle / DatePicker
// on value change, ReferencePicker on selection. The parent decides
// what API call to make (create-entity / add-value / edit-value /
// delete-value) — see `EntityEditView.commit`.
//
// Mirrors the read-side `PropertyRow.swift` dispatch by `definition.type`,
// but with mutable controls. File / counter / formula / readonly fields
// render disabled summaries — Phase 7 will add file uploads.

import SwiftUI

/// Mutable backing store for one editable property value.
@Observable
final class EditableValue: Identifiable {
    let id = UUID()

    /// Existing value's `_id` — present when editing, nil for newly added rows.
    var _id: String?

    /// Optional language tag for multilingual properties (`"en"` / `"et"`).
    var language: String?

    /// Type-specific mutable state. Only one is meaningful per definition.type.
    var stringValue: String = ""
    var numberValue: String = ""
    var boolValue: Bool = false
    var dateValue: Date?
    var referenceId: String?
    var referenceLabel: String?

    init(_id: String? = nil, language: String? = nil) {
        self._id = _id
        self.language = language
    }
}

/// Editor row for a single value of a property.
struct PropertyEditor: View {
    let definition: PropertyDefinition

    @Bindable var value: EditableValue

    /// Whether the row should render its own field label. Single-value
    /// properties typically pass `true`; list properties pass `false` for
    /// rows after the first so the section header carries the label.
    var showsLabel: Bool = true

    /// How many values the property currently holds — drives whether
    /// `displayLabel(valueCount:)` returns the singular or plural label.
    /// Mirrors webapp's `labelPlural` selection in `property/list.vue`.
    var valueCount: Int = 1

    /// Fires when the user finishes touching this row — TextField on
    /// focus loss, Toggle / DatePicker / Reference on value change.
    /// Parent triggers the autosave branch logic.
    var onCommit: () async -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var showingDescription = false

    /// Color used for the property label — red when the field is
    /// mandatory but empty (matches webapp's `text-red-700` rule).
    private var labelColor: Color {
        if definition.mandatory && isEmpty {
            return .red
        }
        return .primary
    }

    /// Mirror webapp's `<label>`-tap-activates-input behaviour across
    /// every editor type. Text-based editors take focus; click-driven
    /// editors fire the same action a tap on the value column would —
    /// toggle, open picker, set a date, generate a counter. The native
    /// SwiftUI `Picker` (for `set` properties) and `DatePicker` (when a
    /// date is already set) have no programmatic-open API, so for those
    /// the label tap falls through to focus, which is a harmless no-op.
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
            break  // tapping the label here would be too easy to misfire
        default:
            isFocused = true
        }
    }

    /// True when the row's editable state holds nothing meaningful —
    /// drives the mandatory red-label state.
    private var isEmpty: Bool {
        switch definition.type {
        case "boolean": return false  // toggle always has a state
        case "number": return value.numberValue.trimmingCharacters(in: .whitespaces).isEmpty
        case "date", "datetime": return value.dateValue == nil
        case "reference": return value.referenceId == nil
        case "file": return value.stringValue.isEmpty
        default: return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        // Manual two-column row — `LabeledContent` auto-collapses to
        // vertical (label-on-top-of-content) when content is wider
        // than the trailing column, which we don't want for long text
        // values. The HStack always lays out horizontally; tall
        // content types (`text`, `file`) align label `.topLeading` so
        // it sits at the first line; single-line controls use
        // `.firstTextBaseline` for natural vertical centring.
        let isTallContent = definition.type == "text" || definition.type == "file"
        let rowAlignment: VerticalAlignment = isTallContent ? .top : .center
        HStack(alignment: rowAlignment, spacing: 12) {
            Group {
                if showsLabel {
                    labelView
                } else {
                    Color.clear
                }
            }
            .frame(width: 160, alignment: isTallContent ? .topLeading : .leading)

            editor
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(definition.readonly || definition.formula != nil)
    }

    /// Property label — bold name (turns red when mandatory + empty,
    /// mirroring webapp's `text-red-700` rule), plus an info icon with
    /// a description popover when the property declares one. Capped at
    /// 30% of the row width via `containerRelativeFrame(count:span:)`;
    /// long names truncate with the system tail ellipsis.
    @ViewBuilder
    private var labelView: some View {
        HStack(spacing: 4) {
            Text(definition.displayLabel(valueCount: valueCount))
                .fontWeight(.bold)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // Webapp's `<label>` element behaviour — tapping the label
                // focuses the input. Only meaningful for text-based editors
                // (string / text / number); other types observe no
                // `@FocusState` so the assignment is a harmless no-op.
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
                    // Markdown-rendered description, matching webapp's
                    // `<my-markdown :source="property.description" />`.
                    // Width is capped at 360pt; height grows with the
                    // content via `fixedSize(vertical:)` so short notes
                    // get a small popover and long ones expand naturally.
                    Group {
                        if let attributed = try? AttributedString(markdown: description) {
                            Text(attributed)
                        } else {
                            Text(verbatim: description)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    /// The actual control without any label chrome around it.
    @ViewBuilder
    private var editor: some View {
        switch definition.type {
        case "boolean": booleanEditor
        case "number":  numberEditor
        case "text":    textEditor
        case "date":    dateEditor(showsTime: false)
        case "datetime": dateEditor(showsTime: true)
        case "reference": referenceEditor
        case "file":    fileSummary
        case "counter": counterEditor
        default:        stringEditor
        }
    }

    // MARK: - String / text

    /// Editors fill the `LabeledContent` content column and align text
    /// to the leading edge — `LabeledContent` keeps the column boundary
    /// consistent across rows, so every value's leading edge lines up
    /// vertically just inside the longest label's trailing edge.

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
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused { Task { await onCommit() } }
                }
                .onSubmit { Task { await onCommit() } }
        }
    }

    private var textEditor: some View {
        // `TextEditor` is SwiftUI's canonical multi-line text area —
        // free-form line breaks, scrollable, autogrows. `TextField` with
        // `axis: .vertical` is for short multiline fields (Mail compose
        // style); for properly textarea-like behaviour use TextEditor.
        //
        // `scrollContentBackground(.hidden)` hides `TextEditor`'s default
        // opaque white scroll-view backdrop on macOS so it inherits the
        // Form row background instead of looking like a stuck-on white
        // tile. iOS already inherits correctly; the modifier is a no-op
        // there.
        TextEditor(text: $value.stringValue)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 96)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused { Task { await onCommit() } }
            }
    }

    // MARK: - Number / boolean

    private var numberEditor: some View {
        TextField("", text: $value.numberValue)
            .multilineTextAlignment(.leading)
            #if os(iOS)
            .keyboardType(.decimalPad)
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

    /// Two-state editor — a `DatePicker` once a date is chosen, plus a
    /// trailing trash button to clear it; a tappable "Set date" row when
    /// the value is empty. SwiftUI's `DatePicker` only binds to non-nil
    /// `Date`, so we'd otherwise pre-fill the picker with `Date()` and
    /// the user couldn't commit "today" without first picking a different
    /// day. Clearing fires `onCommit` → empty value → `DELETE /property`.
    /// Two-state editor — leading-aligned in both states. SwiftUI's
    /// `DatePicker` only binds to a non-nil `Date`, so an empty value
    /// is rendered as a placeholder pill that the user taps to fill in
    /// `Date()`. Once set, the picker shows alongside an X button that
    /// clears back to nil. Default is **no date** (not today).
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

    /// `Button` + `.sheet` — `NavigationLink` inside a Form row
    /// makes the *whole* row tappable (including the label column);
    /// using a Button confines the tap area to the value column. The
    /// sheet is self-contained, so the picker's nav-bar Close is the
    /// only dismiss control (no duplicate back chevron).
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
                ReferencePickerView(query: definition.query) { id, label in
                    value.referenceId = id
                    value.referenceLabel = label
                    showingPicker = false
                    Task { await onCommit() }
                }
            }
        }
    }

    // MARK: - Read-only summaries

    /// Files are read-only in Phase 6 — the upload flow lands in Phase 7.
    /// Empty rows shouldn't reach here (seedValues / manageEmptyFields
    /// skip file properties without an existing value); when they do,
    /// render nothing rather than a "📄 label" placeholder.
    @ViewBuilder
    private var fileSummary: some View {
        if !value.stringValue.isEmpty {
            HStack {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(verbatim: value.stringValue)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Counter — read-only display of the current sequence value plus
    /// a "Generate" button that commits with `counter: 1` so the API
    /// resolves the next value server-side. Webapp's same flow:
    /// `properties.push({ ..., string: value, counter: 1 })`.
    private var counterEditor: some View {
        HStack(spacing: 12) {
            if !value.stringValue.isEmpty {
                Text(verbatim: value.stringValue)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
            Button {
                Task { await onCommit() }
            } label: {
                Label("counter", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
