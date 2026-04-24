// Left sidebar — shows menu groups as expandable sections.
// Clicking the db icon opens a popover to switch databases.
// Bottom bar shows the current user on all platforms.

import SwiftUI

/// Sidebar with menu groups, database picker, and current user bar.
struct SidebarView: View {
    @Environment(MenuModel.self) private var menu
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api

    @Binding var selectedMenuId: String?
    let openPinnedEntity: (String) -> Void
    @State private var expandedGroups: [String: Bool] = [:]
    @State private var showDbPicker = false

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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showDbPicker.toggle()
                } label: {
                    Image(systemName: "cylinder.split.1x2")
                }
                .accessibilityLabel(String(localized: "database"))
                .sheet(isPresented: $showDbPicker) {
                    DatabaseListView(showCloseButton: true)
                }
            }
        }
        #endif
        // Bottom bar: current user
        .safeAreaBar(edge: .bottom) {
            Button {
                if let userId = currentDatabase?.user?._id {
                    openPinnedEntity(userId)
                }
            } label: {
                HStack(spacing: 10) {
                    EntityAvatar(name: currentDatabase?.user?.name ?? "", thumbnail: nil)
                    Text(currentDatabase?.user?.name ?? String(localized: "user"))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
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
