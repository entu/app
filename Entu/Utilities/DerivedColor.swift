// Deterministic identity colors — the redesign derives icon-tile and cover
// colors from a stable id (hash → hue, fixed saturation/brightness band) so
// an item keeps its color everywhere: database card, list thumbnail, cover
// header, search results.

import CoreImage
import SwiftUI

/// Shared Core Image context for color extraction — CIContext creation is
/// expensive and the context is thread-safe.
private let colorExtractionContext = CIContext()

/// Dominant color of a platform image as sRGB 0…1 — the entity cover
/// header derives its gradient from it.
///
/// CIKMeans clusters the image into a small palette. Each palette pixel is
/// premultiplied by its alpha, and the alpha carries the cluster's pixel
/// share — so dominance comes straight from the palette (rendered as
/// unconverted linear floats, unpremultiplied, then mapped to sRGB).
/// Washed-out clusters (near-white page backgrounds, near-black borders,
/// grays) are skipped while a colorful cluster exists, so a book cover on
/// white paper yields the artwork's color, not the paper's.
func dominantRGB(of image: PlatformImage) -> (red: Double, green: Double, blue: Double)? {
    #if os(macOS)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #else
    guard let cgImage = image.cgImage else { return nil }
    #endif

    let ciImage = CIImage(cgImage: cgImage)
    let clusterCount = 6

    guard let kmeans = CIFilter(name: "CIKMeans", parameters: [
        kCIInputImageKey: ciImage,
        kCIInputExtentKey: CIVector(cgRect: ciImage.extent),
        "inputCount": clusterCount,
        "inputPasses": 10,
        "inputPerceptual": 0
    ]), let paletteImage = kmeans.outputImage else { return nil }

    // Palette — a clusterCount × 1 pixel image, rendered without color
    // conversion so the values stay in the linear working space.
    var floats = [Float](repeating: 0, count: 4 * clusterCount)
    floats.withUnsafeMutableBytes { buffer in
        colorExtractionContext.render(
            paletteImage,
            toBitmap: buffer.baseAddress!,
            rowBytes: 4 * clusterCount * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: clusterCount, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
    }

    struct Cluster {
        let weight: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    // Unpremultiply and apply the linear → sRGB transfer.
    func srgb(_ value: Float) -> Double {
        let v = Double(min(max(value, 0), 1))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    let clusters: [Cluster] = (0..<clusterCount).compactMap { index in
        let alpha = floats[index * 4 + 3]
        guard alpha > 0.001 else { return nil }

        return Cluster(
            weight: Double(alpha),
            red: srgb(floats[index * 4] / alpha),
            green: srgb(floats[index * 4 + 1] / alpha),
            blue: srgb(floats[index * 4 + 2] / alpha)
        )
    }
    .sorted { $0.weight > $1.weight }

    guard !clusters.isEmpty else { return nil }

    /// Saturated and not near-black — a color that can carry the entity's
    /// identity on the header (near-white fails the saturation test).
    func isColorful(_ c: Cluster) -> Bool {
        let maxComponent = max(c.red, c.green, c.blue)
        let minComponent = min(c.red, c.green, c.blue)
        let saturation = maxComponent == 0 ? 0 : (maxComponent - minComponent) / maxComponent

        return saturation >= 0.15 && maxComponent >= 0.15
    }

    let winner = clusters.first(where: isColorful) ?? clusters[0]

    return (winner.red, winner.green, winner.blue)
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
