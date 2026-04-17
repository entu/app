// A lightweight entity for display in list views.
// Converted from the raw API EntitySummary at the service layer,
// with localized name resolved and all PropertyValue arrays stripped.

import Foundation

/// Clean UI type for entity list rows — just id, name, and optional thumbnail.
struct EntityListItem: Identifiable, Hashable {
    let _id: String
    let name: String
    let thumbnail: String?

    var id: String { _id }

    /// Convert from raw API EntitySummary, resolving the localized name.
    init(from entity: EntitySummary) {
        _id = entity._id
        name = entity.displayName
        thumbnail = entity._thumbnail
    }
}
