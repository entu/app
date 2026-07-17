// Root router — shows sign-in, the database picker, or the main split
// view depending on auth state, and owns the transitions between them.

import SwiftUI

/// Root router — picks between auth, database picker, or main view based on state.
/// 1. A database is active → `MainView`.
/// 2. At least one database known → `DatabaseListView` (or auto-select if only one).
/// 3. Nothing known and not signed in → `AuthView`.
struct ContentView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(NetworkMonitor.self) private var network
    @Environment(SearchModel.self) private var search
    @Environment(SessionState.self) private var session
    @Environment(AIChatModel.self) private var chat
    @Environment(DeepLinkRouter.self) private var router

    /// Total number of selectable databases (authenticated + saved public).
    private var totalDatabaseCount: Int {
        auth.databases.count + auth.publicDatabases.count
    }

    /// True when there's at least one entry to pick — either authenticated or
    /// a remembered public database.
    private var hasAnyDatabase: Bool {
        auth.isAuthenticated || !auth.publicDatabases.isEmpty
    }

    // Determines which screen state we're in for animation transitions.
    private var screenState: String {
        if api.databaseId != nil { return "main" }
        if hasAnyDatabase { return "dbSelect" }
        return "auth"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if api.databaseId != nil {
                    MainView()
                        .transition(.opacity)
                } else if hasAnyDatabase {
                    if totalDatabaseCount == 1 {
                        ProgressView()
                            .onAppear { autoSelectSoleDatabase() }
                    } else {
                        DatabaseListView()
                            .transition(.opacity)
                    }
                } else {
                    AuthView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: screenState)

            if !network.isOnline {
                OfflineBanner()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: network.isOnline)
        .onAppear {
            // Logout wipes the in-memory session state these models hold —
            // chat conversation, search text/query, navigation, pending deep
            // link — so nothing of the signed-out user survives in RAM.
            auth.onLogOut = { [weak search, weak session, weak chat, weak router] in
                chat?.reset()
                search?.text = ""
                search?.advancedQuery = nil
                search?.showAdvanced = false
                session?.clearNavigation()
                router?.clear()
            }
        }
    }

    /// Selects the only available database (authenticated first, public otherwise).
    private func autoSelectSoleDatabase() {
        if let database = auth.databases.first {
            auth.selectDatabase(database)
        } else if let publicId = auth.publicDatabases.first {
            auth.selectPublicDatabase(publicId)
        }
    }
}
