// Database picker — shown after sign-in when the user has access to multiple databases,
// or as a sheet when switching databases from the sidebar.
// Each database is a separate Entu tenant (multi-tenant model).
// Selecting one sets the active databaseId for all subsequent API calls.

import SwiftUI

/// Database picker — select a database or sign out. Used in auth flow and as sheet.
struct DatabaseListView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    var showCloseButton = false

    var body: some View {
        // MARK: - Sheet vs full-screen wrapper

        if showCloseButton {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { dismiss() }
                        }
                    }
            }
        } else {
            content
        }
    }

    // MARK: - Shared content

    private var content: some View {
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
                                if showCloseButton { dismiss() }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cylinder").frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(database.name).fontWeight(.medium)

                                        if let userName = database.user?.name {
                                            Text(userName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(.fill.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
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

                if !showCloseButton {
                    Button { auth.logOut() } label: {
                        Text(String(localized: "signOut"))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .toolbar {
                if showCloseButton {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(String(localized: "signOut"), role: .destructive) {
                            auth.logOut()
                        }
                    }
                }
            }
            #if os(macOS)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            #endif
    }
}
