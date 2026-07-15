import SwiftUI

/// Sidebar with menu groups as expandable sections and a bottom row holding
/// the user pill (opens `UserSheet`) and the Entu AI button.
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
        // Bottom row: user pill (name + database) and the Entu AI button
        // side by side. Both are Liquid Glass pills floating over the list.
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    showUserSheet = true
                } label: {
                    HStack(spacing: 8) {
                        UserAvatar(thumbnail: userThumbnail, size: 26)

                        VStack(alignment: .leading, spacing: 0) {
                            ((currentDatabase?.user?.name).map { Text(verbatim: $0) } ?? Text("user"))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            if let databaseId = api.databaseId {
                                Text(verbatim: databaseId)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    // Uniform 4pt inset — the avatar sits as close to the
                    // pill's left edge as to its top and bottom. A glass
                    // *effect* instead of the glass button style, whose own
                    // content padding would widen the leading gap.
                    .padding(4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .sheet(isPresented: $showUserSheet) {
                    UserSheet(openPinnedEntity: openPinnedEntity)
                }

                // Entu AI entry point — gated on a signed-in user (hidden in
                // public-database mode, matching the webapp) and hidden while
                // the chat panel is open to avoid redundancy. Accent-tinted
                // glass per the design's AI pill.
                if auth.currentUserId != nil && !chat.isOpen {
                    Button {
                        chat.isOpen = true
                    } label: {
                        Label {
                            Text("aiButton")
                                .textCase(.uppercase)
                                .kerning(0.5)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .tint(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
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

        // Small 26pt bottom-bar avatar — the 50px thumbnail is plenty.
        userThumbnail = await api.entityThumbnailURL(entityId: userId, size: 50)?.absoluteString
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
