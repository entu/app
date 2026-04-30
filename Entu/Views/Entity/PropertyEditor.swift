// Type-aware editor row for `EntityEditView`. Each control fires
// `onCommit` when the user finishes with it (blur for text, value-change
// for toggles/pickers); the parent maps that to the right API call —
// see `EntityEditView.commit`. Files render read-only until Phase 7.

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

    /// List properties pass `false` for rows after the first so only the
    /// section header carries the label.
    var showsLabel: Bool = true

    /// Drives singular/plural label selection — mirrors webapp's
    /// `labelPlural` logic in `property/list.vue`.
    var valueCount: Int = 1

    /// Fires when the user finishes with this row; parent runs autosave.
    var onCommit: () async -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var showingDescription = false

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
        case "number": return value.numberValue.trimmingCharacters(in: .whitespaces).isEmpty
        case "date", "datetime": return value.dateValue == nil
        case "reference": return value.referenceId == nil
        case "file": return value.stringValue.isEmpty
        default: return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        // Fixed-width label column — `LabeledContent` collapses to vertical
        // for long values, which we don't want. Tall types anchor the label
        // to the first line; single-line controls centre it.
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
        case "file":    fileSummary
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

    private var numberEditor: some View {
        TextField("", text: $value.numberValue)
            .multilineTextAlignment(.leading)
            .labelsHidden()
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

    /// Read-only until Phase 7 ships uploads. Empty rows render nothing
    /// (seedValues skips file properties without an existing value).
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

    /// Current sequence value (read-only) + Generate button. The commit
    /// sends `counter: 1` so the API resolves the next value server-side.
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
