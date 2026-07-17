// Parses `https://entu.app/{databaseId}/{entityId}?{query}` links into
// pending state that `MainView` consumes once the user is authenticated
// and the menu has loaded. Auth callbacks (`/auth/...`) are deliberately
// ignored here — `AuthService` handles those separately. `handle(url:)`
// returns a Bool so `EntuApp` can fall through to `AuthService` when the
// URL isn't an entity link.

import Foundation

/// Holds the most recent pending entity deep link.
@MainActor @Observable
final class DeepLinkRouter {
    /// Set when a deep link names a database (always present after a successful parse).
    var pendingDatabaseId: String?

    /// Set when a deep link also names an entity inside the database.
    var pendingEntityId: String?

    /// Decoded query items from the deep link — surfaces `q`, `menu`, plus
    /// any additional params for forward compatibility.
    var pendingQuery: [String: String] = [:]

    /// Set when the link carried the `#edit` fragment (plugins redirect to
    /// `entu.app/{db}/{id}#edit` after creating an entity). Consumed by the
    /// entity toolbar host once that entity opens, to present the editor.
    /// Deliberately outside `clear()` — it outlives the navigation deep link
    /// so it survives until the detail view can act on it.
    var pendingEditEntityId: String?

    /// Entity action requested from a list row's context menu. The row
    /// selects its entity and stashes this; `EntityToolbarHost` consumes it
    /// once that entity's detail is loaded, applying the same rights gating
    /// as the toolbar buttons.
    struct PendingRowAction: Equatable {
        enum Kind {
            case edit, duplicate, parents, rights, history
        }

        let entityId: String
        let kind: Kind
    }

    var pendingRowAction: PendingRowAction?

    /// Parse `url` and stash any matching deep-link state.
    /// Returns `true` when the URL was consumed (entu.app entity/database link),
    /// `false` when the caller should fall through (auth callback, foreign host, etc).
    func handle(url: URL) -> Bool {
        guard url.host == "entu.app" else { return false }
        if url.path.hasPrefix("/auth/") { return false }

        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // The database segment is an account *slug* (e.g. `roots`), not an
        // ObjectId — the webapp's own URLs are `entu.app/roots/…`, and plugins
        // redirect using that same slug.
        guard let first = segments.first, isDatabaseId(first) else { return false }

        let second: String?
        if segments.count >= 2 {
            guard isObjectId(segments[1]) else { return false }
            second = segments[1]
        } else {
            second = nil
        }

        var queryDict: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                guard let value = item.value else { continue }
                queryDict[item.name] = value.removingPercentEncoding ?? value
            }
        }

        pendingDatabaseId = first
        pendingEntityId = second
        pendingQuery = queryDict
        // `#edit` on an entity link means "open the editor" (webapp parity).
        if url.fragment == "edit", let second {
            pendingEditEntityId = second
        }
        return true
    }

    /// Clear pending state once MainView has applied it.
    func clear() {
        pendingDatabaseId = nil
        pendingEntityId = nil
        pendingQuery = [:]
        pendingRowAction = nil
    }

    private func isObjectId(_ s: String) -> Bool {
        guard s.count == 24 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }

    /// A database id in a link is an account slug — lowercase letters, digits,
    /// `-`/`_` (e.g. `roots`). 24-hex ObjectIds also satisfy this, so both
    /// forms are accepted for the first path segment.
    private func isDatabaseId(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }

        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
