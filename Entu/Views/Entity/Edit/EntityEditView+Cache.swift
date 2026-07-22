// Local-cache mirroring and wire-shape encoding for `EntityEditView`. Split
// out of `EntityEditView+Commit.swift`: after each commit these keep the
// in-memory `entity.properties` in sync — so the next commit can short-circuit
// unchanged rows without a refetch — and build the API change payloads.

import Foundation

extension EntityEditView {
    // MARK: - Local cache mirror

    /// Walk the upsert response, find the property entry that matches the
    /// row we just committed (by `type` + `language`), and update both:
    ///   - `value._id` ← server-assigned id (for newly-created values)
    ///   - the local `entity.properties` cache so the next commit can
    ///     compare against it without refetching.
    func applyUpsertResponse(_ response: EntityUpsertResponse, propertyName: String, value: EditableValue, definition def: PropertyDefinition) {
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

            // Reserved auth properties: copy the server-generated fields
            // back onto the row (mirrors webapp's `addValue` in
            // `property/edit.vue`). The local entity cache is skipped for
            // these — their rows are button-driven, so the blur-compare
            // short-circuit the cache exists for never runs on them.
            if propertyName == "entu_api_key" {
                // The one-time raw key — GET responses mask it to `***`.
                value.stringValue = match.string ?? value.stringValue
                return
            }
            if propertyName == "entu_user" {
                // Server replaced the sentinel string with an invite JWT.
                value.stringValue = ""
                value.invite = match.invite
                value.email = match.email
                return
            }

            updateLocalEntityCache(propertyName: propertyName, propertyId: serverId, value: value, definition: def)
        }
    }

    /// Build a fresh `EntityDetail` for a just-created entity so later
    /// commits in the same session can short-circuit unchanged-rows
    /// against this in-memory cache without a refetch.
    func bootstrapLocalEntity(id: String, typeId: String, parentId: String?) {
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
    func updateLocalEntityCache(propertyName: String, propertyId: String, value: EditableValue, definition def: PropertyDefinition) {
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
    func removeFromLocalEntity(propertyName: String, propertyId: String) {
        guard var current = entity else { return }
        guard var rows = current.properties[propertyName] else { return }
        rows.removeAll { $0._id == propertyId }
        var merged = current.properties
        merged[propertyName] = rows
        current = mergedEntity(current, propertiesOverride: merged)
        entity = current
    }

    /// Build a reference-only `PropertyValue` for the local cache.
    func makeReferencePropertyValue(reference: String) -> PropertyValue {
        let json: [String: Any] = ["reference": reference]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let value = try? JSONDecoder().decode(PropertyValue.self, from: data) {
            return value
        }
        return PropertyValue(_id: nil, string: nil, number: nil, boolean: nil, reference: reference, date: nil, datetime: nil, filename: nil, filesize: nil, language: nil, provider: nil, email: nil, invite: nil, ordinal: nil, inherited: nil)
    }

    /// Build a `PropertyValue` for the local cache from an `EditableValue`.
    func makePropertyValue(_id: String, value: EditableValue, definition def: PropertyDefinition) -> PropertyValue {
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
        return PropertyValue(_id: _id, string: stringValue, number: numberValue, boolean: def.type == "boolean" ? value.boolValue : nil, reference: value.referenceId, date: def.type == "date" ? dateIso : nil, datetime: def.type == "datetime" ? dateIso : nil, filename: nil, filesize: nil, language: value.language, provider: nil, email: nil, invite: nil, ordinal: nil, inherited: nil)
    }

    /// Reassemble an `EntityDetail` with a new `properties` map. Required
    /// because `EntityDetail` decodes its dynamic properties via a custom
    /// decoder and exposes `properties` as `let` — there's no in-place
    /// mutator, so we re-encode + decode through JSON to land a fresh copy.
    func mergedEntity(_ entity: EntityDetail, propertiesOverride: [String: [PropertyValue]]) -> EntityDetail {
        var json: [String: Any] = [:]
        json["_id"] = entity._id
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
    func makeChange(propertyName: String, value: EditableValue, definition def: PropertyDefinition) -> EntityPropertyChange? {
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
    func valueMatchesExisting(_ row: EditableValue, existing: PropertyValue, type: String) -> Bool {
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
}
