// App entry point — creates the shared API client and auth state,
// then injects them into the view hierarchy via .environment().
// All child views access these shared objects through @Environment.

import SwiftUI

/// App entry point — creates shared state and injects via environment.
@main
struct EntuApp: App {
    @State private var api: APIClient
    @State private var auth: AuthModel
    @State private var authService: AuthService
    @State private var passkeyService: PasskeyService
    @State private var search = SearchModel()
    @State private var network = NetworkMonitor()
    @State private var router = DeepLinkRouter()
    @State private var showingPublicEntry = false

    /// User-selected in-app language. Drives `.environment(\.locale, ...)`
    /// below — SwiftUI APIs that take a `LocalizedStringKey` (`Text("key")`,
    /// `Button("key")`, `.alert("key", …)`, etc.) re-render automatically when
    /// this changes. The handful of pure-Swift `String` contexts (the
    /// `String(format:)` confirmation title, `EntityDetailModel.errorMessage`)
    /// read `Bundle.currentLocalized` directly when they're computed.
    /// See `AppLanguage` for the full set of helpers.
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    init() {
        Self.migrateLegacyDefaults()

        let api = APIClient()
        let auth = AuthModel(api: api)
        _api = State(initialValue: api)
        _auth = State(initialValue: auth)
        _authService = State(initialValue: AuthService(auth: auth))
        _passkeyService = State(initialValue: PasskeyService(auth: auth))
    }

    /// One-time rename of legacy UserDefaults keys to the namespaced scheme (`auth.*`, `ui.*`).
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let renames = [
            ("lastDatabaseId", "auth.lastDatabaseId"),
            ("tablePageSize", "ui.tablePageSize")
        ]
        for (old, new) in renames where defaults.object(forKey: new) == nil {
            if let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
                defaults.removeObject(forKey: old)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .publicDatabaseEntry(isPresented: $showingPublicEntry)
                .environment(api)
                .environment(auth)
                .environment(search)
                .environment(authService)
                .environment(passkeyService)
                .environment(network)
                .environment(router)
                .environment(\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))
                // SwiftUI's `Text("key")` doesn't always re-resolve when the
                // env locale changes — it caches against `Bundle.main`'s
                // preferred localization set at launch. Re-keying the root
                // view forces a full rebuild on language change so every
                // `LocalizedStringKey` resolves against the active locale.
                // Session state lives in `EntuApp` (not `ContentView`), so
                // it survives the rebuild.
                .id(appLanguage)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 700)
                #endif
                .onOpenURL { url in
                    if !router.handle(url: url) {
                        authService.handleIncoming(url: url)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        if !router.handle(url: url) {
                            authService.handleIncoming(url: url)
                        }
                    }
                }
        }
        .defaultSize(width: 1280, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Entu menu — Sign In (with providers submenu) when nothing is
            // remembered, otherwise Sign Out (which wipes both authenticated
            // credentials and the saved public-database list).
            CommandGroup(after: .appInfo) {
                if auth.isAuthenticated || !auth.publicDatabases.isEmpty {
                    Button {
                        auth.logOut()
                    } label: {
                        Label("signOut", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Menu {
                        ForEach(AuthProviderGroup.allCases, id: \.self) { group in
                            let providers = AuthProvider.allCases.filter {
                                $0.group == group && $0.isAvailableOnCurrentPlatform
                            }

                            if group != .main && !providers.isEmpty {
                                Divider()
                            }

                            ForEach(providers, id: \.self) { provider in
                                Button(provider.label) {
                                    Task {
                                        if provider == .passkey {
                                            try? await passkeyService.signIn()
                                        } else {
                                            try? await authService.signIn(with: provider)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("signIn", systemImage: "rectangle.portrait.and.arrow.forward")
                    }
                }
            }

            // Database menu — authenticated databases first, then public,
            // then a Browse-public entry. Always shown so the user can add a
            // public database from the menu bar even before signing in.
            CommandMenu("database") {
                if !auth.databases.isEmpty {
                    Section("myDatabases") {
                        ForEach(auth.databases) { database in
                            Toggle(database.name, isOn: Binding(
                                get: { database._id == api.databaseId },
                                set: { if $0 { auth.selectDatabase(database) } }
                            ))
                        }
                    }
                }

                if !auth.publicDatabases.isEmpty {
                    Section("publicDatabasesSection") {
                        ForEach(auth.publicDatabases, id: \.self) { id in
                            Toggle(id, isOn: Binding(
                                get: { id == api.databaseId },
                                set: { if $0 { auth.selectPublicDatabase(id) } }
                            ))
                        }
                    }
                }

                if auth.isAuthenticated || !auth.publicDatabases.isEmpty {
                    Divider()
                }

                Button {
                    showingPublicEntry = true
                } label: {
                    Text("browsePublicDatabaseMenu")
                }
            }
        }
    }
}
