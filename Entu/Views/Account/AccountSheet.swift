// User sheet — opened by tapping the current-user bar in the sidebar.
//
// Renders identical chrome whether the active database is authenticated or
// being browsed as a guest:
//   Hero: round user avatar (or Entu logo fallback) and a title — user
//         name when signed in, database id when browsing a public database.
//   Rows: switch active database (lists authenticated and saved public
//         databases plus a "Browse public database…" entry), open the
//         user's profile entity (only when there's a resolved user), switch
//         the app language.
//   Toolbar: close (cancellation) and Sign Out (destructive — wipes
//         credentials and the saved public-database list, returning to
//         AuthView).
//   Footer row: delete the user's account in the active database — required
//         by App Store guideline 5.1.1(v); rendered as a hidden spacer in
//         public mode so the bottom fade never overlaps the language row.

import SwiftUI

/// Sheet presented when the user taps the sidebar user bar.
struct AccountSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Open my profile" — pins the user entity in
    /// the main detail view. Provided by the sidebar's parent.
    let openPinnedEntity: (String) -> Void

    /// Persisted language preference. Empty = follow system.
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    /// Caches the user entity's signed thumbnail URL for the active database.
    @State private var userThumbnail: String?

    /// Caches the localized label of the user entity's `_type` (e.g. "Person").
    @State private var userTypeLabel: String?

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showingPublicEntry = false

    /// Active authenticated database, or nil when browsing as a guest.
    private var activeDatabase: Database? {
        auth.database(for: api.databaseId)
    }

    /// Hero title — user's name when signed in, database id when browsing
    /// a public database. Keeps the sheet header non-empty in both modes.
    private var headerTitle: String {
        if let userName = activeDatabase?.user?.name ?? auth.user?.name, !userName.isEmpty {
            return userName
        }
        return api.databaseId ?? ""
    }

    /// Database-row subtitle — authenticated database name when signed in,
    /// or the bare database id when browsing as a guest.
    private var databaseRowSubtitle: Text? {
        if auth.isCurrentDatabasePublic, let id = api.databaseId {
            return Text(verbatim: id)
        }
        return (activeDatabase?.name).map { Text(verbatim: $0) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                #if os(macOS)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                #endif
        }
        // Re-scopes to the in-app language so this sheet — the one that hosts
        // the language picker — re-renders immediately when the user switches.
        .appLanguageScoped()
        .disabled(isDeleting)
        .overlay { if isDeleting { deletingOverlay } }
        .task(id: activeDatabase?.user?._id) { await loadUserEntity() }
        .confirmationDialog(
            String(format: String(localized: "deleteAccountConfirmTitle", bundle: .currentLocalized), activeDatabase?.name ?? ""),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("deleteAccount", role: .destructive) {
                Task { await performDelete() }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("deleteAccountMessage")
        }
        .alert(
            "deleteAccountFailed",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            CloseButton { dismiss() }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button("signOut", role: .destructive) {
                auth.logOut()
                dismiss()
            }
            .disabled(isDeleting)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            UserAvatar(thumbnail: userThumbnail, size: 64)
                .padding(.top, 28)
                .padding(.bottom, 10)

            VStack(spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .fontWeight(.bold)

                if let email = auth.user?.email, !email.isEmpty {
                    Text(verbatim: email)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 32)
            // 28 + the rows' 16pt fade inset = the canonical 44pt gap
            // between the profile header and the rows group.
            .padding(.bottom, 28)

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        databaseRow

                        personEntityRow

                        languageRow
                    }
                    // 16pt of empty padding sits under the top fade gradient
                    // so the first row stays fully visible at scroll origin.
                    .padding(.top, 16)

                    deleteRow
                        // Canonical 44pt gap above; 32 keeps the sheet-end
                        // breathing room below.
                        .padding(.top, 44)
                        .padding(.bottom, 32)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 360)
            }
            .scrollFadeMask()

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color("WindowBackground").ignoresSafeArea())
        .publicDatabaseEntry(isPresented: $showingPublicEntry)
    }

    /// Blocking spinner shown while the delete request is in flight.
    private var deletingOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rows

    /// Switches the active database. Lists every authenticated and public
    /// database with a checkmark on the current one, plus a final entry to
    /// add a new public database via the entry sheet.
    private var databaseRow: some View {
        Menu {
            if !auth.databases.isEmpty {
                Section("myDatabases") {
                    ForEach(auth.databases) { database in
                        Button {
                            auth.selectDatabase(database)
                        } label: {
                            if database._id == api.databaseId {
                                Label(database.name, systemImage: "checkmark")
                            } else {
                                Text(database.name)
                            }
                        }
                    }
                }
            }

            if !auth.publicDatabases.isEmpty {
                Section("publicDatabasesSection") {
                    ForEach(auth.publicDatabases, id: \.self) { id in
                        Button {
                            auth.selectPublicDatabase(id)
                        } label: {
                            if id == api.databaseId {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                showingPublicEntry = true
            } label: {
                Text("browsePublicDatabaseMenu")
            }
        } label: {
            SheetRow(
                icon: "cylinder",
                title: Text("database"),
                subtitle: databaseRowSubtitle
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Pins the signed-in user's person entity in the main detail view.
    @ViewBuilder
    private var personEntityRow: some View {
        if let userId = activeDatabase?.user?._id {
            Button {
                openPinnedEntity(userId)
                dismiss()
            } label: {
                SheetRow(
                    icon: "person.crop.circle",
                    title: userTypeLabel.map { Text(verbatim: $0) } ?? Text("person"),
                    subtitle: (activeDatabase?.user?.name).map { Text(verbatim: $0) }
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// In-app language override (System / English / Estonian).
    private var languageRow: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    appLanguage = language.rawValue
                } label: {
                    if appLanguage == language.rawValue {
                        Label(language.label, systemImage: "checkmark")
                    } else {
                        Text(language.label)
                    }
                }
            }
        } label: {
            SheetRow(
                icon: "globe",
                title: Text("language"),
                subtitle: Text((AppLanguage(rawValue: appLanguage) ?? .system).label)
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Permanently deletes the user's `person` entity in the active database.
    /// Hidden when there is no resolvable user `_id` for the active database —
    /// rendered as an invisible spacer so the bottom fade gradient never
    /// overlaps the language row.
    @ViewBuilder
    private var deleteRow: some View {
        if activeDatabase?.user?._id != nil {
            Button {
                showDeleteConfirmation = true
            } label: {
                Text("deleteAccount")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        } else {
            Text("deleteAccount")
                .font(.caption)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: - Side effects

    /// Fetches the user entity's thumbnail URL and the localized label of its
    /// type entity. Two sequential calls: first the user entity (for
    /// `photo` and `_type`), then the type entity (for `label` and `name`).
    ///
    /// Resolution order for `userTypeLabel`:
    ///   1. type entity's `label` (preferred, localized human label)
    ///   2. type entity's `name` (e.g. "person")
    ///   3. user entity's inlined `_type[0].string` (set up-front so any
    ///      later failure path keeps a fallback in place)
    ///
    /// Resets both caches to nil first so stale values never bleed across
    /// database switches.
    private func loadUserEntity() async {
        userThumbnail = nil
        userTypeLabel = nil
        guard let userId = activeDatabase?.user?._id else { return }

        // No photo pre-check — the thumbnail endpoint returns nothing for
        // photo-less entities.
        userThumbnail = await api.entityThumbnailURL(entityId: userId, size: 200)?.absoluteString

        guard let userResponse: EntityDetailResponse = try? await api.get(
            "entity/\(userId)",
            params: ["props": "_type"]
        ) else { return }

        // Apply the inlined fallback first — any later failure leaves it in place.
        userTypeLabel = userResponse.entity?.typeName

        guard let typeId = userResponse.entity?.typeId else { return }

        guard let typeResponse: EntityDetailResponse = try? await api.get(
            "entity/\(typeId)",
            params: ["props": "label,name"]
        ) else { return }

        if let label = PropertyValue.localized(typeResponse.entity?.properties["label"]) {
            userTypeLabel = label
        } else if let name = PropertyValue.localized(typeResponse.entity?.properties["name"]) {
            userTypeLabel = name
        }
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await auth.deleteCurrentAccount()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
