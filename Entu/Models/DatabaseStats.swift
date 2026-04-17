// Usage statistics for a database, returned by the API root endpoint.
// Each stat tracks current usage, the plan limit, and soft-deleted count.

import Foundation

/// Usage statistics for a database.
struct DatabaseStats: Codable {
    let entities: UsageStat
    let properties: UsageStat
    let files: UsageStat
    let requests: UsageStat
}

/// Single usage stat with current, limit, and deleted counts.
struct UsageStat: Codable {
    let usage: Int?
    let limit: Int?
    let deleted: Int?
}
