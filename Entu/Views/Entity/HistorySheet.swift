// Per-entity history drawer. Mirrors webapp's
// `components/entity/drawer/history.vue` — chronological audit log of all
// property changes (additions, modifications, deletions) with the editor
// and timestamp.
//
// Changes are grouped by editor + 1-minute bucket so a multi-property
// edit by one user shows up as a single block. Within each block, every
// touched property is one row with its before / after values.
//
// Editor+ sheet — visibility is gated by the parent EntityToolbar.

import SwiftUI

/// Read-only entity-history viewer.
struct HistorySheet: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let entityId: String
    let typeId: String?

    /// Subtitle inputs — entity's display name (preferred) and type label
    /// (fallback). Passed by the caller so we don't need to fetch the entity
    /// just to render the header.
    let entityName: String?
    let typeLabel: String?

    /// Explicit init so the `@State` properties below stay out of the init
    /// surface (the caller supplies only these four inputs).
    init(entityId: String, typeId: String?, entityName: String?, typeLabel: String?) {
        self.entityId = entityId
        self.typeId = typeId
        self.entityName = entityName
        self.typeLabel = typeLabel
    }

    @State private var rawChanges: [HistoryChange.Raw] = []
    @State private var editorNames: [String: String] = [:]
    @State private var groups: [HistoryGroup] = []
    @State private var totalCount: Int = 0
    @State private var pageSize: Int = 25
    @State private var definitions: [String: PropertyDefinition] = [:]
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadError: String?

    private var hasMore: Bool { rawChanges.count < totalCount }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            sheetHeader
            #endif
            Group {
                if isLoading && groups.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                } else if groups.isEmpty {
                    ContentUnavailableView("historyEmpty", systemImage: "clock.arrow.circlepath")
                } else {
                    listBody
                }
            }
        }
        #if os(iOS)
        .navigationTitle(Text("history"))
        .navigationSubtitle(headerSubtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { dismiss() }
            }
        }
        .task { await load() }
        .appLanguageScoped()
    }

    /// Subtitle: entity name (preferred), fall back to type label.
    private var headerSubtitle: String? {
        if let entityName, !entityName.isEmpty { return entityName }
        return typeLabel
    }

    #if os(macOS)
    /// In-content title bar for macOS sheets. See EntityEditView.swift —
    /// macOS sheets don't render the toolbar's principal slot.
    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("history")
                .font(.headline)
            if let headerSubtitle, !headerSubtitle.isEmpty {
                Text(verbatim: headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    #endif

    /// `List` (not `Form`) so rows render lazily — the last row's
    /// `.onAppear` fires only when scrolled into view, which is what the
    /// infinite-scroll trigger relies on.
    private var listBody: some View {
        List {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                Section {
                    ForEach(Array(group.changes.enumerated()), id: \.element.id) { changeIndex, change in
                        changeRow(change)
                            .onAppear {
                                let isLastGroup = groupIndex == groups.count - 1
                                let isLastChange = changeIndex == group.changes.count - 1
                                if isLastGroup && isLastChange && hasMore && !isLoadingMore {
                                    Task { await loadMore() }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(verbatim: group.editorName ?? group.editorId.suffix(8).description)
                            .fontWeight(.semibold)
                        Spacer()
                        if let at = group.at {
                            Text(at, format: Date.FormatStyle(date: .numeric, time: .shortened, locale: locale))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }

    private func changeRow(_ change: HistoryChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: change.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Array(change.oldValues.enumerated()), id: \.offset) { _, value in
                valueLine(value, kind: .old)
            }
            ForEach(Array(change.newValues.enumerated()), id: \.offset) { _, value in
                valueLine(value, kind: .new)
            }
        }
    }

    private enum ValueKind { case old, new }

    private func valueLine(_ value: HistoryValue, kind: ValueKind) -> some View {
        HStack(spacing: 6) {
            if let lang = value.language?.uppercased() {
                Text(verbatim: lang)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(kind == .old ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(verbatim: value.text)
                .strikethrough(kind == .old)
                .foregroundStyle(kind == .old ? Color.red : Color.green)
            if let suffix = value.suffix {
                Text(verbatim: suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Loading

    /// Initial load — clears any previous state and fetches page 1.
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        // Make sure type definitions are available so we can resolve
        // user-friendly property labels per change.
        if definitions.isEmpty, let typeId {
            let defs = await fetchDefinitions(typeId: typeId)
            definitions = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0) })
        }

        rawChanges = []
        editorNames = [:]
        groups = []
        await fetchPage(skip: 0)
    }

    /// Append the next page when the last visible row becomes visible.
    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchPage(skip: rawChanges.count)
    }

    /// Fetch one page from the API, append to the accumulated raw changes,
    /// resolve any new editor names, and rebuild groups. Buckets that
    /// straddle a page boundary merge naturally because we always rebuild
    /// from the full accumulated list.
    private func fetchPage(skip: Int) async {
        do {
            let response: HistoryResponse = try await api.get(
                "entity/\(entityId)/history",
                params: ["limit": String(pageSize), "skip": String(skip)]
            )
            totalCount = response.count ?? 0
            rawChanges.append(contentsOf: response.changes)

            // Resolve names for editors we haven't seen yet (in parallel).
            let newEditorIds = Set(response.changes.compactMap { $0.by })
                .subtracting(editorNames.keys)
            if !newEditorIds.isEmpty {
                let fetched = await fetchEditorNames(ids: newEditorIds)
                for (id, name) in fetched { editorNames[id] = name }
            }

            groups = buildGroups(from: rawChanges, editorNames: editorNames)
        } catch {
            loadError = String(localized: "networkError", bundle: .currentLocalized)
        }
    }

    private func fetchDefinitions(typeId: String) async -> [PropertyDefinition] {
        let params: [String: String] = [
            "_parent.reference": typeId,
            "props": "name,label,decimals,markdown,ordinal"
        ]
        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            return []
        }
        return response.entities.map { PropertyDefinition(from: $0) }
    }

    private func fetchEditorNames(ids: Set<String>) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    let response: EntityDetailResponse? = try? await api.get(
                        "entity/\(id)",
                        params: ["props": "name"]
                    )
                    let name = PropertyValue.localized(response?.entity?.properties["name"])
                    return (id, name)
                }
            }
            var map: [String: String] = [:]
            for await (id, name) in group {
                if let name { map[id] = name }
            }
            return map
        }
    }

    // MARK: - Grouping

    /// Group raw changes by `(editor, 1-minute bucket)`, then within each
    /// bucket by property name. Mirrors webapp's bucketing exactly so a
    /// single multi-property edit shows up as one row group.
    private func buildGroups(from changes: [HistoryChange.Raw], editorNames: [String: String]) -> [HistoryGroup] {
        struct BucketKey: Hashable { let editorId: String; let minute: String }

        var buckets: [BucketKey: HistoryGroup] = [:]
        var keyOrder: [BucketKey] = []

        for raw in changes {
            let editorId = raw.by ?? ""
            let minute = raw.at.map(minuteBucket(_:)) ?? "unknown"
            let key = BucketKey(editorId: editorId, minute: minute)

            if buckets[key] == nil {
                buckets[key] = HistoryGroup(
                    id: "\(editorId)-\(minute)",
                    editorId: editorId,
                    editorName: editorNames[editorId],
                    at: raw.at,
                    changes: []
                )
                keyOrder.append(key)
            }

            // Find or insert the per-property row inside the bucket.
            let label = definitions[raw.type]?.label ?? raw.type
            let ordinal = definitions[raw.type]?.ordinal ?? 9999
            var bucket = buckets[key]!
            var change = bucket.changes.first(where: { $0.type == raw.type })
                ?? HistoryChange(type: raw.type, label: label, ordinal: ordinal, oldValues: [], newValues: [])
            if let v = formatValue(raw.old) { change.oldValues.append(v) }
            if let v = formatValue(raw.new) { change.newValues.append(v) }
            bucket.changes.removeAll { $0.type == raw.type }
            bucket.changes.append(change)
            buckets[key] = bucket
        }

        // Sort buckets newest-first; sort changes inside each bucket by ordinal.
        let sortedKeys = keyOrder.sorted { lhs, rhs in
            let lAt = buckets[lhs]?.at
            let rAt = buckets[rhs]?.at
            switch (lAt, rAt) {
            case (let l?, let r?): return l > r
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return sortedKeys.compactMap { key in
            guard var group = buckets[key] else { return nil }
            group.changes.sort { $0.ordinal < $1.ordinal }
            return group
        }
    }

    private func minuteBucket(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let truncated = cal.date(from: components) ?? date
        return ISO8601DateFormatter().string(from: truncated)
    }

    /// Format a raw value blob into a printable string + optional suffix.
    /// Mirrors webapp's `formatValue` priority — reference / file / boolean /
    /// datetime / date / number / string.
    private func formatValue(_ value: PropertyValue?) -> HistoryValue? {
        guard let value else { return nil }
        if let ref = value.reference {
            return HistoryValue(text: value.string ?? ref, suffix: nil, language: value.language)
        }
        if let filename = value.filename {
            let suffix = value.filesize.map { $0.fileSizeString }
            return HistoryValue(text: filename, suffix: suffix, language: value.language)
        }
        if let b = value.boolean {
            return HistoryValue(text: b ? "✓" : "✗", suffix: nil, language: value.language)
        }
        if let iso = value.datetime, let date = ISO8601DateFormatter.parse(iso) {
            return HistoryValue(
                text: date.formatted(.dateTime.locale(locale)),
                suffix: nil,
                language: value.language
            )
        }
        if let iso = value.date, let date = ISO8601DateFormatter.parse(iso) {
            return HistoryValue(
                text: date.formatted(date: .numeric, time: .omitted),
                suffix: nil,
                language: value.language
            )
        }
        if let n = value.number {
            return HistoryValue(text: "\(n)", suffix: nil, language: value.language)
        }
        if let s = value.string {
            return HistoryValue(text: s, suffix: nil, language: value.language)
        }
        return nil
    }
}

// MARK: - Wire types

private struct HistoryResponse: Decodable {
    let changes: [HistoryChange.Raw]
    let count: Int?
}

extension HistoryChange {
    /// Single raw history entry from the API — `old` / `new` may be absent
    /// (e.g. property was added or deleted). `at` ISO 8601, `by` is a user
    /// entity id (or nil for system actions).
    struct Raw: Decodable {
        let type: String
        let at: Date?
        let by: String?
        let old: PropertyValue?
        let new: PropertyValue?

        private enum CodingKeys: String, CodingKey { case type, at, by, old, new }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            by = try? c.decode(String.self, forKey: .by)
            old = try? c.decode(PropertyValue.self, forKey: .old)
            new = try? c.decode(PropertyValue.self, forKey: .new)
            if let iso = try? c.decode(String.self, forKey: .at) {
                at = ISO8601DateFormatter.parse(iso)
            } else {
                at = nil
            }
        }
    }
}

// MARK: - Display models

/// One bucket on screen — a single editor's edits within a 1-minute window.
struct HistoryGroup: Identifiable {
    let id: String
    let editorId: String
    let editorName: String?
    let at: Date?
    var changes: [HistoryChange]
}

/// One property's old/new values within a bucket.
struct HistoryChange: Identifiable {
    let type: String
    let label: String
    let ordinal: Double
    var oldValues: [HistoryValue]
    var newValues: [HistoryValue]
    var id: String { type }
}

/// One printable value with optional language tag and trailing suffix
/// (e.g. file size, datetime label).
struct HistoryValue {
    let text: String
    let suffix: String?
    let language: String?
}
