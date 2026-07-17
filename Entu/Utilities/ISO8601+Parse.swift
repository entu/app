// ISO 8601 parsing — tolerates both fractional-second and plain
// datetime strings, which the API returns interchangeably.

import Foundation

extension ISO8601DateFormatter {
    /// Parses an ISO 8601 string tolerating both fractional-seconds
    /// (`2026-04-29T15:30:45.123Z`) and plain (`2026-04-29T15:30:45Z`)
    /// formats — which is what the API can return depending on the underlying
    /// value's precision.
    static func parse(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: string) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
