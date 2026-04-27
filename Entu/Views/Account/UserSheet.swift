// User sheet — opened by tapping the current-user bar in the sidebar.
//
// Hero: round user avatar (or Entu logo fallback) and the user's name.
// Rows: switch active database, open the user's profile entity, switch the
// app language.
// Toolbar: close (cancellation) and Sign Out (destructive).
// Footer row: delete the user's account in the active database — required by
// App Store guideline 5.1.1(v).

import SwiftUI

/// Sheet presented when the user taps the sidebar user bar.
struct UserSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Open my profile" — pins the user entity in
    /// the main detail view. Provided by the sidebar's parent.
    let openPinnedEntity: (String) -> Void

    /// Persisted language preference. Empty = follow system.
    @AppStorage("ui.appLanguage") private var appLanguage: String = ""

    /// Snapshot of `appLanguage` taken when the sheet opens — used to show the
    /// "restart needed" hint only when the user changed it during this session.
    @State private var initialAppLanguage: String = ""

    /// Caches the user entity's `_thumbnail` URL for the active database.
    @State private var userThumbnail: String?

    /// Caches the localized label of the user entity's `_type` (e.g. "Person").
    @State private var userTypeLabel: String?

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    private var activeDatabase: Database? {
        auth.databases.first { $0._id == api.databaseId }
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
        .disabled(isDeleting)
        .overlay { if isDeleting { deletingOverlay } }
        .onAppear { initialAppLanguage = appLanguage }
        .task(id: activeDatabase?.user?._id) { await loadUserEntity() }
        .confirmationDialog(
            String(format: String(localized: "deleteAccountConfirmTitle"), activeDatabase?.name ?? ""),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "deleteAccount"), role: .destructive) {
                Task { await performDelete() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "deleteAccountMessage"))
        }
        .alert(
            String(localized: "deleteAccountFailed"),
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
        }
        ToolbarItem(placement: .destructiveAction) {
            Button(String(localized: "signOut"), role: .destructive) {
                auth.logOut()
                dismiss()
            }
            .disabled(isDeleting)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            UserAvatar(thumbnail: userThumbnail, size: 96)
                .padding(.top, 48)
                .padding(.bottom, 16)

            Text(activeDatabase?.user?.name ?? auth.user?.name ?? "")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        databaseRow

                        personEntityRow

                        languageRow

                        if appLanguage != initialAppLanguage {
                            Text(String(localized: "languageRestartNote"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                    }
                    // 16pt of empty padding sits under the top fade gradient
                    // so the first row stays fully visible at scroll origin.
                    .padding(.top, 16)

                    deleteRow
                        .padding(.vertical, 36)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 320)
            }
            .mask(scrollFadeMask)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Top + bottom fade-out gradient applied to the scrolling list of rows.
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
        }
    }

    /// Blocking spinner shown while the delete request is in flight.
    private var deletingOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rows

    /// Switches the active database. Lists every accessible database with a
    /// checkmark on the current one.
    private var databaseRow: some View {
        Menu {
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
        } label: {
            SheetRow(
                icon: "cylinder",
                title: String(localized: "database"),
                subtitle: activeDatabase?.name
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
                    title: userTypeLabel ?? String(localized: "person"),
                    subtitle: activeDatabase?.user?.name
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
                    applyLanguage(language)
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
                title: String(localized: "language"),
                subtitle: (AppLanguage(rawValue: appLanguage) ?? .system).label
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Permanently deletes the user's `person` entity in the active database.
    /// Hidden when there is no resolvable user `_id` for the active database.
    @ViewBuilder
    private var deleteRow: some View {
        if activeDatabase?.user?._id != nil {
            Button {
                showDeleteConfirmation = true
            } label: {
                Text(String(localized: "deleteAccount"))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
    }

    // MARK: - Side effects

    /// Fetches the user entity's thumbnail URL and the localized label of its
    /// type entity. Two sequential calls: first the user entity (for
    /// `_thumbnail` and `_type`), then the type entity (for `label` and `name`).
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

        guard let userResponse: EntityDetailResponse = try? await api.get(
            "entity/\(userId)",
            params: ["props": "_thumbnail,_type"]
        ) else { return }

        userThumbnail = userResponse.entity?._thumbnail
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

    /// Persists the language choice in `AppleLanguages` so `String(localized:)`
    /// picks it up on the next launch. The SwiftUI environment locale is set
    /// at app root for immediate effect on `Text(LocalizedStringKey)`.
    private func applyLanguage(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
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

// MARK: - AppLanguage

/// Available in-app language overrides. The raw value is the ISO code stored
/// in `@AppStorage("ui.appLanguage")` and `UserDefaults.AppleLanguages`.
private enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case estonian = "et"

    var id: String { rawValue }

    /// Localized display label for the language picker row and menu items.
    var label: String {
        switch self {
        case .system: return String(localized: "languageSystem")
        case .english: return String(localized: "languageEnglish")
        case .estonian: return String(localized: "languageEstonian")
        }
    }
}
