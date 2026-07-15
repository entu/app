// Shared capacity bar for usage statistics — database picker cards and
// dashboard stat tiles. Deleted items still occupy the limit, so they render
// as a lighter segment right after the solid current segment.

import SwiftUI

/// 4pt capacity bar on a quiet track: solid current segment + lighter
/// deleted segment. Fractions are 0…1 of the full width.
struct UsageBar: View {
    let color: Color
    let usageFraction: Double
    var deletedFraction: Double = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color)
                    .frame(width: geo.size.width * usageFraction)
                Rectangle()
                    .fill(color.opacity(0.35))
                    .frame(width: geo.size.width * deletedFraction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}
