import SwiftUI

/// Sidebar with menu groups as expandable sections and a bottom user
/// bar that opens `UserSheet` on tap.
struct SidebarView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(MenuModel.self) private var menu
    @Environment(AIChatModel.self) private var chat

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
        // Bottom bar: current user (above) + Entu AI entry point (below).
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
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

                // Global Entu AI entry point — gated on a signed-in user
                // (hidden in public-database mode, matching the webapp).
                // Hidden while the chat inspector is open to avoid redundancy.
                if auth.currentUserId != nil && !chat.isOpen {
                    Button {
                        chat.isOpen = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("entuAi")
                                .lineLimit(1)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.entuBrand)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                }
            }
        }
        .task(id: currentDatabase?.user?._id) {
            await loadUserThumbnail()
        }
    }

    /// Resolves the active database user's thumbnail for the bottom bar
    /// avatar. Cleared before fetching so a stale thumbnail never bleeds across
    /// database switches.
    private func loadUserThumbnail() async {
        userThumbnail = nil
        guard let userId = currentDatabase?.user?._id else { return }

        guard let response: EntityDetailResponse = try? await api.get(
            "entity/\(userId)",
            params: ["props": "photo"]
        ), response.entity?.hasPhoto == true else { return }

        userThumbnail = await api.entityThumbnailURL(entityId: userId, size: 200)?.absoluteString
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
