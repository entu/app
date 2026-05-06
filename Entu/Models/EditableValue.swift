// Mutable backing store for one row of `EntityEditView`'s in-progress
// edits. One instance per property value the user is touching — text in
// progress, a Date the user just picked, a reference they selected, file
// bytes staged for upload. The view binds to fields here; commit logic
// reads them and ships the right shape to the API.

import Foundation

/// One in-progress editable value. The active subset of fields depends
/// on the property's `definition.type` — the rest stay at their default.
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
