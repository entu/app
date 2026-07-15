// Deterministic identity colors — the redesign derives icon-tile and cover
// colors from a stable id (hash → hue, fixed saturation/brightness band) so
// an item keeps its color everywhere: database card, list thumbnail, cover
// header, search results.

import SwiftUI

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
