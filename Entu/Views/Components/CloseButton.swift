// Standard sheet close button — "Close" text on macOS, the system close
// glyph on iOS.

import SwiftUI

/// The standard sheet close button — a text "Close" on macOS, the system close
/// glyph on iOS.
///
/// Takes the dismiss `action` as a closure rather than reading
/// `@Environment(\.dismiss)` itself: on macOS a sheet's toolbar is hoisted to
/// the window toolbar, outside the sheet's environment, so a self-read dismiss
/// is a no-op there. Callers capture `@Environment(\.dismiss)` in their own
/// body and pass it in — `CloseButton { dismiss() }`.
struct CloseButton: View {
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Group {
            #if os(macOS)
            Button("close", role: .close, action: action)
            #else
            Button(role: .close, action: action)
            #endif
        }
        .disabled(isDisabled)
    }
}
