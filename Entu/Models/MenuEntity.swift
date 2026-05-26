import Foundation

/// Clean UI type for a sidebar menu item.
struct MenuEntity: Identifiable, Hashable {
    let _id: String
    let name: String
    let query: String
    let group: String?
    let ordinal: Double?

    var id: String { _id }
}

/// A group of menu items sharing a section label.
struct MenuGroup: Identifiable {
    let name: String?
    let items: [MenuEntity]

    var id: String { name ?? "_ungrouped" }

    /// Average ordinal of items — used to sort groups in display order.
    /// Returns nil when no items have ordinals (sorts before groups with ordinals).
    var ordinal: Double? {
        let withOrdinal = items.compactMap { $0.ordinal }
        guard !withOrdinal.isEmpty else { return nil }
        return withOrdinal.reduce(0.0, +) / Double(items.count)
    }
}
