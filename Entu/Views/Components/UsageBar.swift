// Shared capacity bar for usage statistics — database picker cards and
// dashboard stat tiles. Deleted items still occupy the limit, so they render
// as a lighter segment right after the solid current segment.

import SwiftUI

/// 4pt capacity bar on a quiet track: solid current segment + lighter
/// deleted segment. Fractions are 0…1 of the full width.
///
/// Over-limit rendering mirrors the webapp's `stats-bar.vue`: the caller
/// switches the fraction denominator to the total (so the segments fill the
/// bar) and passes `limitMarkFraction` = limit / total — a red overlay then
/// covers everything beyond the limit's position.
struct UsageBar: View {
    let color: Color
    let usageFraction: Double
    var deletedFraction: Double = 0
    var limitMarkFraction: Double? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(color)
                        .frame(width: geo.size.width * usageFraction)
                    Rectangle()
                        .fill(color.opacity(0.35))
                        .frame(width: geo.size.width * deletedFraction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let limitMarkFraction {
                    Rectangle()
                        .fill(.red.opacity(0.5))
                        .frame(width: max(geo.size.width * (1 - limitMarkFraction), 0))
                        .offset(x: geo.size.width * limitMarkFraction)
                }
            }
            .background(.fill.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}
