// Autosave status capsule for sheets that commit each change immediately
// (Parents, Rights). Shown only after the first save: "Saving…" while a
// mutation is in flight, green "All changes saved" once idle.

import SwiftUI

/// Green "All changes saved" / quiet "Saving…" status capsule.
struct AutosavePill: View {
    let isSaving: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isSaving {
                ProgressView()
                    .controlSize(.mini)
                Text("saving")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                Text("allChangesSaved")
            }
        }
        .font(.caption)
        .foregroundStyle(Color("SuccessText"))
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .background(
            (isSaving ? Color.secondary : Color.green).opacity(0.14),
            in: Capsule()
        )
    }
}
