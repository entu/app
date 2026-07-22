// Per-value commit, file upload, delete, and trailing-empty housekeeping
// for `EntityEditView`. Split out of `EntityEditView.swift` so the main
// file stays focused on rendering. Mirrors the webapp's autosave model
// (`components/property/edit.vue::updateValue`) — a single commit chain
// fans out to create/add/edit/delete based on entity + value state.

import AuthenticationServices
import Foundation
import SwiftUI

extension EntityEditView {
    // MARK: - Per-value commit (autosave)

    /// Commit a single value. Mirrors `property/edit.vue::updateValue`.
    /// Serialised via `commitChain` so concurrent blurs run sequentially —
    /// otherwise two editors could each see `currentEntityId == nil` and
    /// each fire `createEntity`, producing two entities.
    func commit(propertyName: String, value: EditableValue) async {
        let prior = commitChain
        let task = Task { @MainActor in
            _ = await prior?.value
            await runCommit(propertyName: propertyName, value: value)
        }
        commitChain = task
        _ = await task.value
    }

    /// Actual commit logic — only ever runs one at a time thanks to the
    /// serialising `commit` wrapper.
    private func runCommit(propertyName: String, value: EditableValue) async {
        guard let def = definitions.first(where: { $0.name == propertyName }) else { return }
        if def.readonly || def.formula != nil { return }

        // Files take a separate path: POST metadata, decode upload intent,
        // PUT the bytes to S3. Skip the empty/equality short-circuits.
        if def.type == "file" && value.pendingFileURL != nil {
            await runFileUpload(propertyName: propertyName, value: value)
            manageEmptyFields(for: def)
            return
        }

        let isEmpty = isEditableValueEmpty(value, definition: def)

        // Empty unsaved row: nothing to send, but rebalance trailing empties
        // so a language flip on a multilingual empty row redraws correctly.
        if isEmpty && value._id == nil {
            manageEmptyFields(for: def)
            return
        }

        // No-op when an existing value was edited but didn't actually change.
        if let _id = value._id,
           let existing = entity?.properties[propertyName]?.first(where: { $0._id == _id }),
           valueMatchesExisting(value, existing: existing, type: def.type),
           value.language == existing.language {
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            if currentEntityId == nil && !isEmpty && value._id == nil {
                try await createEntity(propertyName: propertyName, value: value, definition: def)
            } else if let entityId = currentEntityId, !isEmpty, value._id == nil {
                try await addValue(entityId: entityId, propertyName: propertyName, value: value, definition: def)
            } else if let entityId = currentEntityId, !isEmpty, value._id != nil {
                try await editValue(entityId: entityId, propertyName: propertyName, value: value, definition: def)
            } else if isEmpty, let _id = value._id {
                let _: DeleteResponse = try await api.delete("property/\(_id)")
                value._id = nil
                removeFromLocalEntity(propertyName: propertyName, propertyId: _id)
                if var rows = values[propertyName] {
                    rows.removeAll { $0.id == value.id && $0._id == nil }
                    values[propertyName] = rows
                }
            }
            hasSavedChanges = true

            // Self-invite on the user's own entity: the response carried a
            // raw invite JWT (set by `applyUpsertResponse`) — present the
            // provider sheet that attaches the new login method. Mirrors
            // webapp's redirect to `/{account}/invite?token=…`. Masked
            // `***` invites from GET never pass through this path.
            if def.name == "entu_user", isOwnEntity, let token = value.invite, token != "***" {
                pendingSelfInvite = PendingSelfInvite(token: token)
            }
        } catch {
            commitError = error.localizedDescription
        }

        manageEmptyFields(for: def)
    }

    // MARK: - Passkey registration

    /// Run the native WebAuthn registration flow for an empty
    /// `entu_passkey` row and apply the stored property to it. Only
    /// reachable on the user's own entity (the editor gates the button).
    func registerPasskey(propertyName: String, value: EditableValue) async {
        isSaving = true
        defer { isSaving = false }

        do {
            guard let property = try await passkeyService.register(),
                  let serverId = property._id else { return }

            value._id = serverId
            value.stringValue = property.string ?? ""
            hasSavedChanges = true

            if let def = definitions.first(where: { $0.name == propertyName }) {
                manageEmptyFields(for: def)
            }
        } catch let authError as ASAuthorizationError where authError.code == .canceled {
            // User dismissed the passkey sheet — not an error
        } catch {
            commitError = error.localizedDescription
        }
    }

    /// Create the entity from the very first committed value. Sends the
    /// property + the synthesised `_parent` (when present) and `_type`
    /// references in one request, matching webapp's `addEntity`. The
    /// upsert response carries the newly-assigned property `_id`s, so
    /// no separate GET is needed — we read them straight off the
    /// response and update the local row + cache.
    private func createEntity(propertyName: String, value: EditableValue, definition def: PropertyDefinition) async throws {
        guard case .create(let parentId, let typeId, _) = mode else { return }
        var changes: [EntityPropertyChange] = []
        if let change = makeChange(propertyName: propertyName, value: value, definition: def) {
            changes.append(change)
        }
        if let parentId {
            changes.append(EntityPropertyChange(type: "_parent", reference: parentId))
        }
        changes.append(EntityPropertyChange(type: "_type", reference: typeId))

        let response: EntityUpsertResponse = try await api.post("entity", body: changes)
        guard let newId = response._id else { return }
        currentEntityId = newId
        bootstrapLocalEntity(id: newId, typeId: typeId, parentId: parentId)
        applyUpsertResponse(response, propertyName: propertyName, value: value, definition: def)
        onSaved?(newId)
    }

    /// Add a brand-new value to an already-existing entity. Response's
    /// `properties` includes the just-inserted value with its server
    /// `_id`, which we copy onto the local row.
    private func addValue(entityId: String, propertyName: String, value: EditableValue, definition def: PropertyDefinition) async throws {
        guard let change = makeChange(propertyName: propertyName, value: value, definition: def) else { return }
        let response: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
        applyUpsertResponse(response, propertyName: propertyName, value: value, definition: def)
        onSaved?(entityId)
    }

    /// Replace an existing value. The response carries the same `_id`
    /// (replace mutates in place) plus the new value fields — we update
    /// the local cache so subsequent unchanged-skip checks short-circuit.
    private func editValue(entityId: String, propertyName: String, value: EditableValue, definition def: PropertyDefinition) async throws {
        guard var change = makeChange(propertyName: propertyName, value: value, definition: def) else { return }
        change._id = value._id
        let response: EntityUpsertResponse = try await api.post("entity/\(entityId)", body: [change])
        applyUpsertResponse(response, propertyName: propertyName, value: value, definition: def)
        onSaved?(entityId)
    }

    // MARK: - File upload

    /// Two-step file upload: POST metadata to receive an `UploadIntent`
    /// (presigned S3 PUT), then stream the temp file to S3 via that intent.
    /// On success, finalize the row to the saved state. On failure, clear
    /// the pending bytes (the temp file is removed unconditionally) and
    /// surface a `commitError` — the user re-picks to retry.
    private func runFileUpload(propertyName: String, value: EditableValue) async {
        guard let def = definitions.first(where: { $0.name == propertyName }) else { return }
        guard let fileURL = value.pendingFileURL,
              let filename = value.pendingFilename,
              let mimetype = value.pendingFiletype else { return }

        value.isUploading = true
        value.uploadProgress = -1
        isSaving = true
        defer {
            isSaving = false
        }
        defer {
            value.isUploading = false
            value.uploadProgress = -1
            value.pendingFileURL = nil
            value.pendingFilename = nil
            value.pendingFiletype = nil
            value.pendingFilesize = nil
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            // Step 1: POST file metadata. Creates the entity first if we're
            // in create mode and this is the first commit.
            let change = EntityPropertyChange(
                type: propertyName,
                language: value.language,
                filename: filename,
                filesize: value.pendingFilesize,
                filetype: mimetype
            )

            let response: EntityUpsertResponse
            if let entityId = currentEntityId {
                response = try await api.post("entity/\(entityId)", body: [change])
            } else {
                guard case .create(let parentId, let typeId, _) = mode else { return }
                var changes: [EntityPropertyChange] = [change]
                if let parentId { changes.append(EntityPropertyChange(type: "_parent", reference: parentId)) }
                changes.append(EntityPropertyChange(type: "_type", reference: typeId))

                response = try await api.post("entity", body: changes)
                if let newId = response._id {
                    currentEntityId = newId
                    bootstrapLocalEntity(id: newId, typeId: typeId, parentId: parentId)
                    onSaved?(newId)
                }
            }

            // Step 2: extract the just-inserted property's `upload` block.
            guard let property = response.properties?
                    .first(where: { $0.type == propertyName && $0.upload != nil }),
                  let intent = property.upload else {
                throw APIError.invalidResponse
            }

            // Step 3: stream bytes to S3 with progress.
            try await api.uploadFile(intent: intent, fileURL: fileURL) { fraction in
                value.uploadProgress = fraction
            }

            // Finalize the row to the saved state.
            if let serverId = property._id {
                value._id = serverId
                value.stringValue = filename
                value.filesize = value.pendingFilesize
                updateLocalEntityCache(propertyName: propertyName, propertyId: serverId, value: value, definition: def)
            }
            hasSavedChanges = true
            if let entityId = currentEntityId { onSaved?(entityId) }
        } catch {
            commitError = error.localizedDescription
        }
    }

    // MARK: - File picker handoff

    /// User picked one or more files from the upload row. Stage each pick
    /// onto an editable row (reusing the host row for the first, appending
    /// fresh rows for the rest) and queue each upload through the commit
    /// chain — `manageEmptyFields` then re-renders a trailing empty row
    /// so the user can pick more files for `list` properties.
    func handleFilesPicked(propertyName: String, hostRow: EditableValue, picks: [PickedFile]) {
        guard !picks.isEmpty else { return }
        guard let def = definitions.first(where: { $0.name == propertyName }) else { return }
        var rows = values[propertyName] ?? []

        var stagedRows: [EditableValue] = []
        for (index, pick) in picks.enumerated() {
            let target: EditableValue
            if index == 0 {
                target = hostRow
            } else {
                target = EditableValue()
                if let hostIndex = rows.firstIndex(where: { $0.id == hostRow.id }) {
                    rows.insert(target, at: hostIndex + index)
                } else {
                    rows.append(target)
                }
            }
            target.pendingFileURL = pick.url
            target.pendingFilename = pick.filename
            target.pendingFiletype = pick.mimetype
            target.pendingFilesize = pick.size
            target.isUploading = true
            target.uploadProgress = -1
            stagedRows.append(target)
        }

        values[propertyName] = rows
        manageEmptyFields(for: def)

        // Fire each upload through the commit chain — chained so the first
        // creates the entity (if needed) before later rows try to add values.
        for row in stagedRows {
            Task { await commit(propertyName: propertyName, value: row) }
        }
    }

    // MARK: - Per-value delete (swipe / file row trash)

    func deleteValue(propertyName: String, value: EditableValue, propertyId: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: DeleteResponse = try await api.delete("property/\(propertyId)")
            if var rows = values[propertyName] {
                rows.removeAll { $0.id == value.id }
                values[propertyName] = rows
            }
            if let def = definitions.first(where: { $0.name == propertyName }) {
                manageEmptyFields(for: def)
            }
            hasSavedChanges = true
        } catch {
            commitError = error.localizedDescription
        }
    }

    // MARK: - Empty-field housekeeping

    /// Mirrors webapp's `manageEmptyFields`. Keeps trailing empty rows
    /// tidy after every commit so the user can keep typing without
    /// pressing a "+" button each time.
    ///   non-list, non-multilingual : one empty row only when no values
    ///   list                       : one empty row trailing
    ///   multilingual               : one empty row per language;
    ///                                non-list also drops the empty when
    ///                                a saved value exists for that language
    func manageEmptyFields(for def: PropertyDefinition) {
        guard !def.readonly, def.formula == nil else { return }
        var rows = values[def.name] ?? []

        // Files: keep all saved + uploading rows, plus exactly one trailing
        // empty row for the upload button. Single-value properties hide the
        // upload row when one file is already saved (delete first to swap).
        if def.type == "file" {
            let occupied = rows.filter { $0._id != nil || $0.isUploading || $0.pendingFileURL != nil }
            if def.list || occupied.isEmpty {
                rows = occupied + [defaultRow(for: def)]
            } else {
                rows = occupied
            }
            values[def.name] = rows
            return
        }

        // Multilingual: per-language tracking. For each language, decide
        // whether to add/keep/drop a single trailing empty row. Saved values
        // without a language tag (legacy data on a now-multilingual property)
        // are folded into the first language so they don't double up with
        // an extra empty row for that language.
        if def.multilingual {
            let firstLang = Self.multilingualLanguages.first ?? "en"
            let untaggedSaved = rows.filter {
                $0._id != nil && !Self.multilingualLanguages.contains($0.language ?? "")
            }
            // Values first (per language), empty rows collected below them —
            // a new empty row never sits above existing values.
            var rebuilt: [EditableValue] = []
            var empties: [EditableValue] = []
            for lang in Self.multilingualLanguages {
                var saved = rows.filter { $0._id != nil && $0.language == lang }
                if lang == firstLang { saved.append(contentsOf: untaggedSaved) }
                let nonEmptyUnsaved = rows.filter {
                    $0._id == nil && $0.language == lang && !isEditableValueEmpty($0, definition: def)
                }
                let empty = rows.filter {
                    $0._id == nil && $0.language == lang && isEditableValueEmpty($0, definition: def)
                }

                rebuilt.append(contentsOf: saved)
                rebuilt.append(contentsOf: nonEmptyUnsaved)

                let needsEmpty = def.list ? true : saved.isEmpty
                if needsEmpty {
                    empties.append(empty.first ?? defaultRow(for: def, language: lang))
                }
            }
            values[def.name] = rebuilt + empties
            return
        }

        if def.list {
            // Values first, exactly one empty row below them — an empty
            // row never sits above existing values.
            let nonEmpty = rows.filter { $0._id != nil || !isEditableValueEmpty($0, definition: def) }
            let empties = rows.filter { $0._id == nil && isEditableValueEmpty($0, definition: def) }
            rows = nonEmpty + [empties.first ?? defaultRow(for: def)]
        } else {
            let saved = rows.filter { $0._id != nil }
            let trailingEmpty = rows.filter { $0._id == nil && isEditableValueEmpty($0, definition: def) }
            if !saved.isEmpty {
                // Drop trailing empty rows once any value is saved.
                rows = saved
            } else {
                rows = Array(trailingEmpty.prefix(1))
                if rows.isEmpty {
                    rows = [defaultRow(for: def)]
                }
            }
        }

        values[def.name] = rows
    }

    // MARK: - Whole-entity delete

    func deleteEntity() async {
        guard let entityId = currentEntityId else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let _: DeleteResponse = try await api.delete("entity/\(entityId)")
            onDeleted?()
            dismiss()
        } catch {
            commitError = error.localizedDescription
        }
    }
}
