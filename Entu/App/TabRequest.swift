// Seed value for a new window/tab — carried by the value-based main
// WindowGroup so ⌘T (dashboard) and ⌘-click (entity) open a scene with
// defined content instead of restoring the saved session.

import Foundation

/// Seed for a new window/tab — what the window shows on first appearance.
struct TabRequest: Codable, Hashable {
    /// The content a freshly opened window starts on.
    enum Content: Codable, Hashable {
        /// Default window — restore the saved session for the active database.
        case restore

        /// ⌘T "New Tab" — fresh dashboard with clean navigation and search.
        case dashboard

        /// ⌘-click on an entity link — that entity pinned, everything else clean.
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
