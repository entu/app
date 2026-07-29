// App entry point — creates the app-wide services once (API client, auth,
// network, deep-link router, window-session store), injects them into the
// environment, and hosts the main window group with its menu-bar commands.
// Per-window state (navigation, search, palette, chat) lives in
// `WindowRootView` so every window/tab navigates independently.

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// App entry point — creates shared state and injects via environment.
@main
struct EntuApp: App {
    @State private var api: APIClient
    @State private var auth: AuthModel
    @State private var authService: AuthService
    @State private var passkeyService: PasskeyService
    @State private var network = NetworkMonitor()
    @State private var router = DeepLinkRouter()
    @State private var windowSessions = WindowSessionStore()

    /// User-selected in-app language. Drives `.environment(\.locale, ...)`
    /// below — SwiftUI APIs that take a `LocalizedStringKey` (`Text("key")`,
    /// `Button("key")`, `.alert("key", …)`, etc.) re-render automatically when
    /// this changes. The handful of pure-Swift `String` contexts (the
    /// `String(format:)` confirmation title, `EntityDetailModel.errorMessage`)
    /// read `Bundle.currentLocalized` directly when they're computed.
    /// See `AppLanguage` for the full set of helpers.
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    init() {
        #if os(macOS)
        // Let macOS tab new windows automatically — ⌘T / ⌘-click open a new
        // window and the system tabs it next to the current one (per the
        // user's "Prefer tabs" setting). No manual tab attaching.
        NSWindow.allowsAutomaticWindowTabbing = true
        #endif
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

    /// The app-wide services every window scene injects — one list shared
    /// by the main and entity WindowGroups, so a new service can't be added
    /// to one scene and forgotten on the other (`@Environment(T.self)`
    /// traps at runtime when a value is missing). `windowSessions` is
    /// main-window-only and injected at its call site.
    private func withAppServices(_ content: some View) -> some View {
        content
            .environment(api)
            .environment(auth)
            .environment(authService)
            .environment(passkeyService)
            .environment(network)
            .environment(router)
            .environment(\.locale, appLanguage.isEmpty ? .current : Locale(identifier: appLanguage))
    }

    var body: some Scene {
        WindowGroup(id: "main", for: TabRequest.self) { $request in
            withAppServices(
                WindowRootView(api: api, request: request)
                    .environment(windowSessions)
            )
        } defaultValue: {
            TabRequest()
        }
        .defaultSize(width: 1280, height: 850)
        // App Store screenshot capture mode — uncomment together with the
        // `.frame(width: 1280, height: 768)` in `WindowRootView` to lock the
        // window to the fixed content size (otherwise the window resizes and
        // leaves margins around the fixed content). Comment both out to ship.
        // .windowResizability(.contentSize)
        .commands {
            // File > New — ⌘N creates an entity (the app's primary object),
            // ⌃⌘N adds a child. `.newItem` is *replaced* (not left default)
            // so ⌘N is the entity action; New Window moves to ⇧⌘N inside the
            // same group, keeping the window-reopen affordance App Review
            // requires. ⌘T opens a new tab on the dashboard (macOS).
            // See `NewEntityCommands`.
            NewEntityCommands()

            // Entu menu — Sign In (with providers submenu) when nothing is
            // remembered, otherwise Sign Out (which wipes both authenticated
            // credentials and the saved public-database list).
            //
            // Menu-bar strings resolve against the system language (plain
            // `String(localized:)`, not `.currentLocalized`) — the OS has no
            // Estonian localization, so following the in-app language toggle
            // would leave a mixed-language menu bar.
            CommandGroup(after: .appInfo) {
                if auth.isAuthenticated || !auth.publicDatabases.isEmpty {
                    Button {
                        auth.logOut()
                    } label: {
                        Label(String(localized: "signOut"), systemImage: "rectangle.portrait.and.arrow.right")
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
                                Button(provider.menuLabel) {
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

            // Database menu — see `DatabaseCommands` (extracted so the
            // Browse-public entry can target the active window through a
            // focused scene value).
            DatabaseCommands(auth: auth, api: api)

            // View > Command Palette (⌘K) — driven by the focused scene
            // value `MainView` publishes; a no-op outside the main view.
            PaletteCommands()

            // View > as List / as Table (⌘1/⌘2) — main-results view mode.
            ViewToggleCommands()

            // App menu > Settings… (⌘,) — opens the account sheet.
            AccountCommands()

            // Edit > Search (⌘F) — focuses the toolbar search field.
            SearchFieldCommands()

            // Entity menu — actions for the entity shown in the detail
            // column, published via the `entityActions` focused value.
            EntityCommands()

            // View > Reload Entity (⌘R) / Clear Cache (⇧⌘R).
            ReloadCommands()
        }

        // Auxiliary entity windows — one entity per window, Mail-style
        // (HIG: an auxiliary window "presents a specific area… dedicated
        // to one experience"). Value = entity id; opening an already-open
        // entity fronts its window instead of duplicating it. A separate
        // WindowGroup gets its own tabbing identifier, so entity windows
        // tab together — never with main windows — per the user's system
        // "Prefer tabs" setting.
        WindowGroup(id: EntityWindowRootView.windowID, for: String.self) { $entityId in
            if let entityId {
                withAppServices(EntityWindowRootView(api: api, entityId: entityId))
            }
        }
        .defaultSize(width: 760, height: 900)
    }
}
