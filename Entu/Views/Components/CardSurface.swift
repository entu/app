// Design-token card chrome shared by stat tiles and other custom cards:
// card fill, 0.5pt hairline, soft shadow — light and dark variants come
// from the CardBackground / CardHairline colorsets.

import SwiftUI

/// Unified card metrics — every card and card grid in the app shares these.
enum CardMetrics {
    /// Corner radius of all cards.
    static let cornerRadius: CGFloat = 14
    /// Gap between adjacent cards.
    static let gap: CGFloat = 10
}

extension View {
    /// Wraps the view in the design's card surface: `CardBackground` fill,
    /// 0.5pt `CardHairline` border, and a soft drop shadow. One radius and
    /// shadow everywhere — no per-call variation.
    func cardSurface() -> some View {
        self
            .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: CardMetrics.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: CardMetrics.cornerRadius)
                    .strokeBorder(Color("CardHairline"), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 5, y: 2)
    }
}
