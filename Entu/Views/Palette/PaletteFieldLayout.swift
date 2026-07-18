// Input-row layout for the ⌘K palette — token chips wrap like a flow
// layout and the trailing subview (the text field) always fills the
// remainder of the last row, dropping to its own full-width row when
// too little space is left. Keeping the field inside ONE stable layout
// — instead of swapping between a plain row and a chip row — preserves
// its view identity, so keyboard focus survives token edits without
// re-grab workarounds. Deliberately separate from the generic
// `FlowLayout` (Components) — the flexing last child, fill-width sizing
// and per-row centering would be three single-consumer options there.

import SwiftUI

/// Wrapping chip row whose last subview flexes to the remaining width.
struct PaletteFieldLayout: Layout {
    var spacing: CGFloat = 6

    /// Minimum width the trailing field may shrink to before wrapping
    /// onto its own row.
    var fieldMinWidth: CGFloat = 150

    private struct Item {
        var origin: CGPoint
        var size: CGSize
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0

        // Vertically center the finished row's items within its height.
        func closeRow() {
            for index in rowStart..<items.count {
                items[index].origin.y = y + (rowHeight - items[index].size.height) / 2
            }
        }

        func wrap() {
            closeRow()
            x = 0
            y += rowHeight + spacing
            rowHeight = 0
            rowStart = items.count
        }

        for (index, subview) in subviews.enumerated() {
            let isField = index == subviews.count - 1
            var size = subview.sizeThatFits(.unspecified)

            if isField {
                if maxWidth - x < fieldMinWidth && x > 0 {
                    wrap()
                }
                size.width = max(maxWidth - x, fieldMinWidth)
            } else if x > 0, x + size.width > maxWidth {
                wrap()
            }

            items.append(Item(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        closeRow()

        return (items, CGSize(width: maxWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        return layout(subviews: subviews, maxWidth: proposal.width ?? fieldMinWidth).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for (index, item) in result.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }
}
