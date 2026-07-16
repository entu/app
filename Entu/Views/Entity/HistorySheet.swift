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
                    FormPlaceholder()
                } else if let loadError {
                    ContentUnavailableView(loadError, systemImage: "exclamationmark.triangle")
                } else if groups.isEmpty {
                    ContentUnavailableView("historyEmpty", systemImage: "clock.arrow.circlepath")
                } else {
                    listBody
                }
            }
        }
        .background(Color("WindowBackground"))
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

    /// Timeline: per group an avatar + editor + timestamp header, then the
    /// property rows on a left rule (design 8d). `LazyVStack` keeps the
    /// infinite-scroll trigger working — the last row's `.onAppear` fires
    /// only when scrolled into view.
    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                    VStack(alignment: .leading, spacing: 0) {
                        groupHeader(group)

                        // Left rule aligned under the avatar's center.
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 2)
                                .padding(.leading, 10)

                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(group.changes.enumerated()), id: \.element.id) { changeIndex, change in
                                    changeRow(change)

                                    if changeIndex < group.changes.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .padding(.leading, 18)
                        }
                    }
                    .onAppear {
                        if groupIndex == groups.count - 1 && hasMore && !isLoadingMore {
                            Task { await loadMore() }
                        }
                    }
                }

                if isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func groupHeader(_ group: HistoryGroup) -> some View {
        HStack(spacing: 8) {
            // Resolved name → editor id tail → "Entu" (with the logo) for
            // changes without an editor (by == nil, system actions).
            let name = group.editorName
                ?? (group.editorId.isEmpty ? "Entu" : group.editorId.suffix(8).description)

            EditorAvatar(editorId: group.editorId, name: name)

            Text(verbatim: name)
                .fontWeight(.semibold)

            Spacer()

            if let at = group.at {
                Text(verbatim: timestamp(at))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 6)
    }

    /// "13.09.2013 · 9:41" — date and time joined with a middot.
    private func timestamp(_ date: Date) -> String {
        let day = date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale))
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        return "\(day) · \(time)"
    }

    private func changeRow(_ change: HistoryChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(verbatim: change.label)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .trailing)

            // Old values (struck through) flow inline before the new ones,
            // so a replacement reads "old  new" on one line. A change with
            // no new values is a pure deletion — marked dark red.
            FlowLayout(spacing: 8) {
                ForEach(Array(change.oldValues.enumerated()), id: \.offset) { _, value in
                    valueView(value, kind: change.newValues.isEmpty ? .deleted : .old, isAddition: false)
                }
                ForEach(Array(change.newValues.enumerated()), id: \.offset) { _, value in
                    valueView(value, kind: .new, isAddition: change.oldValues.isEmpty)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    private enum ValueKind {
        case old
        case deleted
        case new

        var isStruckThrough: Bool { self != .new }
    }

    private func valueView(_ value: HistoryValue, kind: ValueKind, isAddition: Bool) -> some View {
        HStack(spacing: 6) {
            if let lang = value.language?.uppercased() {
                Text(verbatim: lang)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }

            let text = (isAddition ? "+ " : "") + value.text
                + (value.suffix.map { " · \($0)" } ?? "")

            if value.suffix != nil {
                // File values render as tinted chips.
                Text(verbatim: text)
                    .font(.caption)
                    .fontWeight(.medium)
                    .strikethrough(kind.isStruckThrough)
                    .foregroundStyle(valueColor(for: kind))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(chipBackground(for: kind), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(verbatim: text)
                    .strikethrough(kind.isStruckThrough)
                    .foregroundStyle(valueColor(for: kind))
            }
        }
        .textSelection(.enabled)
    }

    private func valueColor(for kind: ValueKind) -> AnyShapeStyle {
        switch kind {
        case .old: AnyShapeStyle(.quaternary)
        case .deleted: AnyShapeStyle(Color("DestructiveText"))
        case .new: AnyShapeStyle(Color("SuccessText"))
        }
    }

    private func chipBackground(for kind: ValueKind) -> AnyShapeStyle {
        switch kind {
        case .old: AnyShapeStyle(.fill.quaternary)
        case .deleted: AnyShapeStyle(Color.red.opacity(0.1))
        case .new: AnyShapeStyle(Color.green.opacity(0.12))
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

// MARK: - Editor avatar

/// 22pt circular editor avatar — the person entity's thumbnail when one
/// exists, otherwise their initial on the derived id color.
private struct EditorAvatar: View {
    @Environment(APIClient.self) private var api

    let editorId: String
    let name: String

    @State private var image: Image?

    var body: some View {
        Group {
            if editorId.isEmpty {
                // System changes — the Entu logo, unclipped like everywhere.
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            } else {
                Group {
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle()
                            .fill(Color.derivedGradient(from: editorId))
                            .overlay {
                                Text(verbatim: String(name.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
            }
        }
        .accessibilityHidden(true)
        .task(id: editorId) {
            image = nil
            guard !editorId.isEmpty,
                  let url = await api.entityThumbnailURL(entityId: editorId, size: 50) else { return }
            image = await loadImage(from: url)
        }
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
