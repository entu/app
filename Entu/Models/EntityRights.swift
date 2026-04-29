// Per-entity access rights resolved against the active user.
//
// The API returns `_owner` / `_editor` / `_expander` / `_viewer` arrays on
// every entity. A right is granted when the active user's id appears in
// the matching array — flat membership, no cascading. The server's data
// model already adds owners to all four arrays where appropriate, so the
// client doesn't synthesise implication. This mirrors the webapp's
// `right` computed in `pages/[account]/[entityId].vue`.
//
// In a public-database session there is no current user
// (`currentUserId == nil`), so every right is false and write affordances
// disappear.

import Foundation

/// Resolved per-entity rights for the active user.
struct EntityRights {
    let owner: Bool
    let editor: Bool
    let expander: Bool
    let viewer: Bool

    static let none = EntityRights(owner: false, editor: false, expander: false, viewer: false)
}

extension EntityDetail {
    /// Compute the rights granted to `userId` on this entity. Each flag is
    /// a literal `properties[<key>].some { $0.reference == userId }` —
    /// **no cascade** — matching the webapp's behaviour exactly.
    func rights(for userId: String?) -> EntityRights {
        guard let userId else { return .none }

        func contains(_ key: String) -> Bool {
            properties[key]?.contains { $0.reference == userId } ?? false
        }

        return EntityRights(
            owner: contains("_owner"),
            editor: contains("_editor"),
            expander: contains("_expander"),
            viewer: contains("_viewer")
        )
    }
}
