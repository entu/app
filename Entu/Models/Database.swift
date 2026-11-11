// Database (tenant) models — the databases the auth API grants access
// to, plus the signed-in user's identity within each. The same shape
// carries the auth response's `support` entries: databases whose owner
// granted Entu support access, open until `until`, where the user acts as
// the database entity (`user._id`).

import Foundation

/// A database (tenant) returned by the auth API — an own database from
/// `accounts`, or a support database from `support` (then `until` is set).
struct Database: Codable, Identifiable, Equatable {
    let _id: String
    let name: String
    let user: DatabaseUser?

    /// Support databases only: end of the owner's grant, ISO 8601.
    var until: String?

    var id: String { _id }

    /// Parsed `until`, nil for own databases.
    var untilDate: Date? {
        until.flatMap(ISO8601DateFormatter.parse)
    }

    /// True while a support grant is still running — own databases are
    /// never support grants, so they answer false.
    var isActiveSupportGrant: Bool {
        guard let untilDate else { return false }

        return untilDate > .now
    }
}

/// User info within a database. In a support database `_id` is the
/// database entity's id and `name` is absent.
struct DatabaseUser: Codable, Equatable {
    let _id: String?
    let name: String?
}
