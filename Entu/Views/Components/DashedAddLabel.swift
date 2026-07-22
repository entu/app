// Dashed "add" capsule — the design's quiet add affordance, shared by the
// file editor's upload chip, the reference editor's "+ Add" chip, and the
// reserved-auth add actions. Callers wrap it in their own Button / Menu
// trigger. (RightsSheet's add-user chip keeps its own larger metrics.)

import SwiftUI

/// Dashed-capsule add label — icon + caption title inside a dashed
/// quaternary stroke.
struct DashedAddLabel: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.medium))
            Text(titleKey)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .overlay {
            Capsule().strokeBorder(
                .quaternary,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
        .contentShape(Capsule())
    }
}
