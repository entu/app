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
}
