// Left sidebar — shows menu groups as expandable sections.
// Bottom bar shows the current user on all platforms; tapping it opens UserSheet.

import SwiftUI

/// Sidebar with menu groups and the current user bar.
struct SidebarView: View {
    @Environment(MenuModel.self) private var menu
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @Binding var selectedMenuId: String?
    let openPinnedEntity: (String) -> Void
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var showUserSheet = false
    @State private var userThumbnail: String?

    private var currentDatabase: Database? {
        auth.databases.first { $0._id == api.databaseId }
    }

    var body: some View {
        List(selection: $selectedMenuId) {
            ForEach(Array(menu.groups.enumerated()), id: \.element.id) { index, group in
                Section(isExpanded: expansionBinding(for: group.id, isFirst: index == 0)) {
                    ForEach(group.items) { item in
                        NavigationLink(value: item._id) {
                            Text(item.name)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text(group.name ?? "")
                }
            }
        }
        #if os(iOS)
        .navigationTitle("Entu")
        .navigationSubtitle(currentDatabase?.name ?? "")
        #endif
        // Bottom bar: current user
        .safeAreaBar(edge: .bottom) {
            Button {
                showUserSheet = true
            } label: {
                HStack(spacing: 10) {
                    UserAvatar(thumbnail: userThumbnail, size: 28)
                    Text(currentDatabase?.user?.name ?? String(localized: "user"))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showUserSheet) {
                UserSheet(openPinnedEntity: openPinnedEntity)
            }
        }
        .task(id: currentDatabase?.user?._id) {
            await loadUserThumbnail()
        }
    }

    /// Fetches the active database user's `_thumbnail` for the bottom bar
    /// avatar. Cleared before fetching so a stale thumbnail never bleeds across
    /// database switches.
    private func loadUserThumbnail() async {
        userThumbnail = nil
        guard let userId = currentDatabase?.user?._id else { return }

        if let response: EntityDetailResponse = try? await api.get(
            "entity/\(userId)",
            params: ["props": "_thumbnail"]
        ) {
            userThumbnail = response.entity?._thumbnail
        }
    }

    // MARK: - Expansion binding

    private func expansionBinding(for groupId: String, isFirst: Bool) -> Binding<Bool> {
        Binding(
            get: { expandedGroups[groupId] ?? isFirst },
            set: { expandedGroups[groupId] = $0 }
        )
    }
}
