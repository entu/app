// Type-aware editor row for `EntityEditView`. Each control fires
// `onCommit` when the user finishes with it (blur for text, value-change
// for toggles/pickers); the parent maps that to the right API call —
// see `EntityEditView.commit`.

import SwiftUI
import QuickLook
#if os(iOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

/// One file picked by the user, ready to be staged on an `EditableValue`
/// and pushed through the upload commit branch. `url` points to a file the
/// editor owns — typically a temp copy — so the upload can stream straight
/// from disk; the parent removes it after the PUT settles.
struct PickedFile {
    let filename: String
    let mimetype: String
    let url: URL
    let size: Int
}

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
    var numberValue: Double?
    var boolValue: Bool = false
    var dateValue: Date?
    var referenceId: String?
    var referenceLabel: String?

    /// File staged for upload. The picker writes the bytes to a temp file
    /// and stores its URL here so the upload can stream from disk via
    /// `URLSession.upload(for:fromFile:)` without loading the whole file
    /// into RAM (multi-GB-safe). Cleared after a successful PUT.
    var pendingFileURL: URL?
    var pendingFilename: String?
    var pendingFilesize: Int?
    var pendingFiletype: String?

    /// `filesize` on a saved file row — drives the byte-count label.
    var filesize: Int?

    /// Set during the metadata POST + S3 PUT so the editor can render
    /// a row spinner (indeterminate) or progress bar (determinate).
    var isUploading: Bool = false

    /// 0…1 fraction during the S3 PUT. Negative while metadata POST is
    /// in flight (no bytes-sent telemetry available yet).
    var uploadProgress: Double = -1

    init(_id: String? = nil, language: String? = nil) {
        self._id = _id
        self.language = language
    }
}

/// Editor row for a single value of a property.
struct PropertyEditor: View {
    @Environment(APIClient.self) private var api
    @Environment(\.locale) private var locale

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

    @FocusState private var isFocused: Bool
    @State private var showingDescription = false

    /// Local file URL the QuickLook preview displays. Populated lazily
    /// when the user taps a saved file row.
    @State private var previewURL: URL?

    /// Drives the confirmation dialog presented when the user taps the
    /// trash button on a saved file row.
    @State private var showingDeleteFileConfirm = false

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
        // Fixed-width label column — `LabeledContent` collapses to vertical
        // for long values, which we don't want. Tall types anchor the label
        // to the first line; single-line controls centre it.
        let isTallContent = definition.type == "text" || definition.type == "file"
        let rowAlignment: VerticalAlignment = isTallContent ? .top : .center
        HStack(alignment: rowAlignment, spacing: 12) {
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
        // Tapping the gap between label and editor (or anywhere not on a
        // child control) routes through `activate()` — same behaviour as
        // tapping the label. Child controls (TextField, Toggle, Picker,
        // DatePicker) consume their own taps first, so this only fires
        // for the inert background area.
        .contentShape(Rectangle())
        .onTapGesture { activate() }
        .disabled(definition.readonly || definition.formula != nil)
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
                ReferencePickerView(query: definition.query) { id, label in
                    value.referenceId = id
                    value.referenceLabel = label
                    showingPicker = false
                    Task { await onCommit() }
                }
            }
        }
    }

    // MARK: - File

    /// Saved → name + size + delete; uploading → progress bar + name + size;
    /// empty → upload button.
    @ViewBuilder
    private var fileEditor: some View {
        if value._id != nil {
            savedFileRow
        } else if value.isUploading {
            uploadingFileRow
        } else {
            uploadButton
        }
    }

    @ViewBuilder
    private var savedFileRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await downloadAndPreview() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    Text(verbatim: value.stringValue)
                        .foregroundStyle(.tint)
                    if let size = value.filesize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                showingDeleteFileConfirm = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("removeValue")
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            Text("removeFileConfirmTitle \(value.stringValue)"),
            isPresented: $showingDeleteFileConfirm,
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                Task { await onDelete() }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    /// Fetch the signed URL via `APIClient.downloadFileForPreview` and
    /// hand the temp file to QuickLook.
    private func downloadAndPreview() async {
        guard let propId = value._id else { return }
        let filename = value.stringValue.isEmpty ? nil : value.stringValue
        previewURL = await api.downloadFileForPreview(propertyId: propId, filename: filename)
    }

    @ViewBuilder
    private var uploadingFileRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: value.pendingFilename ?? "")
                    .foregroundStyle(.secondary)
                if value.uploadProgress >= 0 {
                    ProgressView(value: value.uploadProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            if let size = value.pendingFilesize {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @State private var showingFileImporter = false
    #if os(iOS)
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showingPickerChoice = false
    #endif

    private var uploadButton: some View {
        uploadButtonContent
            .dropDestination(for: URL.self) { urls, _ in
                let accepted = definition.list ? urls : Array(urls.prefix(1))
                let picks = accepted.compactMap { stageFile(at: $0) }
                guard !picks.isEmpty else { return false }
                onFilesPicked(picks)
                return true
            }
    }

    @ViewBuilder
    private var uploadButtonContent: some View {
        #if os(iOS)
        // iOS — choice between Photos and Files. Multi-select when list.
        Menu {
            Button {
                photosPickerItems = []
                showingPickerChoice = true
            } label: {
                Label("chooseFromPhotos", systemImage: "photo")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("chooseFromFiles", systemImage: "folder")
            }
        } label: {
            Label(definition.list ? "uploadFiles" : "uploadFile", systemImage: "arrow.up.circle")
        }
        .photosPicker(
            isPresented: $showingPickerChoice,
            selection: $photosPickerItems,
            maxSelectionCount: definition.list ? 0 : 1,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photosPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotosPickerItems(items) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: definition.list
        ) { result in
            handleFileImporter(result)
        }
        #else
        // macOS — only fileImporter; Photos picker isn't available here.
        Button {
            showingFileImporter = true
        } label: {
            Label(definition.list ? "uploadFiles" : "uploadFile", systemImage: "arrow.up.circle")
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: definition.list
        ) { result in
            handleFileImporter(result)
        }
        #endif
    }

    /// Copy each picked URL into the app's temp dir so it survives the
    /// security-scoped lifetime + lets the upload stream from disk.
    private func handleFileImporter(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let picks = urls.compactMap { stageFile(at: $0) }
        if !picks.isEmpty { onFilesPicked(picks) }
    }

    /// Copy a security-scoped picker URL into temp and return a `PickedFile`.
    private func stageFile(at source: URL) -> PickedFile? {
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return PickedFile(
            filename: source.lastPathComponent,
            mimetype: source.mimeType(),
            url: dest,
            size: size
        )
    }

    #if os(iOS)
    /// Stream PhotosPicker items to temp files (we can't ask Photos for a
    /// URL, but `loadTransferable` can read in chunks via Data — write each
    /// chunk straight out so we don't keep the whole file in RAM).
    private func loadPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        var picks: [PickedFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "dat"
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let filename = "photo-\(Int(Date().timeIntervalSince1970))-\(index + 1).\(ext)"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try data.write(to: dest)
            } catch { continue }
            picks.append(PickedFile(filename: filename, mimetype: mime, url: dest, size: data.count))
        }
        photosPickerItems = []
        if !picks.isEmpty { onFilesPicked(picks) }
    }
    #endif

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

private extension URL {
    /// MIME type from the URL's path extension via `UTType`. Falls back
    /// to `application/octet-stream` when the extension is unknown.
    func mimeType() -> String {
        guard let type = UTType(filenameExtension: pathExtension),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}

