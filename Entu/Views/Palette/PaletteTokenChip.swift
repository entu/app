// Query-grammar token chips rendered inline in the ⌘K input row —
// entity type, filter (sealed and being-edited), and sort.
//
// Design: handoff "Tokens (query grammar)". 12pt medium text, padding
// 3/9/3/5, radius 7, tinted background (accent for filters, `#5856D6`
// purple for sort); the token being edited gets a stronger background
// plus an inset ring; every chip ends with an 8pt × at reduced opacity.

import SwiftUI

/// Shared chrome for one token chip: tinted capsule with trailing ×.
private struct PaletteChipBase<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    // Handoff sizes as Dynamic Type baselines.
    @ScaledMetric(relativeTo: .callout) private var chipFontSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var removeIconSize: CGFloat = 8

    var tint: Color = .accentColor
    var editing = false
    let onRemove: () -> Void
    @ViewBuilder let content: Content

    /// Handoff token table: dark chips carry a stronger tint (0.18 /
    /// editing 0.22) than light (0.10 / 0.14) — the accent colorset
    /// already swaps `#0071E3` → `#409CFF`.
    private var backgroundOpacity: Double {
        if colorScheme == .dark {
            return editing ? 0.22 : 0.18
        }
        return editing ? 0.14 : 0.10
    }

    var body: some View {
        HStack(spacing: 5) {
            content

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: removeIconSize, weight: .semibold))
                    .opacity(0.65)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: chipFontSize, weight: .medium))
        .foregroundStyle(tint)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(tint.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

/// `Raamat ×` — the entity-type scope chip.
struct PaletteTypeChip: View {
    let entityType: PaletteEntityType
    let onRemove: () -> Void

    var body: some View {
        PaletteChipBase(onRemove: onRemove) {
            Text(verbatim: entityType.label)
        }
    }
}

/// `Autor is Tolkien, J. R. R. ×` — a sealed filter chip. The condition
/// word renders at reduced opacity and cycles on click.
struct PaletteFilterChip: View {
    let filter: PaletteFilter
    let onCycleCondition: () -> Void
    let onRemove: () -> Void

    var body: some View {
        PaletteChipBase(onRemove: onRemove) {
            Text(verbatim: filter.property.label)
            conditionWord(filter.condition, action: onCycleCondition)
            Text(verbatim: filter.valueLabel)
        }
    }
}

/// `Autor is` — the filter being edited, awaiting its value.
struct PaletteDraftChip: View {
    let draft: PaletteFilterDraft
    let onCycleCondition: () -> Void
    let onRemove: () -> Void

    var body: some View {
        PaletteChipBase(editing: true, onRemove: onRemove) {
            Text(verbatim: draft.property.label)
            conditionWord(draft.condition, action: onCycleCondition)
        }
    }
}

/// `↓ Pealkiri ×` — the purple sort chip; the arrow flips direction.
struct PaletteSortChip: View {
    static let tint = Color(red: 0x58 / 255, green: 0x56 / 255, blue: 0xD6 / 255)

    @ScaledMetric(relativeTo: .caption2) private var arrowSize: CGFloat = 9

    let sort: PaletteSort
    let onFlip: () -> Void
    let onRemove: () -> Void

    var body: some View {
        PaletteChipBase(tint: Self.tint, onRemove: onRemove) {
            Button(action: onFlip) {
                Image(systemName: sort.descending ? "arrow.down" : "arrow.up")
                    .font(.system(size: arrowSize, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text(verbatim: sort.property.label)
        }
    }
}

/// The chip's condition word ("is", "before", …) at 65% opacity —
/// clicking cycles it (same as ⌥ while editing).
@MainActor
private func conditionWord(_ condition: PaletteCondition, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(verbatim: condition.label)
            .opacity(0.65)
    }
    .buttonStyle(.plain)
}
