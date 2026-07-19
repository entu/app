// Sidebar — menu groups as expandable sections. iPhone/iPad show the
// database name as the native large title with the user name as subtitle,
// the avatar button in the nav bar and the AI button in the native bottom
// toolbar (native equivalent of the design's in-content header + pills,
// 24a); macOS keeps a bottom bar with the user pill and the AI pill.

import SwiftUI

/// Sidebar with menu groups as expandable sections plus the account and
/// Entu AI entry points — nav bar + bottom toolbar on iOS, bottom pill
/// bar on macOS.
struct SidebarView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(MenuModel.self) private var menu
    @Environment(AIChatModel.self) private var chat

    @Binding var selectedMenuId: String?
    let openPinnedEntity: (String) -> Void
    @State private var showAccountSheet = false


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
        Group {
            #if os(iOS)
            // iPhone + iPad: native large title + subtitle + nav-bar
            // avatar instead of the design's in-content header / user
            // pill (24a) — the native construction, per HIG. The AI
            // entry point sits in the native bottom toolbar, matching
            // the list column's filter / search / New.
            menuList
                .navigationTitle(currentDatabase?.name ?? "Entu")
                .navigationSubtitle(currentDatabase?.user?.name ?? "")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        avatarButton
                    }

                    // Entu AI entry point — gated on a signed-in user
                    // (hidden in public-database mode, matching the
                    // webapp) and hidden while the chat panel is open
                    // to avoid redundancy. Flexible spacer pushes it
                    // to the trailing edge, Mail-compose-style.
                    if auth.currentUserId != nil && !chat.isOpen {
                        ToolbarSpacer(.flexible, placement: .bottomBar)

                        ToolbarItem(placement: .bottomBar) {
                            aiToolbarButton
                        }
                    }
                }
            #else
            // macOS: bottom bar with the user pill + AI pill.
            menuList
                .safeAreaBar(edge: .bottom) { bottomBar }
            #endif
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet(openPinnedEntity: openPinnedEntity)
                .blocksCommandPalette()
        }
    }

    /// The menu list itself — shared by the iOS (nav title + toolbars)
    /// and macOS (bottom pill bar) branches of `body`.
    private var menuList: some View {
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
    }

    #if os(macOS)
    /// Bottom bar (macOS): compact user pill + AI pill side by side.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            fullUserPill

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

    /// Opens the account sheet — person icon + name + database id in a
    /// glass capsule (macOS bottom bar).
    private var fullUserPill: some View {
        Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.secondary)

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
    #endif

    #if os(iOS)
    /// Account button (iPhone + iPad nav bar) — the standard person
    /// symbol; the toolbar supplies sizing and glass treatment.
    private var avatarButton: some View {
        Button {
            showAccountSheet = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("user")
    }

    /// AI entry point as a standard bottom-toolbar button (iPhone +
    /// iPad) — built exactly like the nav-bar avatar button: plain
    /// button, system-drawn chrome. The only addition is the tint,
    /// which colors the sparkles icon in the AI purple (design's
    /// #5856d6 ≈ system indigo; toolbar icons color via `.tint`, not
    /// `foregroundStyle`). Prominent styles are avoided deliberately —
    /// they lose their tint on iPad and render white-on-white (see the
    /// iPadOS 26 toolbar quirks note in CLAUDE-APP.md).
    private var aiToolbarButton: some View {
        Button {
            chat.isOpen = true
        } label: {
            Label("aiButton", systemImage: "sparkles")
        }
        .tint(.indigo)
    }
    #endif

    #if os(macOS)
    /// AI purple — same identity color as the chat's sparkle icons
    /// (design's #5856d6 ≈ system indigo). Compact glass pill beside the
    /// user pill (macOS).
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            // Same content height + uniform inset as the user
            // pill beside it, so the two pills match exactly.
            .frame(height: 26)
            .padding(4)
            // Never truncate the label — the user pill beside it
            // is the one that compresses in a narrow sidebar.
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.indigo).interactive(), in: Capsule())
    }
    #endif

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
