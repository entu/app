// Marks a modal sheet's content as blocking the ⌘K command palette —
// while any marked sheet is on screen, the palette toggle no-ops so the
// overlay can't open (invisibly) behind the modal. Pure SwiftUI: each
// sheet content increments the palette model's modal depth on appear
// and decrements on disappear, so nesting (type picker → editor)
// balances naturally.

import SwiftUI

private struct PaletteSheetBlocking: ViewModifier {
    @Environment(CommandPaletteModel.self) private var palette

    func body(content: Content) -> some View {
        content
            .onAppear { palette.modalDepth += 1 }
            // Clamped — a stray extra disappear must not go negative and
            // open a permanent gap in the sheet blocking.
            .onDisappear { palette.modalDepth = max(0, palette.modalDepth - 1) }
    }
}

extension View {
    /// Attach to modal sheet content — ⌘K no-ops while it's presented.
    func blocksCommandPalette() -> some View {
        modifier(PaletteSheetBlocking())
    }
}
