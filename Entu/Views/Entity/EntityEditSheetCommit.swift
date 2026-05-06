// Per-value commit, file upload, delete, and trailing-empty housekeeping
// for `EntityEditView`. Split out of `EntityEditSheet.swift` so the main
// file stays focused on rendering. Mirrors the webapp's autosave model
// (`components/property/edit.vue::updateValue`) — a single commit chain
// fans out to create/add/edit/delete based on entity + value state.

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
        } catch {
            commitError = error.localizedDescription
        }

        manageEmptyFields(for: def)
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
            if let entityId = currentEntityId { onSaved?(entityId) }
        } catch {
            commitError = error.localizedDescription
        }
    }

    // MARK: - Local cache mirror

    /// Walk the upsert response, find the property entry that matches the
    /// row we just committed (by `type` + `language`), and update both:
    ///   - `value._id` ← server-assigned id (for newly-created values)
    ///   - the local `entity.properties` cache so the next commit can
    ///     compare against it without refetching.
    private func applyUpsertResponse(_ response: EntityUpsertResponse, propertyName: String, value: EditableValue, definition def: PropertyDefinition) {
        guard let returned = response.properties else { return }

        // Pick the matching property — same name + same language. For
        // editValue, prefer the entry whose `_id` matches the row's.
        let match: UpsertedProperty?
        if let rowId = value._id {
            match = returned.first { $0._id == rowId && $0.type == propertyName }
                ?? returned.first { $0.type == propertyName && $0.language == value.language }
        } else {
            match = returned.first { $0.type == propertyName && $0.language == value.language }
                ?? returned.first { $0.type == propertyName }
        }

        if let match, let serverId = match._id {
            value._id = serverId
            updateLocalEntityCache(propertyName: propertyName, propertyId: serverId, value: value, definition: def)
        }
    }

    /// Build a fresh `EntityDetail` for a just-created entity so later
    /// commits in the same session can short-circuit unchanged-rows
    /// against this in-memory cache without a refetch.
    private func bootstrapLocalEntity(id: String, typeId: String, parentId: String?) {
        var props: [String: [PropertyValue]] = [:]
        props["_type"] = [makeReferencePropertyValue(reference: typeId)]
        if let parentId {
            props["_parent"] = [makeReferencePropertyValue(reference: parentId)]
        }
        let json: [String: Any] = ["_id": id]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let response = try? JSONDecoder().decode(EntityDetailResponse.self, from: data) {
            entity = response.entity
        }
        // The decoder above only carries `_id`; layer the type/parent
        // entries we synthesised into the in-memory model.
        if var current = entity {
            var merged = current.properties
            for (k, v) in props { merged[k] = v }
            current = mergedEntity(current, propertiesOverride: merged)
            entity = current
        }
    }

    /// Insert or replace one property in the local `entity.properties`
    /// cache so it stays in sync after a commit without a refetch.
    private func updateLocalEntityCache(propertyName: String, propertyId: String, value: EditableValue, definition def: PropertyDefinition) {
        guard var current = entity else { return }
        var rows = current.properties[propertyName] ?? []
        rows.removeAll { $0._id == propertyId }
        rows.append(makePropertyValue(_id: propertyId, value: value, definition: def))
        var merged = current.properties
        merged[propertyName] = rows
        current = mergedEntity(current, propertiesOverride: merged)
        entity = current
    }

    /// Drop a property value from the local `entity.properties` cache.
    private func removeFromLocalEntity(propertyName: String, propertyId: String) {
        guard var current = entity else { return }
        guard var rows = current.properties[propertyName] else { return }
        rows.removeAll { $0._id == propertyId }
        var merged = current.properties
        merged[propertyName] = rows
        current = mergedEntity(current, propertiesOverride: merged)
        entity = current
    }

    /// Build a reference-only `PropertyValue` for the local cache.
    private func makeReferencePropertyValue(reference: String) -> PropertyValue {
        let json: [String: Any] = ["reference": reference]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let value = try? JSONDecoder().decode(PropertyValue.self, from: data) {
            return value
        }
        return PropertyValue(_id: nil, string: nil, number: nil, boolean: nil, reference: reference, date: nil, datetime: nil, filename: nil, filesize: nil, language: nil, provider: nil, email: nil, ordinal: nil)
    }

    /// Build a `PropertyValue` for the local cache from an `EditableValue`.
    private func makePropertyValue(_id: String, value: EditableValue, definition def: PropertyDefinition) -> PropertyValue {
        let stringValue: String? = {
            switch def.type {
            case "boolean", "number", "date", "datetime", "reference", "file": return nil
            default:
                let trimmed = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }()
        let numberValue: Double? = (def.type == "number") ? value.numberValue : nil
        let dateIso: String? = {
            guard let date = value.dateValue else { return nil }
            switch def.type {
            case "date", "datetime": return ISO8601DateFormatter().string(from: date)
            default: return nil
            }
        }()

        var json: [String: Any] = ["_id": _id]
        if let s = stringValue { json["string"] = s }
        if let n = numberValue { json["number"] = n }
        if def.type == "boolean" { json["boolean"] = value.boolValue }
        if let id = value.referenceId { json["reference"] = id }
        if def.type == "date", let iso = dateIso { json["date"] = iso }
        if def.type == "datetime", let iso = dateIso { json["datetime"] = iso }
        if let lang = value.language { json["language"] = lang }

        if let data = try? JSONSerialization.data(withJSONObject: json),
           let decoded = try? JSONDecoder().decode(PropertyValue.self, from: data) {
            return decoded
        }
        return PropertyValue(_id: _id, string: stringValue, number: numberValue, boolean: def.type == "boolean" ? value.boolValue : nil, reference: value.referenceId, date: def.type == "date" ? dateIso : nil, datetime: def.type == "datetime" ? dateIso : nil, filename: nil, filesize: nil, language: value.language, provider: nil, email: nil, ordinal: nil)
    }

    /// Reassemble an `EntityDetail` with a new `properties` map. Required
    /// because `EntityDetail` decodes its dynamic properties via a custom
    /// decoder and exposes `properties` as `let` — there's no in-place
    /// mutator, so we re-encode + decode through JSON to land a fresh copy.
    private func mergedEntity(_ entity: EntityDetail, propertiesOverride: [String: [PropertyValue]]) -> EntityDetail {
        var json: [String: Any] = [:]
        json["_id"] = entity._id
        if let thumb = entity._thumbnail { json["_thumbnail"] = thumb }
        for (key, values) in propertiesOverride {
            if let data = try? JSONEncoder().encode(values),
               let any = try? JSONSerialization.jsonObject(with: data) {
                json[key] = any
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let decoded = try? JSONDecoder().decode(EntityDetail.self, from: data) {
            return decoded
        }
        return entity
    }

    // MARK: - Wire-shape encoding

    /// Build the wire-shape change for a row. Returns nil for the empty
    /// non-counter case; that branch is handled by the delete path.
    private func makeChange(propertyName: String, value: EditableValue, definition def: PropertyDefinition) -> EntityPropertyChange? {
        var change = EntityPropertyChange(type: propertyName)
        change.language = value.language

        switch def.type {
        case "boolean":
            // Entu only stores `true`. False is unreachable here because
            // `isEditableValueEmpty` already routed it to the delete path.
            change.boolean = true
        case "number":
            guard let num = value.numberValue else { return nil }
            let rounded = def.decimals.map { decimals in
                (num * pow(10.0, Double(decimals))).rounded() / pow(10.0, Double(decimals))
            } ?? num
            change.number = rounded
        case "date":
            guard let date = value.dateValue else { return nil }
            change.date = ISO8601DateFormatter().string(from: date)
        case "datetime":
            guard let date = value.dateValue else { return nil }
            change.datetime = ISO8601DateFormatter().string(from: date)
        case "reference":
            guard let id = value.referenceId else { return nil }
            change.reference = id
        case "counter":
            // Counter Generate — webapp sends `string` (current value)
            // alongside `counter: 1`; the API increments and returns
            // the next sequence value. Always sends the change even
            // if the current string is empty, so the very first
            // Generate creates the initial value.
            change.string = value.stringValue
            change.counter = 1
        default:
            let trimmed = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            change.string = trimmed
        }

        return change
    }

    /// True when an `EditableValue` carries no content for its type.
    func isEditableValueEmpty(_ value: EditableValue, definition def: PropertyDefinition) -> Bool {
        switch def.type {
        case "file":
            // A file row only counts as content when there's already a saved
            // file (`_id`) or one staged for upload (`pendingFileURL`). The
            // empty trailing-upload row is intentionally "empty" so the
            // commit chain skips it.
            return value._id == nil && value.pendingFileURL == nil
        case "boolean":
            // Entu only stores `true`. Toggling off is a delete (when
            // saved) or a no-op (when unsaved) — both are "empty" here.
            return !value.boolValue
        case "number":
            return value.numberValue == nil
        case "date", "datetime":
            return value.dateValue == nil
        case "reference":
            return value.referenceId == nil
        case "counter":
            // New row (no `_id`): never empty so the Generate button
            // always commits and the server resolves the next sequence.
            // Saved row: treat blank text as empty so clearing the field
            // routes to the DELETE branch (matches webapp).
            if value._id == nil { return false }
            return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether a row currently matches its server-side counterpart, so
    /// commit can short-circuit unchanged blurs.
    private func valueMatchesExisting(_ row: EditableValue, existing: PropertyValue, type: String) -> Bool {
        switch type {
        case "boolean": return row.boolValue == (existing.boolean ?? false)
        case "number":  return row.numberValue == existing.number
        case "date", "datetime":
            let serverIso = existing.date ?? existing.datetime
            let serverDate = serverIso.flatMap { ISO8601DateFormatter.parse($0) }
            guard let local = row.dateValue, let serverDate else {
                return row.dateValue == nil && serverDate == nil
            }
            return abs(local.timeIntervalSince1970 - serverDate.timeIntervalSince1970) < 1.0
        case "reference": return row.referenceId == existing.reference
        default: return row.stringValue == (existing.string ?? "")
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
        do {
            let _: DeleteResponse = try await api.delete("property/\(propertyId)")
            if var rows = values[propertyName] {
                rows.removeAll { $0.id == value.id }
                values[propertyName] = rows
            }
            if let def = definitions.first(where: { $0.name == propertyName }) {
                manageEmptyFields(for: def)
            }
        } catch {
            commitError = error.localizedDescription
        }
    }

    // MARK: - Empty-field housekeeping

    /// Mirrors webapp's `manageEmptyFields`. Keeps trailing empty rows
    /// tidy after every commit so the user can keep typing without
    /// pressing a "+" button each time.
    ///   non-list, non-multilingual : one empty row only when no values
    ///   list                       : two empty rows trailing
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
            var rebuilt: [EditableValue] = []
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
                    if let first = empty.first {
                        rebuilt.append(first)
                    } else {
                        rebuilt.append(defaultRow(for: def, language: lang))
                    }
                }
            }
            values[def.name] = rebuilt
            return
        }

        if def.list {
            let emptyTrailing = rows.suffix(while: { $0._id == nil && isEditableValueEmpty($0, definition: def) }).count
            if emptyTrailing < 2 {
                for _ in 0..<(2 - emptyTrailing) {
                    rows.append(defaultRow(for: def))
                }
            } else if emptyTrailing > 2 {
                rows.removeLast(emptyTrailing - 2)
            }
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

private extension Array {
    /// Trailing run length where `predicate` is true.
    func suffix(while predicate: (Element) -> Bool) -> [Element] {
        var i = endIndex
        while i > startIndex, predicate(self[i - 1]) {
            i -= 1
        }
        return Array(self[i..<endIndex])
    }
}
