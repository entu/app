// Deterministic identity colors — the redesign derives icon-tile and cover
// colors from a stable id (hash → hue, fixed saturation/brightness band) so
// an item keeps its color everywhere: database card, list thumbnail, cover
// header, search results.

import CoreImage
import SwiftUI

/// Average color of a platform image (CIAreaAverage) as RGB 0…1 — the
/// entity cover header derives its gradient from the thumbnail's average.
func averageRGB(of image: PlatformImage) -> (red: Double, green: Double, blue: Double)? {
    #if os(macOS)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #else
    guard let cgImage = image.cgImage else { return nil }
    #endif

    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ciImage,
        kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
    ]), let output = filter.outputImage else { return nil }

    var bitmap = [UInt8](repeating: 0, count: 4)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    context.render(
        output,
        toBitmap: &bitmap,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: nil
    )

    return (Double(bitmap[0]) / 255, Double(bitmap[1]) / 255, Double(bitmap[2]) / 255)
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
