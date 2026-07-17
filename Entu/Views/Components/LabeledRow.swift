// Shared "label · value" row primitive — the fixed-width, right-aligned,
// muted label column with the value content leading, used by the entity
// detail view, the edit sheet, and the Duplicate / History / AI-proposal
// rows. One source of truth for the column metrics: a label-width or
// color tweak lands everywhere at once.

import SwiftUI

/// Fixed-width right-aligned muted label + leading value content.
/// `alignment` picks how the label pairs with the value (center for
/// single-line controls, top for tall content, baseline for text rows).
/// On iPhone (compact) and at accessibility type sizes the label stacks
/// above the value instead.
struct LabeledRow<Label: View, Content: View>: View {
    var labelWidth: CGFloat
    var alignment: VerticalAlignment
    var spacing: CGFloat
    private let label: Label
    private let content: Content

    init(
        labelWidth: CGFloat = 140,
        alignment: VerticalAlignment = .center,
        spacing: CGFloat = 16,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.labelWidth = labelWidth
        self.alignment = alignment
        self.spacing = spacing
        self.label = label()
        self.content = content()
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// iPhone — a narrow row can't fit the label column without clipping.
    /// Also true at accessibility Dynamic Type sizes on every platform.
    private var isCompact: Bool {
        if dynamicTypeSize.isAccessibilitySize { return true }

        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 4) {
                label
                    .foregroundStyle(.tertiary)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                label
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: labelWidth, alignment: alignment == .top ? .topTrailing : .trailing)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
