// Deterministic identity colors — the redesign derives icon-tile and cover
// colors from a stable id (hash → hue, fixed saturation/brightness band) so
// an item keeps its color everywhere: database card, list thumbnail, cover
// header, search results. A cover's dominant color comes from the
// thumbnail API (`APIClient.entityThumbnail`), which computes it server-side.

import SwiftUI

/// Header gradient for a cover color — darkened toward the leading stop.
func coverHeaderGradient(_ rgb: RGBColor) -> LinearGradient {
    LinearGradient(
        colors: [
            Color(red: rgb.red * 0.55, green: rgb.green * 0.55, blue: rgb.blue * 0.55),
            Color(red: min(rgb.red * 1.2, 1), green: min(rgb.green * 1.2, 1), blue: min(rgb.blue * 1.2, 1))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    /// Stable color derived from a string id.
    static func derived(from id: String) -> Color {
        Color(hue: derivedHue(from: id), saturation: 0.62, brightness: 0.72)
    }

    /// Two-stop diagonal gradient of the derived hue, for icon tiles.
    static func derivedGradient(from id: String) -> LinearGradient {
        let hue = derivedHue(from: id)

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.68, brightness: 0.62),
                Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.56, brightness: 0.84)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Emphasis text color of the derived hue — darker, for legible text on
    /// the row's tinted selection fill.
    static func derivedText(from id: String) -> Color {
        Color(hue: derivedHue(from: id), saturation: 0.72, brightness: 0.58)
    }

    /// The entity's identity tint — the cover-derived color when the cache
    /// knows it, the id-derived hue otherwise.
    @MainActor
    static func entityTint(for id: String) -> Color {
        EntityColorCache.shared.colors[id]?.color ?? derived(from: id)
    }

    /// Darker variant of `entityTint` for legible text on the tinted
    /// selection fill.
    @MainActor
    static func entityTintText(for id: String) -> Color {
        if let rgb = EntityColorCache.shared.colors[id] {
            return Color(red: rgb.red * 0.62, green: rgb.green * 0.62, blue: rgb.blue * 0.62)
        }

        return derivedText(from: id)
    }

    /// Selection-ring variant of `entityTint` — light cover colors get
    /// darkened and more opaque so the ring never fades into the row
    /// background. (Id-derived hues have capped brightness and keep the
    /// quiet ring.)
    @MainActor
    static func entityTintBorder(for id: String) -> Color {
        guard let rgb = EntityColorCache.shared.colors[id], rgb.isLight else {
            return entityTint(for: id).opacity(0.3)
        }

        return Color(red: rgb.red * 0.6, green: rgb.green * 0.6, blue: rgb.blue * 0.6)
            .opacity(0.5)
    }

    /// Selection-fill variant of `entityTint` — light cover colors get a
    /// slightly darkened, more opaque fill so the selected row still reads
    /// as tinted against the row background.
    @MainActor
    static func entityTintFill(for id: String) -> Color {
        guard let rgb = EntityColorCache.shared.colors[id], rgb.isLight else {
            return entityTint(for: id).opacity(0.14)
        }

        return Color(red: rgb.red * 0.75, green: rgb.green * 0.75, blue: rgb.blue * 0.75)
            .opacity(0.22)
    }

    /// djb2 hash over UTF-8 bytes → hue in 0..<1. Unlike `hashValue`, the
    /// result is stable across launches, which is the whole point.
    private static func derivedHue(from id: String) -> Double {
        var hash: UInt32 = 5381
        for byte in id.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }

        return Double(hash % 360) / 360
    }
}
