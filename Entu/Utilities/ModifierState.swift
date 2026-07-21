// Synchronous "is ⌘ held right now" read for click-time checks — used to
// route entity links into a new tab/window instead of in-place navigation.

#if os(macOS)
import AppKit
#else
import GameController
#endif

/// Modifier-key state read synchronously at click time. No event monitors —
/// AppKit exposes the current event-stream state directly, and on iPadOS
/// the GameController framework mirrors the hardware keyboard.
enum ModifierState {
    /// True while the Command key is held.
    @MainActor static var isCommandHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return false }

        return keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
            || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true
        #endif
    }
}
