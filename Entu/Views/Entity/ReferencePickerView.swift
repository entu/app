// Modal entity picker used by `PropertyEditor` for `reference`-typed
// properties. Presented as a stacked `.sheet` from the edit sheet —
// macOS sheet sizing collapses on `NavigationStack` pushes, so a
// nested sheet is the cross-platform-stable presentation.
//
// Renders a search field bound to a debounced text input. Each query
// hits `GET /{db}/entity` filtered by the property definition's
// `query` (when present) plus the user's free-text `q`. Results show
// entity name, mirroring the webapp's `my-select-reference`. Tap a row
// to select; the parent receives the entity id and resolved name.

import SwiftUI

/// Search-as-you-type entity picker for reference properties.
struct ReferencePickerView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    /// In-app language preference. Sheets host their content outside the
    /// parent's view tree, so the root locale doesn't propagate down — this
    /// view re-applies it below so localized strings translate correctly.
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    /// Property definition's `query` string — additional filters scoped to
    /// the kinds of entities this reference can point at. nil ⇒ unscoped.
    let query: String?

    /// Called with the picked entity's id and display name.
    let onSelect: (String, String) -> Void

    @State private var searchText: String = ""
    @State private var results: [ReferenceItem] = []
    @State private var isLoading = false
    @State private var totalCount: Int?
    @State private var debounceTask: Task<Void, Never>?

    private static let pageLimit = 100

    /// Local picker row — name + the entity's type label, mirroring
    /// webapp's two-column option layout (name leading, type badge
    /// trailing).
    private struct ReferenceItem: Identifiable, Hashable {
        let _id: String
        let name: String
        let typeLabel: String?
        var id: String { _id }
    }

    var body: some View {
        List {
            ForEach(results) { item in
                Button {
                    onSelect(item._id, item.name)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: item.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let typeLabel = item.typeLabel, !typeLabel.isEmpty {
                            Text(verbatim: typeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let total = totalCount, total > results.count {
                Text("foundMore \(total - results.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isLoading && results.isEmpty {
                ProgressView()
            } else if !isLoading && results.isEmpty && !searchText.isEmpty {
                ContentUnavailableView {
                    Label("noResults", systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // `.navigationBarDrawer(displayMode: .always)` pins the
        // search field permanently below the title bar, so it
        // doesn't appear/disappear on focus and the result list
        // doesn't shift its position.
        #if os(iOS)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("searchPlaceholder")
        )
        #else
        .searchable(text: $searchText, prompt: Text("searchPlaceholder"))
        #endif
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .task { await runSearch() }
        .navigationTitle("selectReference")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
            }
        }
        .frame(minWidth: 480, minHeight: 500)
        .id(appLanguage)
        .environment(\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))
    }

    /// Debounce the user's typing so we don't fire a request per keystroke.
    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        isLoading = true
        defer { isLoading = false }

        // Same shape as webapp's `my-select-reference.vue` filter:
        // start from the property definition's `query` (when present),
        // then layer on `q`, the props projection (`_type.string` +
        // `name` only), `sort`, and `limit`.
        var params = (query ?? "").parseURLQuery()
        if !searchText.isEmpty {
            params["q"] = searchText
        }
        params["props"] = "_type.string,name"
        params["sort"] = "name.string"
        params["limit"] = "\(Self.pageLimit)"

        guard let response: EntityListResponse = try? await api.get("entity", params: params) else {
            results = []
            totalCount = nil
            return
        }

        results = response.entities.map { entity in
            ReferenceItem(
                _id: entity._id,
                name: entity.displayName,
                typeLabel: PropertyValue.localized(entity.additionalProperties?["_type"])
            )
        }
        totalCount = response.count
    }
}
