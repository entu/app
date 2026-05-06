// View modifier that fades the top and bottom edges of a scrollable region
// so the first/last items dissolve into the surrounding chrome instead of
// hard-clipping. Used by AuthView, DatabaseListView, and UserSheet — all
// scroll containers wrapped in the same outer hero layout.

import SwiftUI

extension View {
    /// Apply a top-and-bottom fade-out mask to a scroll container.
    /// `edge` controls how many points of fade appear at each edge.
    func scrollFadeMask(edge: CGFloat = 16) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: edge)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: edge)
            }
        )
    }
}
