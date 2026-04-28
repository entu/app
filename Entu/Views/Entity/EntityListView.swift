// Scrollable entity list with search and infinite scroll.
// Receives a query string from the selected menu item and fetches
// matching entities from the API, converting them to EntityListItem.

import SwiftUI

/// Scrollable entity list with search, infinite scroll, and pull-to-refresh.
struct EntityListView: View {
    @Environment(APIClient.self) private var api
    @Environment(SearchModel.self) private var search
    let query: String

    // Selection binding — drives the detail column in NavigationSplitView.
    @Binding var selectedEntityId: String?

    @State private var items: [EntityListItem] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var pageSize = 50
    @State private var searchDebounceTask: Task<Void, Never>?

    private var hasMore: Bool { items.count < totalCount }

    var body: some View {
        List(selection: $selectedEntityId) {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    EntityAvatar(name: item.name, thumbnail: item.thumbnail)
                    Text(item.name).lineLimit(1)
                }
                .tag(item._id)
                .onAppear {
                    if item.id == items.last?.id && hasMore && !isLoadingMore {
                        Task { await loadMore() }
                    }
                }
            }

            if isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if !hasMore && totalCount > 0 {
                Text("\(totalCount)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .clipped()
        .refreshable { await loadEntities() }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if !isLoading && items.isEmpty {
                ContentUnavailableView {
                    Label("noResults", systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: query) {
            items = []
            totalCount = 0
            await loadEntities()
        }
        .onChange(of: search.text) {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                items = []
                totalCount = 0
                await loadEntities()
            }
        }
    }

    // MARK: - Data loading

    /// Fetch the first page of entities from the API.
    private func loadEntities() async {
        isLoading = true
        var params = parseQuery(query)
        params["props"] = "_thumbnail,name"
        params["limit"] = String(pageSize)
        params["skip"] = "0"
        if !search.text.isEmpty { params["q"] = search.text }

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            items = response.entities.map { EntityListItem(from: $0) }
            totalCount = response.count ?? 0
        }
        isLoading = false
    }

    /// Fetch the next page of entities (infinite scroll).
    private func loadMore() async {
        isLoadingMore = true
        var params = parseQuery(query)
        params["props"] = "_thumbnail,name"
        params["limit"] = String(pageSize)
        params["skip"] = String(items.count)
        if !search.text.isEmpty { params["q"] = search.text }

        if let response: EntityListResponse = try? await api.get("entity", params: params) {
            items.append(contentsOf: response.entities.map { EntityListItem(from: $0) })
            totalCount = response.count ?? totalCount
        }
        isLoadingMore = false
    }

    // MARK: - Search + pagination

    /// Convert a "key1=val1&key2=val2" URL query string to a dictionary.
    private func parseQuery(_ query: String) -> [String: String] {
        var params: [String: String] = [:]
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[String(kv[0])] = String(kv[1]) }
        }
        return params
    }
}
