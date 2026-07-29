// Seed value for a new window/tab — carried by the value-based main
// WindowGroup so ⌘T (dashboard) and ⌘-click (entity) open a scene with
// defined content instead of restoring the saved session.

import Foundation

/// Seed for a new window/tab — what the window shows on first appearance.
struct TabRequest: Codable, Hashable {
    /// The content a freshly opened window starts on.
    enum Content: Codable, Hashable {
        /// Launch-restored window (the WindowGroup default value) — claims
        /// its own saved per-window snapshot from `WindowSessionStore`,
        /// falling back to the active database's `ui.session` state.
        case restore

        /// ⇧⌘N "New Window" — the active database's `ui.session` state,
        /// without claiming a restored window's snapshot (distinguishes an
        /// explicit new window from launch restoration).
        case newWindow

        /// ⌘T "New Tab" — fresh dashboard with clean navigation and search.
        case dashboard

        /// Legacy seed — entities now open in the auxiliary entity window
        /// (`EntityWindowRootView`); kept so main windows saved before that
        /// change still decode and restore (pinned entity, everything else
        /// clean), and as `WindowState.seed` vocabulary.
        case entity(String)

        /// ⌘-click on a sidebar menu item — that menu selected (its entity
        /// list), everything else clean.
        case menu(String)
    }

    var content: Content = .restore

    /// `openWindow(value:)` focuses an existing window when the values are
    /// equal — the nonce keeps every request unique so a new window is
    /// always created (verified against the macOS 26 SDK).
    var nonce = UUID()
}
