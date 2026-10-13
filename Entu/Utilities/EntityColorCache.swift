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

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses the thumbnail API's `#rrggbb` dominant color.
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// Perceived luminance above 0.6 — light colors need darker selection
    /// chrome to stay visible on light backgrounds.
    var isLight: Bool {
        0.299 * red + 0.587 * green + 0.114 * blue > 0.6
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
