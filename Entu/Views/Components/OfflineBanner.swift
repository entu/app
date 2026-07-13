import SwiftUI

/// Compact pill that signals offline state to the user. The view itself
/// always renders; the parent controls visibility so SwiftUI can drive
/// transitions on the parent's conditional inclusion.
struct OfflineBanner: View {
    var body: some View {
        Label("offline", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Floats over the root view — a tinted glass capsule per the
        // Liquid Glass controls-layer guidance.
        .glassEffect(.regular.tint(.red), in: .capsule)
    }
}
