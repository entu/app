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

    /// Identity of the window whose URL handler received the link — stamped
    /// by `handle(url:in:)` so only that window's `MainView` consumes the
    /// pending state (every window observes the same shared router).
    var targetWindowId: UUID?

    /// Parse `url` and stash any matching deep-link state, claiming it for
    /// the window with `windowId`. Targeting is atomic with parsing so no
    /// call site can forget the claim and leak the link to another window.
    func handle(url: URL, in windowId: UUID) -> Bool {
        guard handle(url: url) else { return false }

        targetWindowId = windowId
        return true
    }

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

    /// Invite link (`/{db}/invite?token=…`) — the webapp's invite-acceptance
    /// page URL, sent by invite emails. `WindowRootView` presents it as the
    /// provider sheet that completes the invite. Kept separate from the
    /// entity pending state so `MainView`'s consumption never sees it.
    struct PendingInvite: Equatable, Identifiable {
        let databaseId: String
        let token: String
        var id: String { "\(databaseId):\(token)" }
    }

    var pendingInvite: PendingInvite?

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

        var queryDict: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                guard let value = item.value else { continue }
                queryDict[item.name] = value.removingPercentEncoding ?? value
            }
        }

        // Invite-acceptance link — `/{db}/invite?token=…` (webapp's invite
        // page, linked from invite emails). Routed separately from entity
        // links; a missing token makes the link meaningless, so fall through.
        if segments.count == 2, segments[1] == "invite" {
            guard let token = queryDict["token"], !token.isEmpty else { return false }

            pendingInvite = PendingInvite(databaseId: first, token: token)
            return true
        }

        let second: String?
        if segments.count >= 2 {
            guard isObjectId(segments[1]) else { return false }
            second = segments[1]
        } else {
            second = nil
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

    /// Consume the pending invite (sheet dismissed or completed) — owns
    /// the invariant "target set ⇒ something pending": the window claim is
    /// released unless an entity link still holds it.
    func consumeInvite() {
        pendingInvite = nil
        if pendingDatabaseId == nil {
            targetWindowId = nil
        }
    }

    /// Clear pending state once MainView has applied it.
    func clear() {
        pendingDatabaseId = nil
        pendingEntityId = nil
        pendingQuery = [:]
        pendingRowAction = nil
        pendingInvite = nil
        targetWindowId = nil
    }

    private func isObjectId(_ s: String) -> Bool {
        guard s.count == 24 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }

    /// A database id in a link is an account slug — ASCII letters, digits,
    /// `-`/`_` (e.g. `roots`). 24-hex ObjectIds also satisfy this, so both
    /// forms are accepted for the first path segment. ASCII-only on purpose:
    /// Unicode homoglyphs (Cyrillic "о" in "rооts") would otherwise render a
    /// spoofed database name in trusted UI like the invite sheet title.
    private func isDatabaseId(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }

        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
