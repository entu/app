// Support-session chrome — while the active database is open through an
// Entu support grant, a full-width orange banner at the top of the window
// reads "Support access until <date time>". It sits in the layout flow
// above the content, pushing it down so it never covers anything — the
// webapp's top banner in `layouts/default.vue`. On iOS it sits below the
// status bar (its color fills that area); on macOS at the top of the
// window content, below the toolbar. When the grant's end time passes, it
// returns the window to the database picker via
// `AuthModel.leaveEndedSupportDatabase()`.

import SwiftUI

extension View {
    /// Puts an end-time banner above the view while the active database is
    /// a support database; a no-op otherwise. The view keeps its place in
    /// the stack whether or not the banner shows, so switching database
    /// never rebuilds it.
    func supportAccessChrome() -> some View {
        modifier(SupportAccessChrome())
    }
}

/// See `supportAccessChrome()`.
private struct SupportAccessChrome: ViewModifier {
    @Environment(AuthModel.self) private var auth

    func body(content: Content) -> some View {
        let until = auth.currentSupportDatabase?.untilDate

        // A plain stack, not a safe-area inset: views that ignore the top
        // safe area (the detail header band, the list count strip) would
        // otherwise draw under the banner.
        VStack(spacing: 0) {
            if let until {
                Text("supportAccessUntil \(until, format: .entuDateTime)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    // Text stays below the status bar; the color fills it.
                    .background(Color.orange.ignoresSafeArea(edges: .top))
            }

            content
        }
        // When the grant runs out, leave the database so its loaded data
        // doesn't stay on screen (idempotent across windows).
        .task(id: until) {
            guard let until else { return }

            do {
                // One second past the end, so the grant reads as ended.
                try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 1))
            } catch {
                return
            }
            auth.leaveEndedSupportDatabase()
        }
    }
}
