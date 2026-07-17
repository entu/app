// Database stats model — the GET /{db} usage response (entities,
// properties, files, AI tokens) shown on the dashboard and the
// database picker.

import Foundation

/// Usage statistics for a database.
struct DatabaseStats: Codable {
    /// Database description (organization) — multilingual values in the same
    /// shape as entity properties. Optional so older deployments decode
    /// without it.
    let organization: [PropertyValue]?
    let entities: UsageStat
    let properties: UsageStat
    let files: UsageStat
    /// Monthly AI token usage vs limit (the API's `tokens` block). Optional —
    /// only present once the API reports it, so older deployments decode
    /// without it.
    let tokens: UsageStat?
}

/// Single usage stat with current, limit, and deleted counts.
struct UsageStat: Codable {
    let usage: Int?
    let limit: Int?
    let deleted: Int?
}
