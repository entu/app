// Database picker — shown after sign-in when the user has access to multiple databases.
// Each database is a separate Entu tenant (multi-tenant model).
// Selecting one sets the active databaseId for all subsequent API calls.

import SwiftUI

/// Database picker — select a database or sign out. Used in the post-login auth flow.
struct DatabaseListView: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        VStack(spacing: 0) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.top, 48)
                .padding(.bottom, 16)

            VStack(spacing: 4) {
                Text(String(localized: "selectDatabaseTitle"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(String(localized: "selectDatabaseDescription"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(auth.databases) { database in
                        Button {
                            auth.selectDatabase(database)
                        } label: {
                            SheetRow(
                                icon: "cylinder",
                                title: database.name,
                                subtitle: database.user?.name
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 320)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            )

            Spacer()

            Button { auth.logOut() } label: {
                Text(String(localized: "signOut"))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }
}
