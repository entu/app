// Root of every window scene — owns the models that are per-window
// (navigation session, search, command palette, AI chat) so each tab or
// window navigates independently, and hosts the URL handlers, the
// public-database entry alert, and (macOS) the window accessor that labels
// the native tab.

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Per-window identity and restore bookkeeping, injected alongside the
/// per-window models so `MainView` can seed and gate on it.
@MainActor @Observable
final class WindowState {
    /// Stable identity for this window — deep-link consumption is gated on
    /// it so a link opens in exactly one window.
    let windowId = UUID()

    /// What this window was opened to show — ⌘T dashboard, ⌘-click entity,
    /// or the default session restore.
    let seed: TabRequest.Content

    /// True once `MainView` has applied its restore ladder — guards against
    /// re-restoring after the `.id(appLanguage)` rebuild on language change.
    var hasRestored = false

    #if os(macOS)
    /// The hosting `NSWindow`, filled by `WindowRootView`'s accessor once the
    /// scene is installed. Used only to label the native tab (the redesign
    /// window keeps `window.title` empty, so the tab has no name unless we
    /// set `tab.title` directly). Not observed — imperative AppKit sink.
    @ObservationIgnored weak var macWindow: NSWindow? {
        didSet { macWindow?.tab.title = tabTitle }
    }

    /// Current native-tab label. `MainView` writes the entity name (or the
    /// database name on the dashboard) here; it's mirrored to the window's
    /// tab whether the window is set before or after the title.
    @ObservationIgnored var tabTitle: String = "" {
        didSet { macWindow?.tab.title = tabTitle }
    }
    #endif

    init(seed: TabRequest.Content) {
        self.seed = seed
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

    /// The seed this scene was opened with (also system-restored on relaunch).
    let request: TabRequest

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
        self.request = request
        // `@State` init-in-init only takes effect on first construction —
        // exactly right: the models must survive later re-inits of the view.
        _windowState = State(initialValue: WindowState(seed: request.content))
        _chat = State(initialValue: AIChatModel(api: api))
    }

    var body: some View {
        ContentView()
            .publicDatabaseEntry(isPresented: $showingPublicEntry)
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
            .background {
                // Hands this scene's NSWindow to `WindowState` so `MainView`
                // can label the native tab. Tab placement itself is left to
                // macOS — a new window opened from ⌘T / ⌘-click is tabbed by
                // the system (per the user's "Prefer tabs" setting), next to
                // the current tab; no manual attaching.
                WindowAccessor { window in
                    windowState.macWindow = window
                }
            }
            #endif
            // Menu bar Database > Browse Public Database — published as a
            // focused scene value so the command targets the active window
            // (an app-level binding would present the alert in every window).
            .focusedSceneValue(\.browsePublicDatabase, BrowsePublicDatabaseCommand {
                showingPublicEntry = true
            })
            .onOpenURL { url in
                if router.handle(url: url) {
                    router.targetWindowId = windowState.windowId
                } else {
                    authService.handleIncoming(url: url)
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    if router.handle(url: url) {
                        router.targetWindowId = windowState.windowId
                    } else {
                        authService.handleIncoming(url: url)
                    }
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

#if os(macOS)
/// Reports the hosting `NSWindow` once SwiftUI has installed the view in a
/// window — used only to label the native tab (`window.tab.title`).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't set yet inside makeNSView — read it a tick later.
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
