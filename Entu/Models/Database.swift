// A database returned by the auth API.
// In Entu's multi-tenant model, each database is a separate MongoDB instance.
// The _id is the database name (e.g. "roots") used in API URL paths.

import Foundation

/// A database (tenant) returned by the auth API.
struct Database: Codable, Identifiable, Equatable {
    let _id: String
    let name: String
    let user: DatabaseUser?

    var id: String { _id }
}

/// User info within a database.
struct DatabaseUser: Codable, Equatable {
    let _id: String?
    let name: String?
    let new: Bool?    // true if user was just created via invite
}
