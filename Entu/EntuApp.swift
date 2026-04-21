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
                .environment(api)
                .environment(auth)
                .environment(search)
                .environment(authService)
                .environment(passkeyService)
                #if os(macOS)
                .frame(minWidth: 800, minHeight: 700)
                #endif
                .onOpenURL { url in
                    authService.handleIncoming(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        authService.handleIncoming(url: url)
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
                            let providers = AuthProvider.allCases.filter { $0.group == group }

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
