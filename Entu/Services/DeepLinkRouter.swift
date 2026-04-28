// Parses universal links of the form `https://entu.app/{databaseId}/{entityId}?{query}`
// into pending state that MainView consumes once the user is authenticated and
// the menu has loaded.
//
// Auth callbacks (`/auth/...`) are deliberately ignored here — AuthService
// handles those separately. `handle(url:)` returns a Bool so EntuApp can
// fall through to AuthService when the URL isn't an entity link.

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

    /// Parse `url` and stash any matching deep-link state.
    /// Returns `true` when the URL was consumed (entu.app entity/database link),
    /// `false` when the caller should fall through (auth callback, foreign host, etc).
    func handle(url: URL) -> Bool {
        guard url.host == "entu.app" else { return false }
        if url.path.hasPrefix("/auth/") { return false }

        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = segments.first, isObjectId(first) else { return false }

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
        return true
    }

    /// Clear pending state once MainView has applied it.
    func clear() {
        pendingDatabaseId = nil
        pendingEntityId = nil
        pendingQuery = [:]
    }

    private func isObjectId(_ s: String) -> Bool {
        guard s.count == 24 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}
