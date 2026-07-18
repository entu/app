// Sidebar — menu groups as expandable sections. macOS/iPad add a bottom
// bar with the user pill and the Entu AI button; iPhone draws the design's
// header (database name, user name, avatar button) in the list content
// and keeps only a prominent AI capsule at the bottom.

import SwiftUI

/// Sidebar with menu groups as expandable sections and a bottom row holding
/// the user pill (opens `AccountSheet`) and the Entu AI button.
struct SidebarView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(MenuModel.self) private var menu
    @Environment(AIChatModel.self) private var chat

    @Binding var selectedMenuId: String?
    let openPinnedEntity: (String) -> Void
    @State private var showAccountSheet = false
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

    #if os(iOS)
    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif


    var body: some View {
        List(selection: $selectedMenuId) {
            #if os(iOS)
            // iPhone: the design's header (24a) lives in the content — the
            // nav bar stays inline with just the toggle. (A real large
            // title gets stuck collapsed after popping back from the list
            // column.) iPad mirrors macOS: no header, bottom user pill.
            if isPhone {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: currentDatabase?.name ?? "Entu")
                            .font(.largeTitle.bold())

                        if let userName = currentDatabase?.user?.name {
                            Text(verbatim: userName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    userPill
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            }
            #endif

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
        // The header lives in the list content (see above) — keep the nav
        // bar empty and pull the content up under it.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.top, 0, for: .scrollContent)
        #endif
        // Bottom bar. macOS + iPad: compact user pill + AI side by side.
        // iPhone: only the prominent AI capsule, trailing (24a) — the user
        // lives in the header.
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 8) {
                #if os(macOS)
                userPill
                #else
                if isPhone {
                    Spacer(minLength: 0)
                } else {
                    userPill
                }
                #endif

                // Entu AI entry point — gated on a signed-in user (hidden in
                // public-database mode, matching the webapp) and hidden while
                // the chat panel is open to avoid redundancy.
                if auth.currentUserId != nil && !chat.isOpen {
                    aiButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet(openPinnedEntity: openPinnedEntity)
                .blocksCommandPalette()
        }
        .task(id: currentDatabase?.user?._id) {
            await loadUserThumbnail()
        }
    }

    /// Opens the account sheet. macOS + iPad: bottom glass pill with the
    /// user's name and database id. iPhone: avatar-only button in the
    /// content header.
    private var userPill: some View {
        #if os(macOS)
        fullUserPill
        #else
        Group {
            if isPhone {
                avatarButton
            } else {
                fullUserPill
            }
        }
        #endif
    }

    /// Avatar + name + database id in a glass capsule (macOS, iPad).
    private var fullUserPill: some View {
        Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 8) {
                UserAvatar(thumbnail: userThumbnail, size: 26, fallback: .personIcon)

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
    }

    #if os(iOS)
    /// Round thumbnail-only button (iPhone header). AsyncImage, not a
    /// `.task`-loading avatar — task modifiers in bar contexts don't
    /// reliably fire on iOS.
    private var avatarButton: some View {
        Button {
            showAccountSheet = true
        } label: {
            AsyncImage(url: userThumbnail.flatMap { URL(string: $0) }) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Circle()
                    .fill(.fill.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(.separator, lineWidth: 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("user")
    }
    #endif

    /// AI purple — same identity color as the chat's sparkle icons
    /// (design's #5856d6 ≈ system indigo). Prominent 24a capsule on touch
    /// platforms, the compact pill on macOS.
    private var aiButton: some View {
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
            .font(pillFont)
            .foregroundStyle(.white)
            .padding(.horizontal, aiHorizontalPadding)
            // Same content height + uniform inset as the user
            // pill beside it, so the two pills match exactly.
            .frame(height: pillContentHeight)
            .padding(4)
            // Never truncate the label — the user pill beside it
            // is the one that compresses in a narrow sidebar.
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.indigo).interactive(), in: Capsule())
    }

    /// AI-pill metrics — the design's prominent 24a sizing on iPhone,
    /// the compact pill on macOS and iPad.
    private var pillContentHeight: CGFloat {
        #if os(macOS)
        26
        #else
        isPhone ? 40 : 26
        #endif
    }

    private var pillFont: Font {
        #if os(macOS)
        .caption.weight(.semibold)
        #else
        isPhone ? .subheadline.weight(.semibold) : .caption.weight(.semibold)
        #endif
    }

    private var aiHorizontalPadding: CGFloat {
        #if os(macOS)
        8
        #else
        isPhone ? 16 : 8
        #endif
    }

    /// Resolves the active database user's thumbnail for the bottom bar
    /// avatar. Cleared before fetching so a stale thumbnail never bleeds across
    /// database switches.
    private func loadUserThumbnail() async {
        userThumbnail = nil
        guard let userId = currentDatabase?.user?._id else { return }

        // No photo pre-check — the thumbnail endpoint itself returns
        // nothing for photo-less entities, and a `props=photo` probe
        // false-negatives on slim payloads.
        // Small bar-button avatar — the 50px thumbnail is plenty.
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
