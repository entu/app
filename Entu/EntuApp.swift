// App entry point — creates the shared API client and auth state,
// then injects them into the view hierarchy via .environment().
// All child views access these shared objects through @Environment.

import SwiftUI

/// App entry point — creates shared state and injects via environment.
@main
struct EntuApp: App {
    @State private var api = APIClient()
    @State private var auth: AuthModel
    @State private var authService: AuthService?
    @State private var search = SearchModel()

    init() {
        Self.migrateLegacyDefaults()
        let api = APIClient()
        _api = State(initialValue: api)
        _auth = State(initialValue: AuthModel(api: api))
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
                .environment(api)
                .environment(auth)
                .environment(search)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 700)
                #endif
                .onAppear {
                    if authService == nil {
                        authService = AuthService(auth: auth)
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Entu menu — Sign In (with providers submenu) or Sign Out
            CommandGroup(after: .appInfo) {
                if auth.isAuthenticated {
                    Button {
                        auth.logOut()
                    } label: {
                        Label(String(localized: "signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Menu {
                        ForEach(AuthProviderGroup.allCases, id: \.self) { group in
                            let providers = AuthProvider.allCases.filter { $0.group == group && $0.isEnabled }

                            if group != .main && !providers.isEmpty {
                                Divider()
                            }

                            ForEach(providers, id: \.self) { provider in
                                Button(provider.label) {
                                    Task {
                                        try? await authService?.signIn(with: provider)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(String(localized: "signIn"), systemImage: "rectangle.portrait.and.arrow.forward")
                    }
                }
            }

            // Database menu — only visible when signed in
            if auth.isAuthenticated {
                CommandMenu(String(localized: "database")) {
                    ForEach(auth.databases) { database in
                        Toggle(database.name, isOn: Binding(
                            get: { database._id == api.databaseId },
                            set: { if $0 { auth.selectDatabase(database) } }
                        ))
                    }
                }
            }
        }
    }
}
