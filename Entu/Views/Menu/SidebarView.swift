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
    @State private var showUserSheet = false
    @State private var userThumbnail: String?

    /// Ids of expanded groups. Seeded once when groups first arrive
    /// (first group expanded, rest collapsed). Stored as a `Set` so
    /// each section's binding only writes its own id; SwiftUI's
    /// `Section(isExpanded:)` setter never overwrites another
    /// section's state via a shared default fallback.
    @State private var expandedGroupIds: Set<String> = []
    @State private var didSeedExpansion = false

    private var currentDatabase: Database? {
        auth.databases.first { $0._id == api.databaseId }
    }

    var body: some View {
        List(selection: $selectedMenuId) {
            ForEach(menu.groups) { group in
                Section(isExpanded: expansionBinding(for: group.id)) {
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
        .listStyle(.sidebar)
        .onAppear {
            seedExpansionIfNeeded()
        }
        .onChange(of: menu.groups.count) { _, _ in
            seedExpansionIfNeeded()
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
                    ((currentDatabase?.user?.name).map { Text(verbatim: $0) } ?? Text("user"))
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

    // MARK: - Expansion seed + binding

    /// Seeds `expandedGroupIds` to contain only the first group the
    /// first time menu groups are available. Called both from
    /// `.onAppear` and on `menu.groups.count` change so it runs
    /// regardless of whether groups arrive before or after the view
    /// first appears.
    private func seedExpansionIfNeeded() {
        guard !didSeedExpansion, let first = menu.groups.first else { return }
        expandedGroupIds = [first.id]
        didSeedExpansion = true
    }

    private func expansionBinding(for groupId: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroupIds.contains(groupId) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroupIds.insert(groupId)
                } else {
                    expandedGroupIds.remove(groupId)
                }
            }
        )
    }
}
