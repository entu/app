// Slim banner indicating no network connectivity.
// Caller is responsible for placement and visibility — the view itself
// always renders; visibility is controlled by the parent so SwiftUI can
// drive transitions on the parent's conditional inclusion.

import SwiftUI

/// Compact pill that signals offline state to the user.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("offline")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.red.opacity(0.9)))
        .accessibilityElement(children: .combine)
    }
}
