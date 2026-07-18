// UI-plugin host — renders a plugin's page in SwiftUI's native `WebView`
// inside the edit sheet, mirroring the webapp's iframe contract.

import SwiftUI
import WebKit

/// Hosts a UI plugin's page inside the edit sheet using SwiftUI's native
/// `WebView` (iOS/macOS 26). `WebPage` is an `@Observable` model, so loading
/// state drives the overlay spinner directly.
///
/// The plugin page receives the account, entity/parent/type, locale and the
/// user's token as query parameters (built in `EntityEditView.pluginURL`) and
/// calls the Entu API back with that token — mirroring the webapp's iframe
/// contract in `components/entity/drawer/edit.vue`.
///
/// Plugins commonly finish by redirecting to an Entu entity link (e.g. after a
/// CSV import). `onEntuLink` intercepts those navigations so the app opens the
/// entity natively instead of loading the Entu web app inside the plugin tab.
struct PluginWebView: View {
    let url: URL

    /// Called on the main actor with a navigation target. Return `true` when
    /// it was an Entu entity/database link that has been routed natively — the
    /// web navigation is then cancelled. Return `false` to let it proceed.
    let onEntuLink: (URL) -> Bool

    @State private var page: WebPage
    @State private var decider: PluginNavigationDecider

    init(url: URL, onEntuLink: @escaping (URL) -> Bool) {
        self.url = url
        self.onEntuLink = onEntuLink
        let decider = PluginNavigationDecider()
        _decider = State(initialValue: decider)
        _page = State(initialValue: WebPage(navigationDecider: decider))
    }

    var body: some View {
        WebView(page)
            .overlay {
                if page.isLoading {
                    ProgressView()
                }
            }
            // Reload if the URL changes (e.g. token refresh promotes the
            // sheet from create to edit mode and rebuilds the params).
            .task(id: url) {
                page.load(URLRequest(url: url))
            }
            .onAppear {
                decider.handleEntuLink = onEntuLink
            }
            // After each load, normalize `window.open` so plugin redirects go
            // through the navigation decider regardless of the target they
            // pass (see `windowOpenShim`).
            .onChange(of: page.isLoading) { _, loading in
                guard !loading else { return }

                Task { @MainActor in
                    _ = try? await page.callJavaScript(Self.windowOpenShim)
                }
            }
    }

    /// WebKit-for-SwiftUI routes in-frame navigations (`_top`/`_self`) through
    /// the navigation decider but drops true new-window (`_blank`) requests.
    /// The Entu plugins redirect with `_top`, so the decider already catches
    /// them — this shim rewrites any `window.open(url, …)` into a top-frame
    /// navigation so interception holds even if a plugin uses another target.
    private static let windowOpenShim = """
    window.open = function (url) { if (url) { window.location.assign(url) } return null }
    """
}

/// Cancels navigations that target an Entu link and hands them to the native
/// router instead, so a plugin redirect to `entu.app/{db}/{id}` opens the
/// entity in the app rather than loading the Entu web app in the plugin tab.
@MainActor
final class PluginNavigationDecider: WebPage.NavigationDeciding {
    /// Returns `true` when `url` was an Entu link that has been routed
    /// natively (navigation is then cancelled). Defaults to a no-op that
    /// allows every navigation until the view wires it up.
    var handleEntuLink: (URL) -> Bool = { _ in false }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }

        return handleEntuLink(url) ? .cancel : .allow
    }
}
