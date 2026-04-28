// Root view — decides which screen to show based on auth state:
//   1. Not signed in        → AuthView (sign-in screen)
//   2. Signed in, DB chosen → MainView (sidebar + content)
//   3. Single database      → auto-select it and go to MainView
//   4. Multiple databases   → DatabaseListView (picker)

import SwiftUI

/// Root router — shows auth, database picker, or main view based on state.
struct ContentView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(APIClient.self) private var api
    @Environment(NetworkMonitor.self) private var network

    // Determines which screen state we're in for animation transitions.
    private var screenState: String {
        if !auth.isAuthenticated { return "auth" }
        if api.databaseId != nil { return "main" }
        return "dbSelect"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if !auth.isAuthenticated {
                    AuthView()
                        .transition(.opacity)
                } else if api.databaseId != nil {
                    MainView()
                        .transition(.opacity)
                } else if auth.databases.count == 1 {
                    ProgressView()
                        .onAppear {
                            if let database = auth.databases.first {
                                auth.selectDatabase(database)
                            }
                        }
                } else {
                    DatabaseListView()
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
    }
}
