// Entity list row model — the clean UI item (id, localized name, photo
// flag) converted from a raw `EntitySummary`.

import Foundation

/// Clean UI type for entity list rows — id, name, and whether a thumbnail
/// should be loaded (resolved lazily from the thumbnail endpoint).
struct EntityListItem: Identifiable, Hashable {
    let _id: String
    let name: String
    let hasPhoto: Bool

    var id: String { _id }

    /// Convert from raw API EntitySummary, resolving the localized name.
    init(from entity: EntitySummary) {
        _id = entity._id
        name = entity.displayName
        hasPhoto = entity.hasPhoto
    }
}
