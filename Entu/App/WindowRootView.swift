// Root of every window scene — owns the models that are per-window
// (navigation session, search, command palette, AI chat) so each tab or
// window navigates independently, and hosts the URL handlers and the
// public-database entry alert.

import SwiftUI

/// Per-window identity and restore bookkeeping, injected alongside the
/// per-window models so `MainView` can seed and gate on it.
@MainActor @Observable
final class WindowState {
    /// Stable identity for this window — deep-link consumption and the
    /// window-session registry key on it. Reuses the scene value's nonce,
    /// which is already unique per window and survives relaunch with it.
    let windowId: UUID

    /// What this window was opened to show — ⌘T dashboard, ⌘-click entity
    /// or menu, explicit New Window, or the default launch restore.
    let seed: TabRequest.Content

    /// True once `MainView` has applied its restore ladder — guards against
    /// re-restoring after the `.id(appLanguage)` rebuild on language change.
    var hasRestored = false

    init(request: TabRequest) {
        windowId = request.nonce
        seed = request.content
    }
}

/// Per-window state owner. App-wide services (API, auth, network, deep-link
/// router) stay in `EntuApp`; everything that makes a window's "place" —
/// `SessionState`, `SearchModel`, `CommandPaletteModel`, `AIChatModel` — is
/// created here, once per scene, so every tab is its own navigation context.
struct WindowRootView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(AuthService.self) private var authService
    @Environment(DeepLinkRouter.self) private var router
    @Environment(WindowSessionStore.self) private var windowSessions

    private let api: APIClient

    @State private var windowState: WindowState
    @State private var session = SessionState()
    @State private var search = SearchModel()
    @State private var palette = CommandPaletteModel()
    @State private var chat: AIChatModel
    @State private var showingPublicEntry = false

    /// In-app language — re-keys the content below so every
    /// `LocalizedStringKey` re-resolves on change (see `EntuApp`).
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = ""

    init(api: APIClient, request: TabRequest) {
        self.api = api
        // `@State` init-in-init only takes effect on first construction —
        // exactly right: the models must survive later re-inits of the view.
        _windowState = State(initialValue: WindowState(request: request))
        _chat = State(initialValue: AIChatModel(api: api))
    }

    var body: some View {
        ContentView()
            .publicDatabaseEntry(isPresented: $showingPublicEntry)
            // Invite deep link (`/{db}/invite?token=…`) — presented here,
            // above the auth/picker/main router, so accepting an invite
            // works in every screen state, signed out included.
            .sheet(item: pendingInviteBinding) { invite in
                AddLoginMethodSheet(
                    inviteToken: invite.token,
                    databaseId: invite.databaseId,
                    title: String(localized: "inviteTitle \(invite.databaseId)", bundle: .currentLocalized)
                ) {
                    // Accepted — the fresh token's database list includes
                    // the invited database; jump straight into it.
                    if let database = auth.databases.first(where: { $0._id == invite.databaseId }) {
                        auth.selectDatabase(database)
                    }
                }
            }
            .environment(search)
            .environment(session)
            .environment(palette)
            .environment(chat)
            .environment(windowState)
            // Re-keying forces a full rebuild on language change so every
            // `LocalizedStringKey` resolves against the active locale. The
            // per-window models live in *this* view's `@State`, above the
            // identity boundary, so they survive the rebuild;
            // `windowState.hasRestored` keeps `MainView` from re-applying a
            // saved snapshot over them.
            .id(appLanguage)
            #if os(macOS)
            .frame(minWidth: 800, minHeight: 700)
            // App Store macOS screenshot capture mode — DO NOT DELETE.
            // Swap with the `minWidth/minHeight` line above when taking
            // App Store screenshots. Apple requires a 1280×800 pt outer
            // window; macOS adds ~32pt of title-bar chrome above the
            // content view, so the content frame is 1280×768 to land the
            // window at 1280×800 (= 2560×1600 px @2x, Apple's accepted
            // screenshot size). `MainView` also adds a ~20pt toolbar row
            // that `AuthView`/`DatabaseListView` lack, so its content
            // frame is shortened by that amount to keep the outer window
            // at 1280×800 in every screen state.
            // .frame(width: 1280, height: api.databaseId != nil ? 748 : 768)
            #endif
            // Menu bar Database > Browse Public Database — published as a
            // focused scene value so the command targets the active window
            // (an app-level binding would present the alert in every window).
            .focusedSceneValue(\.browsePublicDatabase, BrowsePublicDatabaseCommand(windowId: windowState.windowId) {
                showingPublicEntry = true
            })
            .onOpenURL { url in
                handleIncoming(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    handleIncoming(url: url)
                }
            }
            // Sign-out / ⇧⌘R wipe the in-memory state every window holds —
            // chat conversation, search, navigation, palette, pending deep
            // link, scene snapshot — so nothing of the signed-out user
            // survives in RAM or scene restoration.
            .onChange(of: auth.logOutToken) {
                resetWindowState()
            }
            // User closed this tab/window — drop its saved snapshot so it
            // doesn't reopen next launch. The store ignores this during app
            // termination (quit must keep every window for restore).
            .onDisappear {
                windowSessions.remove(windowState.windowId)
            }
    }

    /// Route an incoming URL: an entity deep link is claimed for this window
    /// (see `DeepLinkRouter.handle(url:in:)`); anything else falls through
    /// to the auth-callback handler.
    private func handleIncoming(url: URL) {
        if !router.handle(url: url, in: windowState.windowId) {
            authService.handleIncoming(url: url)
        }
    }

    /// The router's pending invite, scoped to this window (the router is
    /// app-shared — only the window whose URL handler received the link
    /// presents the sheet). Dismissing consumes it.
    private var pendingInviteBinding: Binding<DeepLinkRouter.PendingInvite?> {
        Binding(
            get: {
                guard router.targetWindowId == windowState.windowId else { return nil }
                return router.pendingInvite
            },
            set: { newValue in
                guard newValue == nil else { return }

                router.pendingInvite = nil
                // Keep the router invariant "target set ⇒ something pending"
                // — but never drop a claim an entity link still holds.
                if router.pendingDatabaseId == nil {
                    router.targetWindowId = nil
                }
            }
        )
    }

    /// Reset every per-window model plus this window's stored snapshot.
    private func resetWindowState() {
        chat.reset()
        search.text = ""
        search.advancedQuery = nil
        search.showAdvanced = false
        session.clearNavigation()
        router.clear()
        palette.reset()
        windowSessions.remove(windowState.windowId)
    }
}
