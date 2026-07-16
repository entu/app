// Session cache of cover-derived entity colors, keyed by entity id.
// Populated wherever a thumbnail gets processed (list avatars, detail
// header) and read wherever the entity's identity color is needed — so the
// header paints its final color instantly on revisit and the list selection
// tint matches the cover. Observable: rows re-tint as colors arrive.
// Cleared on logout and on database switch.

import SwiftUI

/// An sRGB color triple (0…1) — the payload of the color cache.
struct RGBColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// In-memory cover-color cache, keyed by entity id. Session-scoped.
@MainActor @Observable
final class EntityColorCache {
    static let shared = EntityColorCache()

    var colors: [String: RGBColor] = [:]

    func clear() {
        colors = [:]
    }
}
