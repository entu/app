// Database picker — shown when the user has access to more than one
// database (any combination of authenticated tenants and saved public
// databases) and none is currently active. Selecting a row sets the
// active databaseId for all subsequent API calls; the entry below the
// list opens the "Browse public database" alert to add another.

import SwiftUI

/// Database picker — select a database or sign out. Used in the post-login auth flow.
struct DatabaseListView: View {
    @Environment(AuthModel.self) private var auth
    @State private var showingPublicEntry = false

    var body: some View {
        VStack(spacing: 0) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.top, 48)
                .padding(.bottom, 16)

            VStack(spacing: 4) {
                Text("selectDatabaseTitle")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("selectDatabaseDescription")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 36) {
                        if !auth.databases.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(auth.databases) { database in
                                    Button {
                                        auth.selectDatabase(database)
                                    } label: {
                                        SheetRow(
                                            icon: "cylinder",
                                            title: Text(verbatim: database.name),
                                            subtitle: (database.user?.name).map { Text(verbatim: $0) }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !auth.publicDatabases.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("publicDatabasesSection")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 12) {
                                    ForEach(auth.publicDatabases, id: \.self) { id in
                                        Button {
                                            auth.selectPublicDatabase(id)
                                        } label: {
                                            SheetRow(
                                                icon: "globe",
                                                title: Text(verbatim: id),
                                                subtitle: Text("viewingAsGuest")
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    VStack(spacing: 20) {
                        OrSeparator()
                        BrowsePublicDatabaseButton {
                            showingPublicEntry = true
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 320)
            }
            .scrollFadeMask()

            Spacer()

            Button { auth.logOut() } label: {
                Text("signOut")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .publicDatabaseEntry(isPresented: $showingPublicEntry)
    }
}
